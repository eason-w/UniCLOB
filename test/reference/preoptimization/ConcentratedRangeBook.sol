// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TickMath } from "./vendor/uniswap/TickMath.sol";
import { SqrtPriceMath } from "./vendor/uniswap/SqrtPriceMath.sol";
import { SwapMath } from "./vendor/uniswap/SwapMath.sol";
import { ConcentratedLiquidity as CL } from "./libraries/ConcentratedLiquidity.sol";
import { TickTree } from "./libraries/TickTree.sol";
import { FifoQueue } from "./libraries/FifoQueue.sol";
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
        address token0;
        address token1;
        uint128 orderLot;
        int24 tickSpacing;
        uint24 feePpm;
        uint8 protocolDivisor;
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
        bytes32 marketId;
        address owner;
        int24 lower;
        int24 upper;
        CL.Position accounting;
    }

    struct Order {
        bytes32 marketId;
        address owner;
        int24 tick;
        bool ask;
        uint64 generation;
        uint32 sequence;
        uint128 posted;
        uint128 cancelled;
        uint128 claimed;
    }

    /// @dev Exact-input IOC, or FOK when all maxInput must be spent. Price limit includes orders at that tick.
    struct TradeRequest {
        bytes32 marketId;
        bool zeroForOne;
        uint128 maxInput;
        uint160 sqrtPriceLimitX96;
        uint256 minOutput;
        uint32 maxSteps;
        uint64 deadline;
        bool fillOrKill;
    }

    struct TradeResult {
        uint256 input;
        uint256 output;
        uint256 fee;
        uint256 ammInput;
        uint256 orderInput;
        uint32 steps;
    }

    struct Execution {
        uint256 budget;
        uint256 net;
        TradeResult result;
    }

    address public immutable feeCollector;
    uint256 public nextPositionId = 1;
    uint256 public nextOrderId = 1;
    mapping(address owner => mapping(address token => uint256 amount)) public balanceOf;
    mapping(address token => uint256 amount) public totalLiability;
    mapping(address token => uint256 amount) public protocolFees;
    mapping(bytes32 id => Market market) private markets;
    mapping(uint256 id => Position position) private positions;
    mapping(uint256 id => Order order) private orders;

    error InvalidConfiguration();
    error UnknownMarket();
    error MarketExists();
    error Unauthorized();
    error InvalidAmount();
    error InvalidPrice();
    error DeadlineExpired();
    error Slippage();
    error IncompleteFill();
    error InsufficientBalance();
    error UnsupportedToken();
    error InvalidRecipient();
    error MarketableOrder();
    error BatchTooLarge();

    event MarketCreated(bytes32 indexed marketId, Config config);
    event Deposited(address indexed owner, address indexed token, uint256 amount);
    event Withdrawn(address indexed owner, address indexed token, address recipient, uint256 amount);
    event PositionCreated(
        uint256 indexed positionId, bytes32 indexed marketId, address indexed owner, int24 lower, int24 upper
    );
    event LiquidityChanged(uint256 indexed positionId, int128 delta, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event OrderPlaced(
        uint256 indexed orderId, bytes32 indexed marketId, address indexed owner, bool ask, int24 tick, uint128 lots
    );
    event OrderCancelled(uint256 indexed orderId, uint128 lots, uint256 refund);
    event OrderClaimed(uint256 indexed orderId, uint128 lots, uint256 proceeds);
    event Traded(bytes32 indexed marketId, address indexed owner, bool zeroForOne, TradeResult result);
    event ProtocolCollected(address indexed token, address indexed recipient, uint256 amount);

    /// @param collector Immutable authority over protocol fees only.
    constructor(address collector) {
        if (collector == address(0)) revert InvalidRecipient();
        feeCollector = collector;
    }

    /// @notice Creates an immutable market; the creator acquires no administrative privileges.
    function createMarket(Config calldata c) external nonReentrant returns (bytes32 id) {
        if (
            c.token0 == c.token1 || c.token0.code.length == 0 || c.token1.code.length == 0 || c.orderLot == 0
                || c.tickSpacing <= 0 || c.tickSpacing > 32_767 || c.feePpm == 0 || c.feePpm > 100_000
                || c.protocolDivisor < 2 || c.protocolDivisor > 10
                || ((c.feePpm == 100 || c.feePpm == 500) && c.protocolDivisor != 4)
                || ((c.feePpm == 3000 || c.feePpm == 10_000) && c.protocolDivisor != 6)
        ) revert InvalidConfiguration();
        id = keccak256(abi.encode(c));
        Market storage m = markets[id];
        if (m.config.token0 != address(0)) revert MarketExists();
        m.config = c;
        m.curve.initialize(c.initialSqrtPriceX96);
        emit MarketCreated(id, c);
    }

    /// @notice Deposits exact received tokens into a prefunded trading balance.
    function deposit(address token, uint256 amount, address owner) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (owner == address(0) || owner == address(this)) revert InvalidRecipient();
        if (token.code.length == 0) revert UnsupportedToken();
        balanceOf[owner][token] += amount;
        totalLiability[token] += amount;
        uint256 before_ = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != before_ + amount) revert UnsupportedToken();
        emit Deposited(owner, token, amount);
    }

    /// @notice Withdraws only the caller's unlocked funds.
    function withdraw(address token, uint256 amount, address recipient) external nonReentrant {
        _debit(msg.sender, token, amount);
        _send(token, amount, recipient);
        emit Withdrawn(msg.sender, token, recipient, amount);
    }

    /// @notice Collects protocol allocations without access to AMM or maker reserves.
    function collectProtocol(address token, uint256 amount, address recipient) external nonReentrant {
        if (msg.sender != feeCollector) revert Unauthorized();
        if (amount > protocolFees[token]) revert InsufficientBalance();
        protocolFees[token] -= amount;
        _send(token, amount, recipient);
        emit ProtocolCollected(token, recipient, amount);
    }

    /// @notice Batches up to 64 independently guarded operations with caller identity preserved.
    function multicall(bytes[] calldata calls) external returns (bytes[] memory results) {
        if (calls.length > 64) revert BatchTooLarge();
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory data) = address(this).delegatecall(calls[i]);
            if (!success) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
            results[i] = data;
        }
    }

    /// @notice Returns the widest aligned range for this market. There is no range-width cap.
    function fullRange(bytes32 id) public view returns (int24 lower, int24 upper) {
        int24 spacing = _market(id).config.tickSpacing;
        lower = TickMath.MIN_TICK - TickMath.MIN_TICK % spacing;
        upper = TickMath.MAX_TICK - TickMath.MAX_TICK % spacing;
    }

    /// @notice Creates an endpoint-based position, including full-range positions.
    /// @param liquidity Uniswap-style liquidity L, not token amounts or per-bin shares.
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
    function placeOrder(bytes32 id, bool ask, int24 tick, uint128 lots, uint64 deadline)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        _deadline(deadline);
        Market storage m = _market(id);
        if (tick <= TickMath.MIN_TICK || tick >= TickMath.MAX_TICK || tick % m.config.tickSpacing != 0) {
            revert InvalidPrice();
        }
        if (lots == 0) revert InvalidAmount();
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        if (ask ? price < m.curve.sqrtPriceX96 : price > m.curve.sqrtPriceX96) revert MarketableOrder();
        (bool found, int24 other) = ask ? m.bids.next(TickMath.MAX_TICK, false) : m.asks.next(TickMath.MIN_TICK, true);
        if (found && (ask ? tick <= other : tick >= other)) revert MarketableOrder();
        uint256 base = uint256(lots) * m.config.orderLot;
        uint256 quote = _quote(price, base, true);
        if (base > type(uint128).max || quote > type(uint128).max || _quote(price, m.config.orderLot, false) == 0) {
            revert InvalidAmount();
        }
        FifoQueue.Queue storage q = ask ? m.askQueues[tick] : m.bidQueues[tick];
        (uint64 generation, uint32 sequence) = q.append(lots);
        orderId = nextOrderId++;
        orders[orderId] = Order(id, msg.sender, tick, ask, generation, sequence, lots, 0, 0);
        _debit(msg.sender, ask ? m.config.token0 : m.config.token1, ask ? base : quote);
        if (ask) {
            m.orderReserve0 += base;
            m.asks.set(tick, true);
        } else {
            m.orderReserve1 += quote;
            m.bids.set(tick, true);
        }
        emit OrderPlaced(orderId, id, msg.sender, ask, tick, lots);
    }

    /// @notice Cancels only unfilled lots, preserving filled proceeds and surviving FIFO priority.
    function cancelOrder(uint256 orderId, uint128 lots) external nonReentrant {
        Order storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        q.cancel(o.generation, o.sequence, lots);
        uint256 refund;
        if (o.ask) {
            refund = uint256(lots) * m.config.orderLot;
        } else {
            uint160 price = TickMath.getSqrtPriceAtTick(o.tick);
            refund = _quote(price, uint256(o.cancelled + lots) * m.config.orderLot, false)
                - _quote(price, uint256(o.cancelled) * m.config.orderLot, false);
        }
        o.cancelled += lots;
        if (o.ask) m.orderReserve0 -= refund;
        else m.orderReserve1 -= refund;
        balanceOf[msg.sender][o.ask ? m.config.token0 : m.config.token1] += refund;
        _refresh(m, o.ask, o.tick, q);
        emit OrderCancelled(orderId, lots, refund);
    }

    /// @notice Claims executed FIFO quantities without iterating over other makers.
    function claimOrder(uint256 orderId) external nonReentrant returns (uint256 proceeds) {
        Order storage o = _order(orderId);
        Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        uint128 executed = o.posted - o.cancelled - q.remaining(o.generation, o.sequence);
        uint128 lots = executed - o.claimed;
        if (o.ask) {
            uint160 price = TickMath.getSqrtPriceAtTick(o.tick);
            proceeds = _quote(price, uint256(executed) * m.config.orderLot, false)
                - _quote(price, uint256(o.claimed) * m.config.orderLot, false);
            m.orderReserve1 -= proceeds;
        } else {
            proceeds = uint256(lots) * m.config.orderLot;
            m.orderReserve0 -= proceeds;
        }
        o.claimed = executed;
        balanceOf[msg.sender][o.ask ? m.config.token1 : m.config.token0] += proceeds;
        emit OrderClaimed(orderId, lots, proceeds);
    }

    /// @notice Executes AMM intervals before FIFO orders at their endpoints, with one cumulative taker fee.
    /// @dev maxSteps bounds initialized-boundary/order visits, including zero-liquidity jumps.
    function trade(TradeRequest calldata r) external nonReentrant returns (TradeResult memory result) {
        _deadline(r.deadline);
        Market storage m = _market(r.marketId);
        if (r.maxInput == 0 || r.maxSteps == 0) revert InvalidAmount();
        uint160 current = m.curve.sqrtPriceX96;
        if (
            r.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || r.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
                || (r.zeroForOne ? r.sqrtPriceLimitX96 > current : r.sqrtPriceLimitX96 < current)
        ) revert InvalidPrice();
        Execution memory e = Execution(FeeMath.principal(r.maxInput, m.config.feePpm), 0, TradeResult(0, 0, 0, 0, 0, 0));
        while (e.net < e.budget && e.result.steps < r.maxSteps) {
            ++e.result.steps;
            if (!_step(m, r, e)) break;
        }
        result = e.result;
        if (result.input == 0) revert InvalidAmount();
        if (result.output < r.minOutput) revert Slippage();
        if (r.fillOrKill && result.input != r.maxInput) revert IncompleteFill();
        _debit(msg.sender, r.zeroForOne ? m.config.token0 : m.config.token1, result.input);
        balanceOf[msg.sender][r.zeroForOne ? m.config.token1 : m.config.token0] += result.output;
        emit Traded(r.marketId, msg.sender, r.zeroForOne, result);
    }

    /// @notice Configuration and current AMM state.
    function getMarket(bytes32 id)
        external
        view
        returns (Config memory config, uint160 price, int24 tick, uint128 liquidity)
    {
        Market storage m = _market(id);
        return (m.config, m.curve.sqrtPriceX96, m.curve.tick, m.curve.liquidity);
    }

    /// @notice Segregated AMM and order reserves, including rounding residuals and unclaimed proceeds.
    function reserves(bytes32 id) external view returns (uint256 amm0, uint256 amm1, uint256 orders0, uint256 orders1) {
        Market storage m = _market(id);
        return (m.reserve0, m.reserve1, m.orderReserve0, m.orderReserve1);
    }

    /// @notice Position ownership, endpoints and liquidity/fee checkpoints.
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /// @notice Order metadata, remaining lots and unclaimed executed lots.
    function getOrder(uint256 orderId) external view returns (Order memory o, uint128 remaining, uint128 claimable) {
        o = orders[orderId];
        if (o.owner == address(0)) return (o, 0, 0);
        Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        remaining = q.remaining(o.generation, o.sequence);
        claimable = o.posted - o.cancelled - remaining - o.claimed;
    }

    /// @notice Endpoint metadata for integrations and accounting inspection.
    function getTick(bytes32 id, int24 tick) external view returns (CL.Tick memory) {
        return _market(id).curve.ticks[tick];
    }

    /// @notice Best resting ordinary order. AMM quotes require the curve state, not this order-only view.
    function bestOrder(bytes32 id, bool ask) external view returns (bool found, int24 tick) {
        Market storage m = _market(id);
        if (ask) (found, tick) = m.asks.next(TickMath.MIN_TICK, true);
        else (found, tick) = m.bids.next(TickMath.MAX_TICK, false);
    }

    /// @notice Principal and earned fees obtainable by fully burning a position at current state.
    function positionValue(uint256 positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) return (0, 0, 0, 0);
        CL.State storage c = markets[p.marketId].curve;
        uint160 low = TickMath.getSqrtPriceAtTick(p.lower);
        uint160 high = TickMath.getSqrtPriceAtTick(p.upper);
        uint160 price = c.sqrtPriceX96;
        if (price < high) {
            amount0 = SqrtPriceMath.getAmount0Delta(price > low ? price : low, high, p.accounting.liquidity, false);
        }
        if (price > low) {
            amount1 = SqrtPriceMath.getAmount1Delta(low, price < high ? price : high, p.accounting.liquidity, false);
        }
        (uint256 g0, uint256 g1) = c.inside(p.lower, p.upper);
        // A read-only quote reports whole claimable atoms; checkpoint() retains the fractions.
        // slither-disable-next-line unused-return
        (fee0,) = CL.accrued(p.accounting.liquidity, g0, p.accounting.last0, p.accounting.fraction0);
        // slither-disable-next-line unused-return
        (fee1,) = CL.accrued(p.accounting.liquidity, g1, p.accounting.last1, p.accounting.fraction1);
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
        (bool hasBoundary, int24 boundary) = c.initialized.next(r.zeroForOne ? c.tick : c.tick + 1, !r.zeroForOne);
        (bool hasOrder, int24 orderTick) =
            r.zeroForOne ? m.bids.next(TickMath.MAX_TICK, false) : m.asks.next(TickMath.MIN_TICK, true);
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
                c.sqrtPriceX96 = target;
            } else {
                (uint160 next, uint256 input, uint256 output, uint256 internalFee) =
                    SwapMath.computeSwapStep(c.sqrtPriceX96, target, c.liquidity, -int256(e.budget - e.net), 0);
                assert(internalFee == 0); // Uniform fees are charged once by _account, never by curve math.
                c.sqrtPriceX96 = next;
                _account(m, r.zeroForOne, input, output, true, e);
            }
            c.tick = TickMath.getTickAtSqrtPrice(c.sqrtPriceX96);
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
            _refresh(m, !r.zeroForOne, orderTick, q);
            if (q.total() != 0) return false;
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
        address token = zeroForOne ? m.config.token0 : m.config.token1;
        if (amm) {
            e.result.ammInput += input;
            uint256 carry = zeroForOne ? m.carry0 : m.carry1;
            uint256 cut = (fee + carry) / m.config.protocolDivisor;
            uint8 nextCarry = uint8((fee + carry) % m.config.protocolDivisor);
            uint256 lpFee = fee - cut;
            protocolFees[token] += cut;
            uint256 growth = Math.mulDiv(lpFee, 1 << 128, m.curve.liquidity);
            if (zeroForOne) {
                m.carry0 = nextCarry;
                m.curve.growth0 += growth;
                m.reserve0 += input + lpFee;
                m.reserve1 -= output;
            } else {
                m.carry1 = nextCarry;
                m.curve.growth1 += growth;
                m.reserve1 += input + lpFee;
                m.reserve0 -= output;
            }
        } else {
            e.result.orderInput += input;
            protocolFees[token] += fee;
            if (zeroForOne) {
                m.orderReserve0 += input;
                m.orderReserve1 -= output;
            } else {
                m.orderReserve1 += input;
                m.orderReserve0 -= output;
            }
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
        if (ask) m.asks.set(tick, false);
        else m.bids.set(tick, false);
    }

    function _release(Market storage m, address owner, uint256 amount0, uint256 amount1) private {
        if (amount0 != 0) m.reserve0 -= amount0;
        balanceOf[owner][m.config.token0] += amount0;
        if (amount1 != 0) m.reserve1 -= amount1;
        balanceOf[owner][m.config.token1] += amount1;
    }

    function _market(bytes32 id) private view returns (Market storage m) {
        m = markets[id];
        if (m.config.token0 == address(0)) revert UnknownMarket();
    }

    function _position(uint256 id) private view returns (Position storage p) {
        p = positions[id];
        if (p.owner != msg.sender) revert Unauthorized();
    }

    function _order(uint256 id) private view returns (Order storage o) {
        o = orders[id];
        if (o.owner != msg.sender) revert Unauthorized();
    }

    function _positive(uint128 amount) private pure {
        if (amount == 0 || amount > uint128(type(int128).max)) revert InvalidAmount();
    }

    function _debit(address owner, address token, uint256 amount) private {
        if (amount > balanceOf[owner][token]) revert InsufficientBalance();
        balanceOf[owner][token] -= amount;
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
