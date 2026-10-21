// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { LiquidityAmounts } from "./LiquidityAmounts.sol";

/// @notice Bounded UI reads for the concentrated core; ordinary depth is separate from the continuous curve.
contract ConcentratedRangeBookLens {
    /// @notice Immutable exchange being inspected.
    Book public immutable core;
    /// @notice Invalid core address, range alignment or page size.
    error InvalidQuery();

    /// @notice Configures the read-only lens.
    /// @param book Deployed concentrated core.
    constructor(Book book) {
        if (address(book).code.length == 0) revert InvalidQuery();
        core = book;
    }

    /// @notice Returns up to 128 live ordinary levels in best-to-worst order from an inclusive tick.
    /// @dev Pin a block tag across pages. Resume with last tick +1 for asks, -1 for bids; an empty page ends iteration.
    /// @param marketId Existing market.
    /// @param ask True walks asks upward, false walks bids downward.
    /// @param from Inclusive starting tick; use -887272 for all asks or 887272 for all bids.
    /// @param limit Maximum number of levels, 1–128.
    /// @return ticks Exactly the returned level ticks, without padding.
    /// @return lots Aggregate unfilled base lots at each tick; does not include AMM inventory.
    function orderDepth(bytes32 marketId, bool ask, int24 from, uint16 limit)
        external
        view
        returns (int24[] memory ticks, uint128[] memory lots)
    {
        if (limit == 0 || limit > 128) revert InvalidQuery();
        ticks = new int24[](limit);
        lots = new uint128[](limit);
        uint256 count;
        while (count < limit) {
            (bool found, int24 tick, uint128 quantity) = core.nextOrderLevel(marketId, ask, from);
            if (!found) break;
            ticks[count] = tick;
            lots[count++] = quantity;
            from = ask ? tick + int24(1) : tick - int24(1);
        }
        assembly ("memory-safe") {
            mstore(ticks, count)
            mstore(lots, count)
        }
    }

    /// @notice Converts desired wallet amounts to liquidity and rounded-up principal at the current market price.
    /// @param marketId Existing market.
    /// @param lower Aligned lower tick.
    /// @param upper Aligned upper tick.
    /// @param desired0 Token0 budget.
    /// @param desired1 Token1 budget.
    /// @return liquidity Supported liquidity L; endpoint capacity is checked at execution, not in this preview.
    /// @return amount0 Required token0 principal.
    /// @return amount1 Required token1 principal.
    function quoteLiquidity(bytes32 marketId, int24 lower, int24 upper, uint256 desired0, uint256 desired1)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c, uint160 price,,) = core.getMarket(marketId);
        if (lower % c.tickSpacing != 0 || upper % c.tickSpacing != 0) revert InvalidQuery();
        (liquidity, amount0, amount1) = LiquidityAmounts.forAmounts(price, lower, upper, desired0, desired1);
    }

    /// @notice Reads metadata and fill progress for up to 128 known order IDs.
    /// @param ids Order identifiers discovered from owner-filtered OrderPlaced logs.
    /// @return orders Core order metadata in requested order.
    /// @return remaining Unfilled base lots.
    /// @return claimable Executed, unclaimed base lots; use core claim simulation for token proceeds.
    function ordersById(uint256[] calldata ids)
        external
        view
        returns (Book.Order[] memory orders, uint128[] memory remaining, uint128[] memory claimable)
    {
        if (ids.length > 128) revert InvalidQuery();
        orders = new Book.Order[](ids.length);
        remaining = new uint128[](ids.length);
        claimable = new uint128[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            (orders[i], remaining[i], claimable[i]) = core.getOrder(ids[i]);
        }
    }
}
