// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TickMath } from "./vendor/uniswap/TickMath.sol";
import { SwapMath } from "./vendor/uniswap/SwapMath.sol";
import { ConcentratedLiquidity as CL } from "./libraries/ConcentratedLiquidity.sol";
import { TickTree } from "./libraries/TickTree.sol";
import { AdaptiveFifoQueue as FifoQueue } from "./libraries/AdaptiveFifoQueue.sol";
import { OrderBookAccounting as Orders } from "./libraries/OrderBookAccounting.sol";
import { WalletSettlement as Wallet } from "./libraries/WalletSettlement.sol";
import { FeeMath } from "./libraries/FeeMath.sol";

/// @title ConcentratedRangeBook
/// @notice AMM-first concentrated-liquidity singleton with supplemental, funded FIFO orders.
/// @dev The AMM executes up to each order's price before that order can execute. Full-range
///      positions touch two endpoints. Trading touches initialized endpoints and order levels,
///      never every price tick. Cancun and standard, non-rebasing ERC-20 tokens are required.
contract ConcentratedRangeBook is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CL for CL.State;
    using TickTree for TickTree.Map;
    using FifoQueue for FifoQueue.Queue;

    /// @dev token0 is the base asset; prices are token1 atoms per token0 atom.
    struct Config {
        /// @notice Base asset address; token order is not automatically sorted.
        address token0;
        /// @notice Quote asset address; price is token1 atoms per token0 atom.
        address token1;
        /// @notice Token0 atoms per ordinary-order lot; independent of AMM liquidity units.
        uint128 orderLot;
        /// @notice Positive grid spacing for LP endpoints and ordinary-order prices.
        int24 tickSpacing;
        /// @notice Uniform gross-input taker fee in parts per million.
        uint24 feePpm;
        /// @notice AMM fee share denominator: protocol receives 1/divisor with carried rounding; order fees go entirely to protocol.
        uint8 protocolDivisor;
        /// @notice Initial Q64.96 square-root price; part of immutable market identity.
        uint160 initialSqrtPriceX96;
    }

    struct Market {
        Config config;
        CL.State curve;
        uint256 reserve0;
        uint256 reserve1;
        uint256 orderReserve0;
        uint256 orderReserve1;
        uint8 carry0;
        uint8 carry1;
        TickTree.Map asks;
        TickTree.Map bids;
        mapping(int24 tick => FifoQueue.Queue queue) askQueues;
        mapping(int24 tick => FifoQueue.Queue queue) bidQueues;
    }

    struct Position {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice Core owner; for NFT positions this is the position-manager contract.
        address owner;
        /// @notice Inclusive lower tick.
        int24 lower;
        /// @notice Exclusive upper tick.
        int24 upper;
        /// @notice Liquidity and fee-growth checkpoints for this persistent range.
        CL.Position accounting;
    }

    struct Order {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice Account authorized to cancel, replace and claim the order.
        address owner;
        /// @notice Aligned order price tick.
        int24 tick;
        /// @notice True sells token0 for token1; false buys token0 with token1.
        bool ask;
        /// @notice Queue generation containing this order; distinguishes reused price levels.
        uint64 generation;
        /// @notice FIFO sequence within the queue generation.
        uint32 sequence;
        /// @notice Total base lots originally posted in this revision.
        uint128 posted;
        /// @notice Base lots cancelled from this revision.
        uint128 cancelled;
        /// @notice Filled base lots whose proceeds have already been claimed.
        uint128 claimed;
    }

    /// @dev Queue capacity bounds each quantity to uint64; the public Order ABI remains uint128.
    struct StoredOrder {
        bytes32 marketId;
        address owner;
        int24 tick;
        bool ask;
        uint64 generation;
        uint32 sequence;
        uint64 posted;
        uint64 cancelled;
        uint64 claimed;
    }

    /// @dev Exact-input IOC, or FOK when all maxInput must be spent. Price limit includes orders at that tick.
    struct TradeRequest {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice True sells token0 and moves price down; false sells token1 and moves price up.
        bool zeroForOne;
        /// @notice Maximum gross input atoms, including trading fees.
        uint128 maxInput;
        /// @notice Explicit Q64.96 price limit in the trade direction; core does not accept a zero sentinel.
        uint160 sqrtPriceLimitX96;
        /// @notice Minimum actual output atoms; applies even when a partial fill is permitted.
        uint256 minOutput;
        /// @notice Positive matching-work limit, counting curve boundaries and order-level steps.
        uint32 maxSteps;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
        /// @notice Requires the entire gross input budget to be consumed, otherwise reverts.
        bool fillOrKill;
    }

    struct TradeResult {
        /// @notice Actual gross input atoms, equal to ammInput + orderInput + fee.
        uint256 input;
        /// @notice Actual output atoms.
        uint256 output;
        /// @notice Total taker fee in input atoms across both liquidity sources.
        uint256 fee;
        /// @notice Net input atoms executed against the AMM, excluding fees.
        uint256 ammInput;
        /// @notice Net input atoms executed against FIFO orders, excluding fees.
        uint256 orderInput;
        /// @notice Matching-work steps consumed by execution.
        uint32 steps;
    }

    struct Execution {
        uint256 budget;
        uint256 net;
        TradeResult result;
        uint256 protocolCut;
        uint256 lpFee;
        uint256 ammOutput;
        uint256 orderOutput;
        uint256 carry;
        bool hasOrder;
        int24 orderTick;
    }

    /// @notice Authority over recorded protocol fees only; cannot access user funds or alter markets.
    address public immutable feeCollector;
    /// @notice Next globally unique position identifier; identifiers are never recycled.
    uint256 public nextPositionId = 1;
    /// @notice Next globally unique order identifier; identifiers are never recycled.
    uint256 public nextOrderId = 1;
    /// @notice Free token balances; excludes locked LP principal, order collateral and unclaimed proceeds.
    mapping(address owner => mapping(address token => uint256 amount)) public balanceOf;
    /// @notice Deposited obligations across all markets, reduced on verified withdrawals; excludes donations.
    mapping(address token => uint256 amount) public totalLiability;
    /// @notice Protocol allocations across markets, included in totalLiability and collectible only by feeCollector.
    mapping(address token => uint256 amount) public protocolFees;
    mapping(bytes32 id => Market market) private markets;
    mapping(uint256 id => Position position) private positions;
    mapping(uint256 id => StoredOrder order) private orders;

    /// @notice Market configuration violates token, grid, fee or lot constraints.
    error InvalidConfiguration();
    /// @notice The requested market has not been created.
    error UnknownMarket();
    /// @notice An identical immutable market configuration already exists.
    error MarketExists();
    /// @notice Caller does not own the position/order or is not the protocol collector.
    error Unauthorized();
    /// @notice Quantity is zero, outside its domain, or the trade executes no input.
    error InvalidAmount();
    /// @notice Order tick or trade limit violates the grid, domain or trading direction.
    error InvalidPrice();
    /// @notice The submission timestamp is later than the supplied deadline.
    error DeadlineExpired();
    /// @notice A principal input/output or trade output protection was violated.
    error Slippage();
    /// @notice A fill-or-kill trade could not spend the entire gross input budget.
    error IncompleteFill();
    /// @notice Free balance or protocol allocation is insufficient.
    error InsufficientBalance();
    /// @notice Asset is not a deployed contract or its transfer violates exact balance deltas.
    error UnsupportedToken();
    /// @notice Recipient or credited owner is zero or the exchange itself.
    error InvalidRecipient();
    /// @notice A post-only order crosses the curve spot or an opposing ordinary order.
    error MarketableOrder();
    /// @notice The batch contains more than 64 calls.
    error BatchTooLarge();
    /// @notice Quote updates are empty, malformed, noncanonical, or reference another market.
    error InvalidOrderUpdates();
    /// @notice Successful quote payload; quoteTrade always reverts so all simulated matching is rolled back.
    /// @param result Simulated fill, fee allocation and work count; no matching state commits.
    error QuoteResult(TradeResult result);

    /// @notice A new immutable market was initialized.
    event MarketCreated(bytes32 indexed marketId, Config config);
    /// @notice An exact token transfer credited an owner's internal balance.
    event Deposited(address indexed owner, address indexed token, uint256 amount);
    /// @notice An owner's internal balance was sent to an external recipient.
    event Withdrawn(address indexed owner, address indexed token, address recipient, uint256 amount);
    /// @notice A new persistent, nontransferable LP position was created.
    event PositionCreated(
        uint256 indexed positionId, bytes32 indexed marketId, address indexed owner, int24 lower, int24 upper
    );
    /// @notice LP principal changed by signed liquidity delta; amounts are token atoms.
    event LiquidityChanged(uint256 indexed positionId, int128 delta, uint256 amount0, uint256 amount1);
    /// @notice Whole LP fees were credited internally, including during a liquidity change.
    event FeesCollected(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    /// @notice A funded post-only order entered the FIFO queue.
    event OrderPlaced(
        uint256 indexed orderId, bytes32 indexed marketId, address indexed owner, bool ask, int24 tick, uint128 lots
    );
    /// @notice Unfilled lots were cancelled and collateral was credited internally.
    event OrderCancelled(uint256 indexed orderId, uint128 lots, uint256 refund);
    /// @notice Executed lots were claimed and proceeds were credited internally.
    event OrderClaimed(uint256 indexed orderId, uint128 lots, uint256 proceeds);
    /// @notice A hybrid trade executed for the caller, using internal or direct wallet settlement.
    event Traded(bytes32 indexed marketId, address indexed owner, bool zeroForOne, TradeResult result);
    /// @notice Recorded protocol fees were transferred to a recipient.
    event ProtocolCollected(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Deploys an immutable exchange with no upgrade or market administration authority.
    /// @param collector Immutable authority over protocol fees only.
    constructor(address collector) {
        if (collector == address(0)) revert InvalidRecipient();
        feeCollector = collector;
    }

    /// @notice Creates an immutable market; the creator acquires no administrative privileges.
    /// @param c Immutable token, grid, fee, lot and initial-price parameters.
    /// @return id Market identifier: keccak256(abi.encode(c)).
    function createMarket(Config calldata c) external nonReentrant returns (bytes32 id) {
        return Orders.create(markets, c);
    }

    /// @notice Deposits exact received tokens into a prefunded trading balance.
    /// @param token Exact-transfer ERC20 asset to pull from msg.sender.
    /// @param amount Positive number of token atoms to transfer.
    /// @param owner Account receiving the free balance; need not be the caller.
    function deposit(address token, uint256 amount, address owner) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (owner == address(0) || owner == address(this)) revert InvalidRecipient();
        if (token.code.length == 0) revert UnsupportedToken();
        balanceOf[owner][token] += amount;
        _pull(token, amount);
        emit Deposited(owner, token, amount);
    }

    /// @notice Withdraws only the caller's unlocked funds.
    /// @param token Asset to withdraw from the caller's free balance.
    /// @param amount Positive number of token atoms to transfer.
    /// @param recipient Destination; cannot be zero or this contract.
    function withdraw(address token, uint256 amount, address recipient) external nonReentrant {
        _debit(msg.sender, token, amount);
        _send(token, amount, recipient);
        emit Withdrawn(msg.sender, token, recipient, amount);
    }

    /// @notice Collects protocol allocations without access to AMM or maker reserves.
    /// @param token Asset whose recorded protocol allocation is collected.
    /// @param amount Positive amount no greater than the recorded allocation.
    /// @param recipient Destination; cannot be zero or this contract.
    function collectProtocol(address token, uint256 amount, address recipient) external nonReentrant {
        if (msg.sender != feeCollector) revert Unauthorized();
        if (amount > protocolFees[token]) revert InsufficientBalance();
        protocolFees[token] -= amount;
        _send(token, amount, recipient);
        emit ProtocolCollected(token, recipient, amount);
    }

    /// @notice Batches up to 64 independently guarded operations with caller identity preserved.
    /// @param calls ABI-encoded calls to this contract; the entire batch reverts on any failure.
    /// @return results ABI-encoded return data in the same order as calls.
    function multicall(bytes[] calldata calls) external returns (bytes[] memory results) {
        if (calls.length > 64) revert BatchTooLarge();
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory data) = address(this).delegatecall(calls[i]);
            if (!success) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
            results[i] = data;
        }
    }

    /// @notice Executes an atomic wallet batch and transfers only each token's net input or output.
    /// @dev No prefunding required. Internal balances remain unchanged. Only liquidity, order and trade
    ///      calls are allowed; no callbacks occur until settlement, which holds the reentrancy lock.
    ///      Per-token intermediate signed deltas must fit int256 and cannot equal int256.min.
    /// @param calls One to 64 encoded actions; any action or settlement failure reverts the entire batch.
    /// @param recipient Recipient of all net outputs; cannot be zero or this exchange.
    /// @return results ABI-encoded results in call order, including actual trade input and output.
    function executeWallet(bytes[] calldata calls, address recipient) external returns (bytes[] memory results) {
        if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        results = Wallet.execute(calls);
        _settleWallet(recipient);
    }

    function _settleWallet(address recipient) private nonReentrant {
        Wallet.settle(totalLiability, recipient);
    }

    /// @notice Returns the widest aligned range for this market. There is no range-width cap.
    /// @param id Existing market identifier.
    /// @return lower Lowest tick divisible by market tick spacing.
    /// @return upper Highest tick divisible by market tick spacing.
    function fullRange(bytes32 id) public view returns (int24 lower, int24 upper) {
        int24 spacing = _market(id).config.tickSpacing;
        lower = TickMath.MIN_TICK - TickMath.MIN_TICK % spacing;
        upper = TickMath.MAX_TICK - TickMath.MAX_TICK % spacing;
    }

    /// @notice Creates an endpoint-based position, including full-range positions.
    /// @param liquidity Uniswap-style liquidity L, not token amounts or per-bin shares.
    /// @param id Existing market identifier.
    /// @param lower Inclusive lower tick, aligned to market spacing.
    /// @param upper Exclusive upper tick, aligned to market spacing.
    /// @param max0 Maximum token0 principal debited from the caller's free balance.
    /// @param max1 Maximum token1 principal debited from the caller's free balance.
    /// @param deadline Last allowed block timestamp, inclusive.
    /// @return positionId New nontransferable position owned by msg.sender.
    /// @return amount0 Token0 principal deposited, rounded up.
    /// @return amount1 Token1 principal deposited, rounded up.
    function mint(bytes32 id, int24 lower, int24 upper, uint128 liquidity, uint256 max0, uint256 max1, uint64 deadline)
        external
        nonReentrant
        returns (uint256 positionId, uint256 amount0, uint256 amount1)
    {
        _deadline(deadline);
        _positive(liquidity);
        Market storage m = _market(id);
        positionId = nextPositionId++;
        Position storage p = positions[positionId];
        p.marketId = id;
        p.owner = msg.sender;
        p.lower = lower;
        p.upper = upper;
        (amount0, amount1) = _modify(m, p, positionId, int128(liquidity));
        if (amount0 > max0 || amount1 > max1) revert Slippage();
        emit PositionCreated(positionId, id, msg.sender, lower, upper);
    }

    /// @notice Adds liquidity after crediting previously earned fees to the position owner.
    /// @param positionId Existing position owned by msg.sender, including a fully burned position.
    /// @param liquidity Positive additional liquidity L, at most int128.max and subject to endpoint capacity.
    /// @param max0 Maximum token0 principal, excluding fees credited before funding.
    /// @param max1 Maximum token1 principal, excluding fees credited before funding.
    /// @param deadline Last allowed block timestamp, inclusive.
    /// @return amount0 Token0 principal deposited, rounded up.
    /// @return amount1 Token1 principal deposited, rounded up.
    function increase(uint256 positionId, uint128 liquidity, uint256 max0, uint256 max1, uint64 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _deadline(deadline);
        _positive(liquidity);
        Position storage p = _position(positionId);
        (amount0, amount1) = _modify(markets[p.marketId], p, positionId, int128(liquidity));
        if (amount0 > max0 || amount1 > max1) revert Slippage();
    }

    /// @notice Releases principal and earned fees in work independent of position width.
    /// @param positionId Existing position owned by msg.sender.
    /// @param liquidity Positive liquidity L to remove, no greater than the position balance.
    /// @param min0 Minimum token0 principal, excluding separately credited fees.
    /// @param min1 Minimum token1 principal, excluding separately credited fees.
    /// @param deadline Last allowed block timestamp, inclusive.
    /// @return amount0 Token0 principal credited internally, rounded down.
    /// @return amount1 Token1 principal credited internally, rounded down.
    function burn(uint256 positionId, uint128 liquidity, uint256 min0, uint256 min1, uint64 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _deadline(deadline);
        _positive(liquidity);
        Position storage p = _position(positionId);
        (amount0, amount1) = _modify(markets[p.marketId], p, positionId, -int128(liquidity));
        if (amount0 < min0 || amount1 < min1) revert Slippage();
    }

    /// @notice Collects fees through two endpoint reads, regardless of range width.
    /// @param positionId Existing position owned by msg.sender.
    /// @return amount0 Whole token0 fee atoms credited to the owner's free balance.
    /// @return amount1 Whole token1 fee atoms credited to the owner's free balance.
    function collect(uint256 positionId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Position storage p = _position(positionId);
        Market storage m = markets[p.marketId];
        (amount0, amount1) = m.curve.checkpoint(p.accounting, p.lower, p.upper);
        _release(m, p.owner, amount0, amount1);
        emit FeesCollected(positionId, amount0, amount1);
    }

    /// @notice Posts a funded FIFO order. Asks sell token0 lots; bids buy token0 lots.
    /// @dev Orders must be on the nonmarketable side of the AMM spot and opposing orders.
    ///      Quote collateral rounds up; maker quote proceeds/refunds round down cumulatively.
    /// @param id Existing market identifier.
    /// @param ask True sells token0 for token1; false buys token0 with token1.
    /// @param tick Aligned limit tick strictly inside the supported tick domain.
    /// @param lots Positive token0 quantity in orderLot units; queue aggregate must fit uint64.
    /// @param deadline Submission deadline only; the resting order does not expire.
    /// @return orderId New order owned by msg.sender; cancellation and claims require this owner.
    function placeOrder(bytes32 id, bool ask, int24 tick, uint128 lots, uint64 deadline)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        _deadline(deadline);
        return _placeOrder(id, ask, tick, lots, 0);
    }

    function _placeOrder(bytes32 id, bool ask, int24 tick, uint128 lots, uint256 reuseId)
        private
        returns (uint256 orderId)
    {
        Market storage m = _market(id);
        orderId = reuseId == 0 ? nextOrderId++ : reuseId;
        uint256 collateral = Orders.place(m, orders[orderId], id, ask, tick, lots);
        _debit(msg.sender, ask ? m.config.token0 : m.config.token1, collateral);
        emit OrderPlaced(orderId, id, msg.sender, ask, tick, lots);
    }

    /// @notice Cancels only unfilled lots, preserving filled proceeds and surviving FIFO priority.
    /// @param orderId Existing order owned by msg.sender.
    /// @param lots Positive unfilled quantity to cancel, in token0 orderLot units.
    function cancelOrder(uint256 orderId, uint128 lots) external nonReentrant {
        _cancelOrder(orderId, lots);
    }

    /// @notice Cancels whatever remains at execution time; filled or cancelled orders are safe no-ops.
    /// @dev Preserves unclaimed fill proceeds. The caller must own the order, even if nothing remains.
    /// @param orderId Existing order owned by msg.sender.
    /// @return lots Actual unfilled quantity cancelled, in token0 orderLot units.
    function cancelRemaining(uint256 orderId) external nonReentrant returns (uint128 lots) {
        StoredOrder storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        lots = q.remaining(o.generation, o.sequence);
        if (lots != 0) _cancelOrder(orderId, lots);
    }

    /// @notice Atomically sets target unfilled quantities/prices for up to 64 owned orders in one market.
    /// @dev Each 43-byte record is abi.encodePacked(uint256 orderId, int24 tick, uint64 lots), big-endian.
    ///      Zero lots cancels the remainder and requires tick=0. Every record claims previous fills.
    ///      Same-price reductions/no-ops preserve FIFO priority; increases or price changes append anew.
    ///      Records execute sequentially, including duplicate IDs. Invalid records revert the whole batch.
    ///      Existing IDs only; creates no new identifiers. Compatible with executeWallet net settlement.
    /// @param id Existing market shared by every order in this batch.
    /// @param updates One to 64 complete packed records, with no trailing bytes.
    /// @param deadline Last allowed submission timestamp, checked once for the entire batch.
    function updateOrders(bytes32 id, bytes calldata updates, uint64 deadline) external nonReentrant {
        _deadline(deadline);
        if (updates.length == 0 || updates.length % 43 != 0) revert InvalidOrderUpdates();
        if (updates.length > 64 * 43) revert BatchTooLarge();
        Market storage m = _market(id);
        for (uint256 offset; offset < updates.length; offset += 43) {
            uint256 orderId;
            int24 tick;
            uint64 lots;
            assembly ("memory-safe") {
                let p := add(updates.offset, offset)
                orderId := calldataload(p)
                tick := signextend(2, shr(232, calldataload(add(p, 32))))
                lots := shr(192, calldataload(add(p, 35)))
            }
            StoredOrder storage o = _order(orderId);
            if (o.marketId != id || (lots == 0 && tick != 0)) revert InvalidOrderUpdates();
            FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
            uint128 remaining = q.remaining(o.generation, o.sequence);
            _claimOrder(orderId);
            if (lots == 0 || (tick == o.tick && lots <= remaining)) {
                if (remaining > lots) _cancelOrder(orderId, remaining - lots);
            } else {
                if (remaining != 0) _cancelOrder(orderId, remaining);
                _placeOrder(id, o.ask, tick, lots, orderId);
            }
        }
    }

    function _cancelOrder(uint256 orderId, uint128 lots) private {
        StoredOrder storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        uint256 refund;
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        q.cancel(o.generation, o.sequence, lots);
        if (o.ask) {
            refund = uint256(lots) * m.config.orderLot;
        } else {
            uint160 price = TickMath.getSqrtPriceAtTick(o.tick);
            refund = _quote(price, uint256(o.cancelled + lots) * m.config.orderLot, false)
                - _quote(price, uint256(o.cancelled) * m.config.orderLot, false);
        }
        o.cancelled += uint64(lots);
        if (o.ask) m.orderReserve0 -= refund;
        else m.orderReserve1 -= refund;
        _refresh(m, o.ask, o.tick, q);
        _credit(msg.sender, o.ask ? m.config.token0 : m.config.token1, refund);
        emit OrderCancelled(orderId, lots, refund);
    }

    /// @notice Claims executed FIFO quantities without iterating over other makers.
    /// @param orderId Existing order owned by msg.sender; already claimed lots cannot be claimed again.
    /// @return proceeds Output token atoms credited internally, excluding any previously claimed proceeds.
    function claimOrder(uint256 orderId) external nonReentrant returns (uint256 proceeds) {
        return _claimOrder(orderId);
    }

    function _claimOrder(uint256 orderId) private returns (uint256 proceeds) {
        StoredOrder storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        uint128 lots;
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        uint128 executed = o.posted - o.cancelled - q.remaining(o.generation, o.sequence);
        lots = executed - o.claimed;
        if (lots == 0) return 0;
        if (o.ask) {
            uint160 price = TickMath.getSqrtPriceAtTick(o.tick);
            proceeds = _quote(price, uint256(executed) * m.config.orderLot, false)
                - _quote(price, uint256(o.claimed) * m.config.orderLot, false);
            m.orderReserve1 -= proceeds;
        } else {
            proceeds = uint256(lots) * m.config.orderLot;
            m.orderReserve0 -= proceeds;
        }
        o.claimed = uint64(executed);
        _credit(msg.sender, o.ask ? m.config.token1 : m.config.token0, proceeds);
        emit OrderClaimed(orderId, lots, proceeds);
    }

    /// @notice Settles an owned order and reuses its identifier for a fresh FIFO quote on the same side and market.
    /// @dev Claims fills, cancels remaining lots, then appends at the back of the new price queue.
    ///      Replacement always loses time priority. Failure restores the entire previous order.
    ///      OrderPlaced is emitted again with the reused identifier; indexers must process events in order.
    /// @param orderId Existing order owned by msg.sender, including a fully settled order.
    /// @param tick New aligned, nonmarketable limit tick.
    /// @param lots Positive quantity of the new order, in token0 orderLot units.
    /// @param deadline Last allowed submission timestamp.
    function replaceOrder(uint256 orderId, int24 tick, uint128 lots, uint64 deadline) external nonReentrant {
        _deadline(deadline);
        StoredOrder storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        uint128 remaining = q.remaining(o.generation, o.sequence);
        _claimOrder(orderId);
        if (remaining != 0) _cancelOrder(orderId, remaining);
        _placeOrder(o.marketId, o.ask, tick, lots, orderId);
    }

    /// @notice Executes AMM intervals before FIFO orders at their endpoints, with one cumulative taker fee.
    /// @dev maxSteps bounds attempted initialized-boundary/order visits, including zero-liquidity jumps.
    ///      Unspent input remains in the caller's free balance. FOK requires spending all maxInput.
    ///      Empty tails do not move spot to a price limit without a boundary or executable order.
    /// @param r Exact-input request with gross budget, inclusive price limit, output and work protections.
    /// @return result Actual gross input, output, fee, net source inputs and attempted matching steps.
    function trade(TradeRequest calldata r) external nonReentrant returns (TradeResult memory result) {
        result = _executeTrade(r);
        Market storage m = markets[r.marketId];
        _debit(msg.sender, r.zeroForOne ? m.config.token0 : m.config.token1, result.input);
        _credit(msg.sender, r.zeroForOne ? m.config.token1 : m.config.token0, result.output);
        emit Traded(r.marketId, msg.sender, r.zeroForOne, result);
    }

    /// @notice Swaps directly from a wallet, pulling only actual input and sending output to the recipient.
    /// @dev Uses the same matching, slippage and fee rules as trade. No prior deposit is needed.
    ///      The caller approves the input token to this exchange. Internal balances remain unchanged.
    /// @param r Exact-input request, including price, output, deadline and work limits.
    /// @param recipient Output destination; cannot be zero or this exchange.
    /// @return result Actual input, output, fees and source quantities.
    function swapWallet(TradeRequest calldata r, address recipient)
        external
        nonReentrant
        returns (TradeResult memory result)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        result = _executeTrade(r);
        Market storage m = markets[r.marketId];
        _pull(r.zeroForOne ? m.config.token0 : m.config.token1, result.input);
        if (result.output != 0) _send(r.zeroForOne ? m.config.token1 : m.config.token0, result.output, recipient);
        emit Traded(r.marketId, msg.sender, r.zeroForOne, result);
    }

    /// @notice Simulates the actual matcher and always reverts, returning QuoteResult on success.
    /// @dev No funding, allowances or token transfers are required. Use the periphery quoter via eth_call.
    ///      Matching writes are rolled back; validation failures retain their normal errors.
    /// @param r Exact-input request with the same price, output, deadline and work limits as a trade.
    function quoteTrade(TradeRequest calldata r) external nonReentrant {
        revert QuoteResult(_executeTrade(r));
    }

    function _executeTrade(TradeRequest calldata r) private returns (TradeResult memory result) {
        _deadline(r.deadline);
        Market storage m = _market(r.marketId);
        if (r.maxInput == 0 || r.maxSteps == 0) revert InvalidAmount();
        uint160 current = m.curve.sqrtPriceX96;
        if (
            r.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || r.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
                || (r.zeroForOne ? r.sqrtPriceLimitX96 > current : r.sqrtPriceLimitX96 < current)
        ) revert InvalidPrice();
        Execution memory e = Execution(0, 0, TradeResult(0, 0, 0, 0, 0, 0), 0, 0, 0, 0, 0, false, 0);
        e.budget = FeeMath.principal(r.maxInput, m.config.feePpm);
        e.carry = r.zeroForOne ? m.carry0 : m.carry1;
        (e.hasOrder, e.orderTick) =
            r.zeroForOne ? m.bids.best(false, m.config.tickSpacing) : m.asks.best(true, m.config.tickSpacing);
        while (e.net < e.budget && e.result.steps < r.maxSteps) {
            ++e.result.steps;
            if (!_step(m, r, e)) break;
        }
        result = e.result;
        if (result.input == 0) revert InvalidAmount();
        if (result.output < r.minOutput) revert Slippage();
        if (r.fillOrKill && result.input != r.maxInput) revert IncompleteFill();
        protocolFees[r.zeroForOne ? m.config.token0 : m.config.token1] += e.protocolCut;
        if (result.ammInput != 0 || e.ammOutput != 0) {
            if (r.zeroForOne) {
                m.carry0 = uint8(e.carry);
                m.reserve0 += result.ammInput + e.lpFee;
                m.reserve1 -= e.ammOutput;
            } else {
                m.carry1 = uint8(e.carry);
                m.reserve1 += result.ammInput + e.lpFee;
                m.reserve0 -= e.ammOutput;
            }
        }
        if (result.orderInput != 0 || e.orderOutput != 0) {
            if (r.zeroForOne) {
                m.orderReserve0 += result.orderInput;
                m.orderReserve1 -= e.orderOutput;
            } else {
                m.orderReserve1 += result.orderInput;
                m.orderReserve0 -= e.orderOutput;
            }
        }
    }

    /// @notice Configuration and current AMM state.
    /// @param id Existing market identifier.
    /// @return config Immutable market configuration.
    /// @return price Current sqrt(token1 atoms / token0 atoms), scaled by 2^96; not an oracle.
    /// @return tick Directional active tick; at a downward boundary it is boundary minus one.
    /// @return liquidity Currently active AMM liquidity L.
    function getMarket(bytes32 id)
        external
        view
        returns (Config memory config, uint160 price, int24 tick, uint128 liquidity)
    {
        Market storage m = _market(id);
        return (m.config, m.curve.sqrtPriceX96, m.curve.tick, m.curve.liquidity);
    }

    /// @notice Segregated AMM and order reserves, including rounding residuals and unclaimed proceeds.
    /// @param id Existing market identifier.
    /// @return amm0 Token0 backing LP principal, unclaimed fees and AMM rounding residue.
    /// @return amm1 Token1 backing LP principal, unclaimed fees and AMM rounding residue.
    /// @return orders0 Token0 backing order collateral, unclaimed proceeds and rounding residue.
    /// @return orders1 Token1 backing order collateral, unclaimed proceeds and rounding residue.
    function reserves(bytes32 id) external view returns (uint256 amm0, uint256 amm1, uint256 orders0, uint256 orders1) {
        Market storage m = _market(id);
        return (m.reserve0, m.reserve1, m.orderReserve0, m.orderReserve1);
    }

    /// @notice Position ownership, endpoints and liquidity/fee checkpoints.
    /// @param positionId Position identifier; nonexistent identifiers return an all-zero struct.
    /// @return Position metadata and fee accounting; ownership is not transferable.
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /// @notice Order metadata, remaining lots and unclaimed executed lots.
    /// @param orderId Order identifier; nonexistent identifiers return all zeros.
    /// @return o Original ownership, price, generation and cumulative quantity metadata.
    /// @return remaining Unfilled and uncancelled token0 lots.
    /// @return claimable Executed token0 lots whose proceeds have not been claimed.
    function getOrder(uint256 orderId) external view returns (Order memory o, uint128 remaining, uint128 claimable) {
        (o, remaining, claimable) = Orders.get(orders[orderId], markets);
    }

    /// @notice Endpoint metadata for integrations and accounting inspection.
    /// @param id Existing market identifier.
    /// @param tick Endpoint to inspect; uninitialized endpoints return zeros.
    /// @return Gross/net liquidity and outside fee growth at this endpoint.
    function getTick(bytes32 id, int24 tick) external view returns (CL.Tick memory) {
        return _market(id).curve.ticks[tick];
    }

    /// @notice Best resting ordinary order. AMM quotes require the curve state, not this order-only view.
    /// @param id Existing market identifier.
    /// @param ask True returns the lowest ask; false returns the highest bid.
    /// @return found Whether any ordinary order exists on this side.
    /// @return tick Best ordinary order tick; undefined when found is false.
    function bestOrder(bytes32 id, bool ask) external view returns (bool found, int24 tick) {
        Market storage m = _market(id);
        if (ask) (found, tick) = m.asks.best(true, m.config.tickSpacing);
        else (found, tick) = m.bids.best(false, m.config.tickSpacing);
    }

    /// @notice Next live ordinary level, for bounded depth pagination; excludes continuous AMM liquidity.
    /// @param id Existing market identifier.
    /// @param ask True walks asks upward; false walks bids downward.
    /// @param from Inclusive start tick; use returned tick plus/minus one for the next page.
    /// @return found Whether a live level exists.
    /// @return tick Located price tick, or zero when absent.
    /// @return lots Aggregate remaining base lots at that level, or zero when absent.
    function nextOrderLevel(bytes32 id, bool ask, int24 from)
        external
        view
        returns (bool found, int24 tick, uint128 lots)
    {
        (found, tick, lots) = Orders.nextLevel(_market(id), ask, from);
    }

    /// @notice Principal and earned fees obtainable by fully burning a position at current state.
    /// @param positionId Position identifier; nonexistent identifiers return all zeros.
    /// @return amount0 Token0 principal at current price, rounded down.
    /// @return amount1 Token1 principal at current price, rounded down.
    /// @return fee0 Whole accrued token0 fees, including retained fractional carry.
    /// @return fee1 Whole accrued token1 fees, including retained fractional carry.
    function positionValue(uint256 positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) return (0, 0, 0, 0);
        return CL.value(markets[p.marketId].curve, p.accounting, p.lower, p.upper);
    }

    function _modify(Market storage m, Position storage p, uint256 positionId, int128 delta)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 fees0;
        uint256 fees1;
        (amount0, amount1, fees0, fees1) = m.curve.modify(p.accounting, p.lower, p.upper, m.config.tickSpacing, delta);
        _release(m, p.owner, fees0, fees1);
        if (delta > 0) {
            _debit(p.owner, m.config.token0, amount0);
            _debit(p.owner, m.config.token1, amount1);
            m.reserve0 += amount0;
            m.reserve1 += amount1;
        } else {
            _release(m, p.owner, amount0, amount1);
        }
        emit FeesCollected(positionId, fees0, fees1);
        emit LiquidityChanged(positionId, delta, amount0, amount1);
    }

    function _step(Market storage m, TradeRequest calldata r, Execution memory e) private returns (bool more) {
        CL.State storage c = m.curve;
        (bool hasBoundary, int24 boundary) =
            c.initialized.next(r.zeroForOne ? c.tick : c.tick + 1, !r.zeroForOne, m.config.tickSpacing);
        bool hasOrder = e.hasOrder;
        int24 orderTick = e.orderTick;
        uint160 boundaryPrice = hasBoundary ? TickMath.getSqrtPriceAtTick(boundary) : r.sqrtPriceLimitX96;
        uint160 orderPrice = hasOrder ? TickMath.getSqrtPriceAtTick(orderTick) : r.sqrtPriceLimitX96;
        uint160 target = r.sqrtPriceLimitX96;
        if (r.zeroForOne) {
            if (hasBoundary && boundaryPrice > target) target = boundaryPrice;
            if (hasOrder && orderPrice > target) target = orderPrice;
        } else {
            if (hasBoundary && boundaryPrice < target) target = boundaryPrice;
            if (hasOrder && orderPrice < target) target = orderPrice;
        }
        if (target != c.sqrtPriceX96) {
            if (c.liquidity == 0) {
                // Empty space has no executable price. Stop at the last real level rather
                // than letting a taker's arbitrary limit become the post-only price anchor.
                if (!(hasBoundary && target == boundaryPrice) && !(hasOrder && target == orderPrice)) return false;
                // Do not move through a gap to an order that cannot execute even one lot.
                if (hasOrder && target == orderPrice) {
                    uint256 minimum = r.zeroForOne ? m.config.orderLot : _quote(orderPrice, m.config.orderLot, true);
                    if (minimum > e.budget - e.net) return false;
                }
                c.sqrtPriceX96 = target;
            } else {
                (uint160 next, uint256 input, uint256 output, uint256 internalFee) =
                    SwapMath.computeSwapStep(c.sqrtPriceX96, target, c.liquidity, -int256(e.budget - e.net), 0);
                assert(internalFee == 0); // Uniform fees are charged once by _account, never by curve math.
                c.sqrtPriceX96 = next;
                _account(m, r.zeroForOne, input, output, true, e);
            }
            if (c.sqrtPriceX96 != target) {
                c.tick = TickMath.getTickAtSqrtPrice(c.sqrtPriceX96);
            } else if (!(hasBoundary && target == boundaryPrice)) {
                c.tick = hasOrder && target == orderPrice ? orderTick : TickMath.getTickAtSqrtPrice(target);
            } // A reached LP boundary sets the directional tick in cross() below.
        }
        if (c.sqrtPriceX96 != target) return false;
        // Curve fees are attributed before changing the active LP set.
        if (hasBoundary && target == boundaryPrice) c.cross(boundary, r.zeroForOne);
        if (hasOrder && target == orderPrice && e.net < e.budget) {
            FifoQueue.Queue storage q = r.zeroForOne ? m.bidQueues[orderTick] : m.askQueues[orderTick];
            uint128 available = q.total();
            uint256 remaining = e.budget - e.net;
            uint256 lots;
            if (r.zeroForOne) lots = Math.min(available, remaining / m.config.orderLot);
            else if (_quote(orderPrice, uint256(available) * m.config.orderLot, true) <= remaining) lots = available;
            else lots = _baseForQuote(orderPrice, remaining) / m.config.orderLot;
            if (lots == 0) return false; // Never bypass a better order to trade against a worse AMM price.
            // Integer order lots deliberately round affordable base quantity down.
            // slither-disable-next-line divide-before-multiply
            uint256 base = lots * m.config.orderLot;
            uint256 quote = _quote(orderPrice, base, !r.zeroForOne);
            q.consume(uint128(lots));
            _account(m, r.zeroForOne, r.zeroForOne ? base : quote, r.zeroForOne ? quote : base, false, e);
            if (lots != available) return false;
            if (r.zeroForOne) m.bids.set(orderTick, false, m.config.tickSpacing);
            else m.asks.set(orderTick, false, m.config.tickSpacing);
            if (e.net < e.budget && target != r.sqrtPriceLimitX96) {
                (e.hasOrder, e.orderTick) =
                    r.zeroForOne ? m.bids.best(false, m.config.tickSpacing) : m.asks.best(true, m.config.tickSpacing);
            }
        }
        return target != r.sqrtPriceLimitX96;
    }

    function _account(Market storage m, bool zeroForOne, uint256 input, uint256 output, bool amm, Execution memory e)
        private
    {
        e.net += input;
        uint256 gross = FeeMath.gross(e.net, m.config.feePpm);
        uint256 fee = gross - e.result.input - input;
        e.result.input = gross;
        e.result.fee += fee;
        e.result.output += output;
        if (amm) {
            e.result.ammInput += input;
            uint256 cut = (fee + e.carry) / m.config.protocolDivisor;
            e.carry = (fee + e.carry) % m.config.protocolDivisor;
            uint256 lpFee = fee - cut;
            e.protocolCut += cut;
            e.lpFee += lpFee;
            e.ammOutput += output;
            uint256 growth = Math.mulDiv(lpFee, 1 << 128, m.curve.liquidity);
            if (zeroForOne) m.curve.growth0 += growth;
            else m.curve.growth1 += growth;
        } else {
            e.result.orderInput += input;
            e.protocolCut += fee;
            e.orderOutput += output;
        }
    }

    // Matches the conventional tick-quote representation: Q192 for small sqrt prices,
    // Q128 for large ones. Both directions use the same rate, avoiding reciprocal drift.
    function _rate(uint160 price) private pure returns (uint256 numerator, uint256 denominator) {
        if (price <= type(uint128).max) return (uint256(price) * price, 1 << 192);
        return (Math.mulDiv(price, price, 1 << 64), 1 << 128);
    }

    function _quote(uint160 price, uint256 base, bool up) private pure returns (uint256) {
        (uint256 n, uint256 d) = _rate(price);
        return Math.mulDiv(base, n, d, up ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    function _baseForQuote(uint160 price, uint256 quote) private pure returns (uint256) {
        (uint256 n, uint256 d) = _rate(price);
        return Math.mulDiv(quote, d, n);
    }

    function _refresh(Market storage m, bool ask, int24 tick, FifoQueue.Queue storage q) private {
        if (q.total() != 0) return;
        if (ask) m.asks.set(tick, false, m.config.tickSpacing);
        else m.bids.set(tick, false, m.config.tickSpacing);
    }

    function _release(Market storage m, address owner, uint256 amount0, uint256 amount1) private {
        if (amount0 != 0) {
            m.reserve0 -= amount0;
            _credit(owner, m.config.token0, amount0);
        }
        if (amount1 != 0) {
            m.reserve1 -= amount1;
            _credit(owner, m.config.token1, amount1);
        }
    }

    function _market(bytes32 id) private view returns (Market storage m) {
        m = markets[id];
        if (m.config.token0 == address(0)) revert UnknownMarket();
    }

    function _position(uint256 id) private view returns (Position storage p) {
        p = positions[id];
        if (p.owner != msg.sender) revert Unauthorized();
    }

    function _order(uint256 id) private view returns (StoredOrder storage o) {
        o = orders[id];
        if (o.owner != msg.sender) revert Unauthorized();
    }

    function _positive(uint128 amount) private pure {
        if (amount == 0 || amount > uint128(type(int128).max)) revert InvalidAmount();
    }

    function _debit(address owner, address token, uint256 amount) private {
        if (Wallet.owner() != address(0)) {
            Wallet.account(owner, token, amount, true);
            return;
        }
        if (amount > balanceOf[owner][token]) revert InsufficientBalance();
        balanceOf[owner][token] -= amount;
    }

    function _credit(address owner, address token, uint256 amount) private {
        if (Wallet.owner() != address(0)) Wallet.account(owner, token, amount, false);
        else balanceOf[owner][token] += amount;
    }

    function _pull(address token, uint256 amount) private {
        totalLiability[token] += amount;
        uint256 before_ = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != before_ + amount) revert UnsupportedToken();
    }

    function _send(address token, uint256 amount, address recipient) private {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        IERC20 asset = IERC20(token);
        uint256 beforeCustody = asset.balanceOf(address(this));
        uint256 beforeRecipient = asset.balanceOf(recipient);
        totalLiability[token] -= amount;
        asset.safeTransfer(recipient, amount);
        if (
            asset.balanceOf(address(this)) != beforeCustody - amount
                || asset.balanceOf(recipient) != beforeRecipient + amount
        ) revert UnsupportedToken();
    }

    function _deadline(uint64 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }
}
