// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { RangeBookRouter as Router } from "./RangeBookRouter.sol";
import { TickMath } from "../vendor/uniswap/TickMath.sol";

/// @notice Funding-free eth_call quotes from the production matcher, including FIFO levels and fee rounding.
/// @dev Deliberately non-view: each core simulation writes then reverts. Quotes are not execution guarantees.
contract RangeBookQuoter {
    /// @notice Immutable exchange whose quote revert payload is decoded.
    Book public immutable core;
    /// @notice The core address is not a deployed contract.
    error InvalidCore();
    /// @notice A simulation unexpectedly succeeded or returned a malformed quote payload.
    error InvalidQuoteResponse();
    /// @notice Path assets, length, repeated markets or intermediate amount are invalid.
    error InvalidPath();

    /// @notice Configures the immutable trusted matcher.
    /// @param book Deployed exchange exposing quoteTrade.
    constructor(Book book) {
        if (address(book).code.length == 0) revert InvalidCore();
        core = book;
    }

    /// @notice Quotes a core request with its exact fill, slippage, deadline and work-limit semantics.
    /// @param request Exact-input trade request; no balances or approvals are needed.
    /// @return result Simulated input, output, fees, source quantities and work.
    function quoteTrade(Book.TradeRequest calldata request) external returns (Book.TradeResult memory result) {
        return _quote(request);
    }

    /// @notice Quotes a wallet single-hop request without moving funds or checking wallet allowances.
    /// @param p Router parameters. Recipient and native-delivery compatibility are checked by the router at execution.
    /// @return result Simulated execution breakdown.
    function quoteExactInputSingle(Router.ExactInputSingleParams calldata p)
        external
        returns (Book.TradeResult memory result)
    {
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c,,,) = core.getMarket(p.marketId);
        bool down = p.tokenIn == c.token0;
        if (!down && p.tokenIn != c.token1) revert InvalidPath();
        return _quote(
            Book.TradeRequest(
                p.marketId,
                down,
                p.amountIn,
                _limit(down, p.sqrtPriceLimitX96),
                p.amountOutMinimum,
                p.maxSteps,
                p.deadline,
                !p.allowPartial
            )
        );
    }

    /// @notice Quotes distinct-market exact-input paths; repeated markets are rejected in both router and quoter.
    /// @dev Distinct markets have independent matching state, so per-hop rollback preserves route equivalence.
    /// @param p Connected router path and final output protection.
    /// @return amountOut Final token output.
    /// @return results Per-hop execution breakdowns in path order.
    function quoteExactInput(Router.ExactInputParams calldata p)
        external
        returns (uint256 amountOut, Book.TradeResult[] memory results)
    {
        uint256 count = p.path.length;
        if (count == 0 || count > 8) revert InvalidPath();
        results = new Book.TradeResult[](count);
        address input = p.tokenIn;
        amountOut = p.amountIn;
        for (uint256 i; i < count; ++i) {
            Router.Hop calldata hop = p.path[i];
            for (uint256 j; j < i; ++j) {
                if (p.path[j].marketId == hop.marketId) revert InvalidPath();
            }
            if (amountOut == 0 || amountOut > type(uint128).max) revert InvalidPath();
            // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
            // slither-disable-next-line unused-return
            (Book.Config memory c,,,) = core.getMarket(hop.marketId);
            bool down = input == c.token0 && hop.tokenOut == c.token1;
            if (!down && !(input == c.token1 && hop.tokenOut == c.token0)) revert InvalidPath();
            results[i] = _quote(
                Book.TradeRequest(
                    hop.marketId,
                    down,
                    uint128(amountOut),
                    _limit(down, hop.sqrtPriceLimitX96),
                    i + 1 == count ? p.amountOutMinimum : 0,
                    hop.maxSteps,
                    p.deadline,
                    true
                )
            );
            input = hop.tokenOut;
            amountOut = results[i].output;
        }
    }

    /// @dev Runs the core rollback simulation, checks its typed payload and decodes the six-word result.
    function _quote(Book.TradeRequest memory request) private returns (Book.TradeResult memory result) {
        (bool success, bytes memory data) = address(core).call(abi.encodeCall(Book.quoteTrade, (request)));
        if (success) revert InvalidQuoteResponse();
        bytes4 selector;
        if (data.length >= 4) assembly ("memory-safe") { selector := mload(add(data, 32)) }
        if (selector != Book.QuoteResult.selector) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        if (data.length != 196) revert InvalidQuoteResponse();
        bytes memory payload = new bytes(192);
        assembly ("memory-safe") {
            mcopy(add(payload, 32), add(data, 36), 192)
        }
        result = abi.decode(payload, (Book.TradeResult));
    }

    /// @dev Normalizes the router's zero price sentinel identically to execution.
    function _limit(bool down, uint160 price) private pure returns (uint160) {
        return price == 0 ? (down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1) : price;
    }
}
