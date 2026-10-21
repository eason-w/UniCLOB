// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Standalone ABI for ConcentratedRangeBookLens.
interface IConcentratedRangeBookLens {
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

    /// @notice Immutable exchange being inspected.
    /// @return arg0 Immutable exchange being inspected.
    function core() external view returns (address arg0);

    /// @notice Returns up to 128 live ordinary levels in best-to-worst order from an inclusive tick.
    /// @dev Pin a block tag across pages. Resume with last tick +1 for asks, -1 for bids; an empty page ends iteration.
    /// @param marketId Existing market.
    /// @param ask True walks asks upward, false walks bids downward.
    /// @param from Inclusive starting tick; use -887272 for all asks or 887272 for all bids.
    /// @param limit Maximum number of levels, 1–128.
    /// @return ticks Aggregate unfilled base lots at each tick; does not include AMM inventory.
    /// @return lots Exactly the returned level ticks, without padding.
    function orderDepth(bytes32 marketId, bool ask, int24 from, uint16 limit)
        external
        view
        returns (int24[] memory ticks, uint128[] memory lots);

    /// @notice Reads metadata and fill progress for up to 128 known order IDs.
    /// @param ids Order identifiers discovered from owner-filtered OrderPlaced logs.
    /// @return orders Executed, unclaimed base lots; use core claim simulation for token proceeds.
    /// @return remaining Core order metadata in requested order.
    /// @return claimable Unfilled base lots.
    function ordersById(uint256[] calldata ids)
        external
        view
        returns (Order[] memory orders, uint128[] memory remaining, uint128[] memory claimable);

    /// @notice Converts desired wallet amounts to liquidity and rounded-up principal at the current market price.
    /// @param marketId Existing market.
    /// @param lower Aligned lower tick.
    /// @param upper Aligned upper tick.
    /// @param desired0 Token0 budget.
    /// @param desired1 Token1 budget.
    /// @return liquidity Required token0 principal.
    /// @return amount0 Required token1 principal.
    /// @return amount1 Supported liquidity L; endpoint capacity is checked at execution, not in this preview.
    function quoteLiquidity(bytes32 marketId, int24 lower, int24 upper, uint256 desired0, uint256 desired1)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Range or calculated liquidity is outside the core's supported domain.
    error InvalidLiquidityAmounts();

    /// @notice Invalid core address, range alignment or page size.
    error InvalidQuery();
}
