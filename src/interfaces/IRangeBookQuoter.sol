// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Standalone ABI for RangeBookQuoter.
interface IRangeBookQuoter {
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

    /// @notice Immutable exchange whose quote revert payload is decoded.
    /// @return arg0 Immutable exchange whose quote revert payload is decoded.
    function core() external view returns (address arg0);

    /// @notice Quotes distinct-market exact-input paths; repeated markets are rejected in both router and quoter.
    /// @dev Distinct markets have independent matching state, so per-hop rollback preserves route equivalence.
    /// @param p Connected router path and final output protection.
    /// @return amountOut Final token output.
    /// @return results Per-hop execution breakdowns in path order.
    function quoteExactInput(ExactInputParams calldata p)
        external
        returns (uint256 amountOut, TradeResult[] memory results);

    /// @notice Quotes a wallet single-hop request without moving funds or checking wallet allowances.
    /// @param p Router parameters. Recipient and native-delivery compatibility are checked by the router at execution.
    /// @return result Simulated execution breakdown.
    function quoteExactInputSingle(ExactInputSingleParams calldata p) external returns (TradeResult memory result);

    /// @notice Quotes a core request with its exact fill, slippage, deadline and work-limit semantics.
    /// @param request Exact-input trade request; no balances or approvals are needed.
    /// @return result Simulated input, output, fees, source quantities and work.
    function quoteTrade(TradeRequest calldata request) external returns (TradeResult memory result);

    /// @notice The core address is not a deployed contract.
    error InvalidCore();

    /// @notice Path assets, length, repeated markets or intermediate amount are invalid.
    error InvalidPath();

    /// @notice A simulation unexpectedly succeeded or returned a malformed quote payload.
    error InvalidQuoteResponse();
}
