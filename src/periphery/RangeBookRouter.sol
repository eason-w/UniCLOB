// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { TickMath } from "../vendor/uniswap/TickMath.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { PeripheryPayments } from "./PeripheryPayments.sol";

/// @notice Exact-input routing with explicit payer attribution, native wrapping and exact call-local refunds.
/// @dev No arbitrary calls, persistent user custody or shared-balance sweeps. Approve this router, not another user.
contract RangeBookRouter is PeripheryPayments {
    /// @notice One market in an exact-input route.
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

    /// @notice Wallet-funded single-hop limits and settlement preferences.
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

    /// @notice Atomic multi-hop exact-input route with a final output minimum.
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

    /// @notice EIP-2612 signature authorizing this router for the caller input.
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
    /// @notice Path is empty, too long, repeats a market, has disconnected assets or exceeds the input domain.
    error InvalidPath();
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
    /// @notice Per-hop execution including fee and AMM/order principal attribution.
    /// @param marketId Executed market.
    /// @param sender Wallet payer for the complete route.
    /// @param result Per-hop actual amounts, fee, source principal and work count.
    event HopExecuted(bytes32 indexed marketId, address indexed sender, Book.TradeResult result);

    /// @notice Deploys a router for one immutable core and optional wrapped-native token.
    /// @param book Trusted deployed exchange.
    /// @param wrapped WETH-compatible token or zero.
    constructor(Book book, address wrapped) PeripheryPayments(book, wrapped) { }

    /// @notice Swaps from the caller wallet; refunds unspent input only when allowPartial is true.
    /// @param p Limits, recipient and market. A zero price limit selects the directional domain endpoint.
    /// @return result Actual gross input, output, fee, source principal and work count.
    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        nonReentrant
        returns (Book.TradeResult memory result)
    {
        return _single(p);
    }

    /// @notice EIP-2612 approval and swap in one call; tolerates an already-consumed permit if allowance suffices.
    /// @param p Wallet swap parameters; native payment must not be supplied.
    /// @param permit Signature authorizing this router to spend p.amountIn from msg.sender.
    /// @return result Actual execution breakdown.
    function exactInputSingleWithPermit(ExactInputSingleParams calldata p, Permit calldata permit)
        external
        nonReentrant
        returns (Book.TradeResult memory result)
    {
        try IERC20Permit(p.tokenIn)
            .permit(msg.sender, address(this), p.amountIn, permit.deadline, permit.v, permit.r, permit.s) { }
            catch { }
        return _single(p);
    }

    /// @dev Funds, executes and settles one protected swap; pre-existing balances never enter refunds.
    function _single(ExactInputSingleParams calldata p) private returns (Book.TradeResult memory result) {
        _recipient(p.recipient);
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c,,,) = core.getMarket(p.marketId);
        bool down = p.tokenIn == c.token0;
        if (!down && p.tokenIn != c.token1) revert InvalidPath();
        address output = down ? c.token1 : c.token0;
        if (p.unwrapNative && (output != wrappedNative || wrappedNative == address(0))) revert InvalidNativeValue();
        _fund(p.tokenIn, p.amountIn);
        Book.TradeRequest memory r = Book.TradeRequest(
            p.marketId,
            down,
            p.amountIn,
            _limit(down, p.sqrtPriceLimitX96),
            p.amountOutMinimum,
            p.maxSteps,
            p.deadline,
            !p.allowPartial
        );
        result = core.swapWallet(r, p.unwrapNative ? address(this) : p.recipient);
        _pay(p.tokenIn, msg.sender, uint256(p.amountIn) - result.input, msg.value != 0);
        if (p.unwrapNative) _pay(output, p.recipient, result.output, true);
        emit HopExecuted(p.marketId, msg.sender, result);
        emit SwapExecuted(
            msg.sender, p.recipient, keccak256(abi.encode(p.marketId)), p.tokenIn, output, result.input, result.output
        );
    }

    /// @notice Executes 1–8 distinct-market hops atomically; every hop must spend its entire input.
    /// @param p Connected path, gross input, final minimum output, recipient and deadline.
    /// @return amountOut Final output atoms delivered to the recipient.
    function exactInput(ExactInputParams calldata p) external payable nonReentrant returns (uint256 amountOut) {
        _recipient(p.recipient);
        uint256 count = p.path.length;
        if (count == 0 || count > 8) revert InvalidPath();
        address output = p.path[count - 1].tokenOut;
        if (p.unwrapNative && (output != wrappedNative || wrappedNative == address(0))) revert InvalidNativeValue();
        _fund(p.tokenIn, p.amountIn);
        address input = p.tokenIn;
        uint256 amount = p.amountIn;
        for (uint256 i; i < count; ++i) {
            Hop calldata hop = p.path[i];
            for (uint256 j; j < i; ++j) {
                if (p.path[j].marketId == hop.marketId) revert InvalidPath();
            }
            if (amount == 0 || amount > type(uint128).max) revert InvalidPath();
            // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
            // slither-disable-next-line unused-return
            (Book.Config memory c,,,) = core.getMarket(hop.marketId);
            bool down = input == c.token0 && hop.tokenOut == c.token1;
            if (!down && !(input == c.token1 && hop.tokenOut == c.token0)) revert InvalidPath();
            // _fund already approved the first input; later hops may introduce new assets.
            if (i != 0) _approveCore(input, amount);
            bool last = i + 1 == count;
            Book.TradeResult memory result = core.swapWallet(
                Book.TradeRequest(
                    hop.marketId,
                    down,
                    uint128(amount),
                    _limit(down, hop.sqrtPriceLimitX96),
                    last ? p.amountOutMinimum : 0,
                    hop.maxSteps,
                    p.deadline,
                    true
                ),
                last && !p.unwrapNative ? p.recipient : address(this)
            );
            amount = result.output;
            input = hop.tokenOut;
            emit HopExecuted(hop.marketId, msg.sender, result);
        }
        amountOut = amount;
        if (p.unwrapNative) _pay(output, p.recipient, amountOut, true);
        emit SwapExecuted(
            msg.sender, p.recipient, keccak256(abi.encode(p.path)), p.tokenIn, output, p.amountIn, amountOut
        );
    }

    /// @dev Accepts exact native value or pulls caller ERC20 input, then authorizes the immutable core.
    function _fund(address token, uint128 amount) private {
        if (amount == 0) revert InvalidPath();
        if (msg.value != 0) {
            if (token != wrappedNative || wrappedNative == address(0) || msg.value != amount) {
                revert InvalidNativeValue();
            }
            _wrap(amount);
        } else {
            _pull(token, amount);
        }
        _approveCore(token, amount);
    }

    /// @dev Expands a zero sentinel to the directional core endpoint; explicit limits pass through unchanged.
    function _limit(bool down, uint160 price) private pure returns (uint160) {
        return price == 0 ? (down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1) : price;
    }
}
