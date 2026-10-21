// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Standalone ABI for RangeBookRouter.
interface IRangeBookRouter {
    struct ExactInputParams {
        /// @notice ERC20 input asset; use the wrapped-token address even when paying native currency.
        address tokenIn;
        /// @notice One to eight asset-connected hops with distinct market IDs; every hop must fully spend its input.
        Hop[] path;
        /// @notice Output recipient; zero, core and this router are forbidden.
        address recipient;
        /// @notice Maximum gross input atoms, including the market trading fee.
        uint128 amountIn;
        /// @notice Minimum output atoms; checked against actual execution, including partial fills.
        uint256 amountOutMinimum;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
        /// @notice Deliver the configured wrapped-native output as native currency.
        bool unwrapNative;
    }

    struct Hop {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice ERC20 output asset of this hop; must be the other token in its market.
        address tokenOut;
        /// @notice Q64.96 directional price bound; zero selects the permitted domain endpoint.
        uint160 sqrtPriceLimitX96;
        /// @notice Positive matching-work limit, counting curve boundaries and order-level steps.
        uint32 maxSteps;
    }

    struct ExactInputSingleParams {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice ERC20 input asset; use the wrapped-token address even when paying native currency.
        address tokenIn;
        /// @notice Output recipient; zero, core and this router are forbidden.
        address recipient;
        /// @notice Maximum gross input atoms, including the market trading fee.
        uint128 amountIn;
        /// @notice Minimum output atoms; checked against actual execution, including partial fills.
        uint256 amountOutMinimum;
        /// @notice Q64.96 directional price bound; zero selects the permitted domain endpoint.
        uint160 sqrtPriceLimitX96;
        /// @notice Positive matching-work limit, counting curve boundaries and order-level steps.
        uint32 maxSteps;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
        /// @notice Whether unused single-hop input may be refunded instead of reverting an incomplete fill.
        bool allowPartial;
        /// @notice Deliver the configured wrapped-native output as native currency.
        bool unwrapNative;
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

    struct Permit {
        /// @notice Permit signature expiration in Unix seconds, separate from the swap deadline.
        uint256 deadline;
        /// @notice EIP-2612 signature recovery identifier.
        uint8 v;
        /// @notice EIP-2612 signature r component.
        bytes32 r;
        /// @notice EIP-2612 signature s component.
        bytes32 s;
    }

    /// @notice Immutable trusted exchange used for all operations.
    /// @return arg0 Immutable trusted exchange used for all operations.
    function core() external view returns (address arg0);

    /// @notice Executes 1–8 distinct-market hops atomically; every hop must spend its entire input.
    /// @param p Connected path, gross input, final minimum output, recipient and deadline.
    /// @return amountOut Final output atoms delivered to the recipient.
    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut);

    /// @notice Swaps from the caller wallet; refunds unspent input only when allowPartial is true.
    /// @param p Limits, recipient and market. A zero price limit selects the directional domain endpoint.
    /// @return result Actual gross input, output, fee, source principal and work count.
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (TradeResult memory result);

    /// @notice EIP-2612 approval and swap in one call; tolerates an already-consumed permit if allowance suffices.
    /// @param p Wallet swap parameters; native payment must not be supplied.
    /// @param permit Signature authorizing this router to spend p.amountIn from msg.sender.
    /// @return result Actual execution breakdown.
    function exactInputSingleWithPermit(ExactInputSingleParams calldata p, Permit calldata permit)
        external
        returns (TradeResult memory result);

    /// @notice Immutable trusted wrapped-native asset; address zero disables native payment support.
    /// @return arg0 Immutable trusted wrapped-native asset; address zero disables native payment support.
    function wrappedNative() external view returns (address arg0);

    /// @notice Per-hop execution including fee and AMM/order principal attribution.
    /// @param marketId Executed market.
    /// @param sender Wallet payer for the complete route.
    /// @param result Per-hop actual amounts, fee, source principal and work count.
    event HopExecuted(bytes32 indexed marketId, address indexed sender, TradeResult result);

    /// @notice Wallet-facing swap attribution; routeHash commits to the requested market/path.
    /// @param sender Wallet payer that called the router.
    /// @param recipient Final output recipient.
    /// @param routeHash keccak256 of abi.encode(marketId) for single-hop, or abi.encode(path) for multi-hop.
    /// @param tokenIn Route input token address.
    /// @param tokenOut Route final output token address.
    /// @param amountIn Actual gross input atoms spent.
    /// @param amountOut Final output atoms delivered.
    event SwapExecuted(
        address indexed sender,
        address indexed recipient,
        bytes32 indexed routeHash,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice A supplied deployment address, recipient or token is invalid.
    error InvalidAddress();

    /// @notice Native value does not match the declared wrapped-native input.
    error InvalidNativeValue();

    /// @notice Path is empty, too long, repeats a market, has disconnected assets or exceeds the input domain.
    error InvalidPath();

    /// @notice A recipient rejected a native-currency transfer.
    error NativeTransferFailed();

    /// @notice A requested input, output or liquidity limit was violated.
    error PeripherySlippage();

    /// @notice Unauthorized reentrant call.
    error ReentrancyGuardReentrantCall();

    /// @notice An operation with an ERC-20 token failed.
    error SafeERC20FailedOperation(address token);

    /// @notice Token transfer or wrapping does not deliver exactly the requested amount.
    error UnsupportedAsset();
}
