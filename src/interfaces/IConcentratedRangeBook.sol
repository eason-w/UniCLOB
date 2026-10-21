// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Standalone ABI for ConcentratedRangeBook.
interface IConcentratedRangeBook {
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
        LiquidityPosition accounting;
    }

    struct LiquidityPosition {
        uint128 liquidity;
        uint128 fraction0;
        uint128 fraction1;
        uint256 last0;
        uint256 last1;
    }

    struct Tick {
        uint128 gross;
        int128 net;
        uint256 outside0;
        uint256 outside1;
    }

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

    /// @notice Free token balances; excludes locked LP principal, order collateral and unclaimed proceeds.
    /// @param owner Account whose balance or authorization is queried.
    /// @param token ERC20 asset whose balance, liabilities or fees are queried.
    /// @return amount Free token balances; excludes locked LP principal, order collateral and unclaimed proceeds.
    function balanceOf(address owner, address token) external view returns (uint256 amount);

    /// @notice Best resting ordinary order. AMM quotes require the curve state, not this order-only view.
    /// @param id Existing market identifier.
    /// @param ask True returns the lowest ask; false returns the highest bid.
    /// @return found Whether any ordinary order exists on this side.
    /// @return tick Best ordinary order tick; undefined when found is false.
    function bestOrder(bytes32 id, bool ask) external view returns (bool found, int24 tick);

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
        returns (uint256 amount0, uint256 amount1);

    /// @notice Cancels only unfilled lots, preserving filled proceeds and surviving FIFO priority.
    /// @param orderId Existing order owned by msg.sender.
    /// @param lots Positive unfilled quantity to cancel, in token0 orderLot units.
    function cancelOrder(uint256 orderId, uint128 lots) external;

    /// @notice Cancels whatever remains at execution time; filled or cancelled orders are safe no-ops.
    /// @dev Preserves unclaimed fill proceeds. The caller must own the order, even if nothing remains.
    /// @param orderId Existing order owned by msg.sender.
    /// @return lots Actual unfilled quantity cancelled, in token0 orderLot units.
    function cancelRemaining(uint256 orderId) external returns (uint128 lots);

    /// @notice Claims executed FIFO quantities without iterating over other makers.
    /// @param orderId Existing order owned by msg.sender; already claimed lots cannot be claimed again.
    /// @return proceeds Output token atoms credited internally, excluding any previously claimed proceeds.
    function claimOrder(uint256 orderId) external returns (uint256 proceeds);

    /// @notice Collects fees through two endpoint reads, regardless of range width.
    /// @param positionId Existing position owned by msg.sender.
    /// @return amount0 Whole token0 fee atoms credited to the owner's free balance.
    /// @return amount1 Whole token1 fee atoms credited to the owner's free balance.
    function collect(uint256 positionId) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects protocol allocations without access to AMM or maker reserves.
    /// @param token Asset whose recorded protocol allocation is collected.
    /// @param amount Positive amount no greater than the recorded allocation.
    /// @param recipient Destination; cannot be zero or this contract.
    function collectProtocol(address token, uint256 amount, address recipient) external;

    /// @notice Creates an immutable market; the creator acquires no administrative privileges.
    /// @param c Immutable token, grid, fee, lot and initial-price parameters.
    /// @return id Market identifier: keccak256(abi.encode(c)).
    function createMarket(Config calldata c) external returns (bytes32 id);

    /// @notice Deposits exact received tokens into a prefunded trading balance.
    /// @param token Exact-transfer ERC20 asset to pull from msg.sender.
    /// @param amount Positive number of token atoms to transfer.
    /// @param owner Account receiving the free balance; need not be the caller.
    function deposit(address token, uint256 amount, address owner) external;

    /// @notice Executes an atomic wallet batch and transfers only each token's net input or output.
    /// @dev No prefunding required. Internal balances remain unchanged. Only liquidity, order and trade calls are allowed; no callbacks occur until settlement, which holds the reentrancy lock. Per-token intermediate signed deltas must fit int256 and cannot equal int256.min.
    /// @param calls One to 64 encoded actions; any action or settlement failure reverts the entire batch.
    /// @param recipient Recipient of all net outputs; cannot be zero or this exchange.
    /// @return results ABI-encoded results in call order, including actual trade input and output.
    function executeWallet(bytes[] calldata calls, address recipient) external returns (bytes[] memory results);

    /// @notice Authority over recorded protocol fees only; cannot access user funds or alter markets.
    /// @return arg0 Authority over recorded protocol fees only; cannot access user funds or alter markets.
    function feeCollector() external view returns (address arg0);

    /// @notice Returns the widest aligned range for this market. There is no range-width cap.
    /// @param id Existing market identifier.
    /// @return lower Lowest tick divisible by market tick spacing.
    /// @return upper Highest tick divisible by market tick spacing.
    function fullRange(bytes32 id) external view returns (int24 lower, int24 upper);

    /// @notice Configuration and current AMM state.
    /// @param id Existing market identifier.
    /// @return config Immutable market configuration.
    /// @return price Currently active AMM liquidity L.
    /// @return tick Current sqrt(token1 atoms / token0 atoms), scaled by 2^96; not an oracle.
    /// @return liquidity Directional active tick; at a downward boundary it is boundary minus one.
    function getMarket(bytes32 id)
        external
        view
        returns (Config memory config, uint160 price, int24 tick, uint128 liquidity);

    /// @notice Order metadata, remaining lots and unclaimed executed lots.
    /// @param orderId Order identifier; nonexistent identifiers return all zeros.
    /// @return o Executed token0 lots whose proceeds have not been claimed.
    /// @return remaining Original ownership, price, generation and cumulative quantity metadata.
    /// @return claimable Unfilled and uncancelled token0 lots.
    function getOrder(uint256 orderId) external view returns (Order memory o, uint128 remaining, uint128 claimable);

    /// @notice Position ownership, endpoints and liquidity/fee checkpoints.
    /// @param positionId Position identifier; nonexistent identifiers return an all-zero struct.
    /// @return arg0 Position metadata and fee accounting; ownership is not transferable.
    function getPosition(uint256 positionId) external view returns (Position memory arg0);

    /// @notice Endpoint metadata for integrations and accounting inspection.
    /// @param id Existing market identifier.
    /// @param tick Endpoint to inspect; uninitialized endpoints return zeros.
    /// @return arg0 Gross/net liquidity and outside fee growth at this endpoint.
    function getTick(bytes32 id, int24 tick) external view returns (Tick memory arg0);

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
        returns (uint256 amount0, uint256 amount1);

    /// @notice Creates an endpoint-based position, including full-range positions.
    /// @param id Existing market identifier.
    /// @param lower Inclusive lower tick, aligned to market spacing.
    /// @param upper Exclusive upper tick, aligned to market spacing.
    /// @param liquidity Uniswap-style liquidity L, not token amounts or per-bin shares.
    /// @param max0 Maximum token0 principal debited from the caller's free balance.
    /// @param max1 Maximum token1 principal debited from the caller's free balance.
    /// @param deadline Last allowed block timestamp, inclusive.
    /// @return positionId Token0 principal deposited, rounded up.
    /// @return amount0 Token1 principal deposited, rounded up.
    /// @return amount1 New nontransferable position owned by msg.sender.
    function mint(bytes32 id, int24 lower, int24 upper, uint128 liquidity, uint256 max0, uint256 max1, uint64 deadline)
        external
        returns (uint256 positionId, uint256 amount0, uint256 amount1);

    /// @notice Batches up to 64 independently guarded operations with caller identity preserved.
    /// @param calls ABI-encoded calls to this contract; the entire batch reverts on any failure.
    /// @return results ABI-encoded return data in the same order as calls.
    function multicall(bytes[] calldata calls) external returns (bytes[] memory results);

    /// @notice Next globally unique order identifier; identifiers are never recycled.
    /// @return arg0 Next globally unique order identifier; identifiers are never recycled.
    function nextOrderId() external view returns (uint256 arg0);

    /// @notice Next live ordinary level, for bounded depth pagination; excludes continuous AMM liquidity.
    /// @param id Existing market identifier.
    /// @param ask True walks asks upward; false walks bids downward.
    /// @param from Inclusive start tick; use returned tick plus/minus one for the next page.
    /// @return found Whether a live level exists.
    /// @return tick Aggregate remaining base lots at that level, or zero when absent.
    /// @return lots Located price tick, or zero when absent.
    function nextOrderLevel(bytes32 id, bool ask, int24 from)
        external
        view
        returns (bool found, int24 tick, uint128 lots);

    /// @notice Next globally unique position identifier; identifiers are never recycled.
    /// @return arg0 Next globally unique position identifier; identifiers are never recycled.
    function nextPositionId() external view returns (uint256 arg0);

    /// @notice Posts a funded FIFO order. Asks sell token0 lots; bids buy token0 lots.
    /// @dev Orders must be on the nonmarketable side of the AMM spot and opposing orders. Quote collateral rounds up; maker quote proceeds/refunds round down cumulatively.
    /// @param id Existing market identifier.
    /// @param ask True sells token0 for token1; false buys token0 with token1.
    /// @param tick Aligned limit tick strictly inside the supported tick domain.
    /// @param lots Positive token0 quantity in orderLot units; queue aggregate must fit uint64.
    /// @param deadline Submission deadline only; the resting order does not expire.
    /// @return orderId New order owned by msg.sender; cancellation and claims require this owner.
    function placeOrder(bytes32 id, bool ask, int24 tick, uint128 lots, uint64 deadline)
        external
        returns (uint256 orderId);

    /// @notice Principal and earned fees obtainable by fully burning a position at current state.
    /// @param positionId Position identifier; nonexistent identifiers return all zeros.
    /// @return amount0 Token0 principal at current price, rounded down.
    /// @return amount1 Token1 principal at current price, rounded down.
    /// @return fee0 Whole accrued token0 fees, including retained fractional carry.
    /// @return fee1 Whole accrued token1 fees, including retained fractional carry.
    function positionValue(uint256 positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);

    /// @notice Protocol allocations across markets, included in totalLiability and collectible only by feeCollector.
    /// @param token ERC20 asset whose balance, liabilities or fees are queried.
    /// @return amount Protocol allocations across markets, included in totalLiability and collectible only by feeCollector.
    function protocolFees(address token) external view returns (uint256 amount);

    /// @notice Simulates the actual matcher and always reverts, returning QuoteResult on success.
    /// @dev No funding, allowances or token transfers are required. Use the periphery quoter via eth_call. Matching writes are rolled back; validation failures retain their normal errors.
    /// @param r Exact-input request with the same price, output, deadline and work limits as a trade.
    function quoteTrade(TradeRequest calldata r) external;

    /// @notice Settles an owned order and reuses its identifier for a fresh FIFO quote on the same side and market.
    /// @dev Claims fills, cancels remaining lots, then appends at the back of the new price queue. Replacement always loses time priority. Failure restores the entire previous order. OrderPlaced is emitted again with the reused identifier; indexers must process events in order.
    /// @param orderId Existing order owned by msg.sender, including a fully settled order.
    /// @param tick New aligned, nonmarketable limit tick.
    /// @param lots Positive quantity of the new order, in token0 orderLot units.
    /// @param deadline Last allowed submission timestamp.
    function replaceOrder(uint256 orderId, int24 tick, uint128 lots, uint64 deadline) external;

    /// @notice Segregated AMM and order reserves, including rounding residuals and unclaimed proceeds.
    /// @param id Existing market identifier.
    /// @return amm0 Token0 backing LP principal, unclaimed fees and AMM rounding residue.
    /// @return amm1 Token1 backing LP principal, unclaimed fees and AMM rounding residue.
    /// @return orders0 Token0 backing order collateral, unclaimed proceeds and rounding residue.
    /// @return orders1 Token1 backing order collateral, unclaimed proceeds and rounding residue.
    function reserves(bytes32 id) external view returns (uint256 amm0, uint256 amm1, uint256 orders0, uint256 orders1);

    /// @notice Swaps directly from a wallet, pulling only actual input and sending output to the recipient.
    /// @dev Uses the same matching, slippage and fee rules as trade. No prior deposit is needed. The caller approves the input token to this exchange. Internal balances remain unchanged.
    /// @param r Exact-input request, including price, output, deadline and work limits.
    /// @param recipient Output destination; cannot be zero or this exchange.
    /// @return result Actual input, output, fees and source quantities.
    function swapWallet(TradeRequest calldata r, address recipient) external returns (TradeResult memory result);

    /// @notice Deposited obligations across all markets, reduced on verified withdrawals; excludes donations.
    /// @param token ERC20 asset whose balance, liabilities or fees are queried.
    /// @return amount Deposited obligations across all markets, reduced on verified withdrawals; excludes donations.
    function totalLiability(address token) external view returns (uint256 amount);

    /// @notice Executes AMM intervals before FIFO orders at their endpoints, with one cumulative taker fee.
    /// @dev maxSteps bounds attempted initialized-boundary/order visits, including zero-liquidity jumps. Unspent input remains in the caller's free balance. FOK requires spending all maxInput. Empty tails do not move spot to a price limit without a boundary or executable order.
    /// @param r Exact-input request with gross budget, inclusive price limit, output and work protections.
    /// @return result Actual gross input, output, fee, net source inputs and attempted matching steps.
    function trade(TradeRequest calldata r) external returns (TradeResult memory result);

    /// @notice Atomically sets target unfilled quantities/prices for up to 64 owned orders in one market.
    /// @dev Each 43-byte record is abi.encodePacked(uint256 orderId, int24 tick, uint64 lots), big-endian. Zero lots cancels the remainder and requires tick=0. Every record claims previous fills. Same-price reductions/no-ops preserve FIFO priority; increases or price changes append anew. Records execute sequentially, including duplicate IDs. Invalid records revert the whole batch. Existing IDs only; creates no new identifiers. Compatible with executeWallet net settlement.
    /// @param id Existing market shared by every order in this batch.
    /// @param updates One to 64 complete packed records, with no trailing bytes.
    /// @param deadline Last allowed submission timestamp, checked once for the entire batch.
    function updateOrders(bytes32 id, bytes calldata updates, uint64 deadline) external;

    /// @notice Withdraws only the caller's unlocked funds.
    /// @param token Asset to withdraw from the caller's free balance.
    /// @param amount Positive number of token atoms to transfer.
    /// @param recipient Destination; cannot be zero or this contract.
    function withdraw(address token, uint256 amount, address recipient) external;

    /// @notice An exact token transfer credited an owner's internal balance.
    event Deposited(address indexed owner, address indexed token, uint256 amount);

    /// @notice Whole LP fees were credited internally, including during a liquidity change.
    event FeesCollected(uint256 indexed positionId, uint256 amount0, uint256 amount1);

    /// @notice LP principal changed by signed liquidity delta; amounts are token atoms.
    event LiquidityChanged(uint256 indexed positionId, int128 delta, uint256 amount0, uint256 amount1);

    /// @notice A new immutable market was initialized.
    event MarketCreated(bytes32 indexed marketId, Config config);

    /// @notice Unfilled lots were cancelled and collateral was credited internally.
    event OrderCancelled(uint256 indexed orderId, uint128 lots, uint256 refund);

    /// @notice Executed lots were claimed and proceeds were credited internally.
    event OrderClaimed(uint256 indexed orderId, uint128 lots, uint256 proceeds);

    /// @notice A funded post-only order entered the FIFO queue.
    event OrderPlaced(
        uint256 indexed orderId, bytes32 indexed marketId, address indexed owner, bool ask, int24 tick, uint128 lots
    );

    /// @notice A new persistent, nontransferable LP position was created.
    event PositionCreated(
        uint256 indexed positionId, bytes32 indexed marketId, address indexed owner, int24 lower, int24 upper
    );

    /// @notice Recorded protocol fees were transferred to a recipient.
    event ProtocolCollected(address indexed token, address indexed recipient, uint256 amount);

    /// @notice A hybrid trade executed for the caller, using internal or direct wallet settlement.
    event Traded(bytes32 indexed marketId, address indexed owner, bool zeroForOne, TradeResult result);

    /// @notice An owner's internal balance was sent to an external recipient.
    event Withdrawn(address indexed owner, address indexed token, address recipient, uint256 amount);

    /// @notice The batch contains more than 64 calls.
    error BatchTooLarge();

    /// @notice The submission timestamp is later than the supplied deadline.
    error DeadlineExpired();

    /// @notice A fill-or-kill trade could not spend the entire gross input budget.
    error IncompleteFill();

    /// @notice Free balance or protocol allocation is insufficient.
    error InsufficientBalance();

    /// @notice Quantity is zero, outside its domain, or the trade executes no input.
    error InvalidAmount();

    /// @notice Market configuration violates token, grid, fee or lot constraints.
    error InvalidConfiguration();

    /// @notice Quote updates are empty, malformed, noncanonical, or reference another market.
    error InvalidOrderUpdates();

    /// @notice Order tick or trade limit violates the grid, domain or trading direction.
    error InvalidPrice();

    /// @notice Quantity is zero, exceeds available lots or exceeds the uint64 aggregate capacity.
    error InvalidQuantity();

    /// @notice Recipient or credited owner is zero or the exchange itself.
    error InvalidRecipient();

    /// @notice Tick or spacing is outside its domain, or membership is changed at an unaligned tick.
    error InvalidTick();

    /// @notice An identical immutable market configuration already exists.
    error MarketExists();

    /// @notice A post-only order crosses the curve spot or an opposing ordinary order.
    error MarketableOrder();

    /// @notice Successful quote payload; quoteTrade always reverts so all simulated matching is rolled back.
    /// @param result Simulated fill, fee allocation and work count; no matching state commits.
    error QuoteResult(TradeResult result);

    /// @notice Unauthorized reentrant call.
    error ReentrancyGuardReentrantCall();

    /// @notice An operation with an ERC-20 token failed.
    error SafeERC20FailedOperation(address token);

    /// @notice A principal input/output or trade output protection was violated.
    error Slippage();

    /// @notice Caller does not own the position/order or is not the protocol collector.
    error Unauthorized();

    /// @notice The requested market has not been created.
    error UnknownMarket();

    /// @notice Asset is not a deployed contract or its transfer violates exact balance deltas.
    error UnsupportedToken();
}
