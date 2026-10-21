// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FullMath } from "../vendor/uniswap/FullMath.sol";
import { SqrtPriceMath } from "../vendor/uniswap/SqrtPriceMath.sol";
import { TickMath } from "../vendor/uniswap/TickMath.sol";

/// @notice Converts wallet token budgets into conservative Uniswap-style liquidity L.
library LiquidityAmounts {
    /// @notice Range or calculated liquidity is outside the core's supported domain.
    error InvalidLiquidityAmounts();

    /// @notice Computes liquidity supported by both desired amounts and rounded-up principal costs.
    /// @param price Current Q64.96 square-root price.
    /// @param lower Inclusive lower tick.
    /// @param upper Exclusive upper tick.
    /// @param desired0 Maximum token0 atoms.
    /// @param desired1 Maximum token1 atoms.
    /// @return liquidity Positive L bounded by int128.max.
    /// @return amount0 Required token0 principal, rounded up.
    /// @return amount1 Required token1 principal, rounded up.
    function forAmounts(uint160 price, int24 lower, int24 upper, uint256 desired0, uint256 desired1)
        internal
        pure
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (lower >= upper) revert InvalidLiquidityAmounts();
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 value;
        if (price <= a) {
            value = _for0(a, b, desired0);
        } else if (price >= b) {
            value = FullMath.mulDiv(desired1, 1 << 96, b - a);
        } else {
            uint256 l0 = _for0(price, b, desired0);
            uint256 l1 = FullMath.mulDiv(desired1, 1 << 96, price - a);
            value = l0 < l1 ? l0 : l1;
        }
        if (value == 0 || value > uint128(type(int128).max)) revert InvalidLiquidityAmounts();
        liquidity = uint128(value);
        if (price < b) amount0 = SqrtPriceMath.getAmount0Delta(price < a ? a : price, b, liquidity, true);
        if (price > a) amount1 = SqrtPriceMath.getAmount1Delta(a, price > b ? b : price, liquidity, true);
        if (amount0 > desired0 || amount1 > desired1) revert InvalidLiquidityAmounts();
    }

    /// @dev Computes floor(amount * a * b / ((b-a) * Q96)) while retaining both division remainders.
    function _for0(uint160 a, uint160 b, uint256 amount) private pure returns (uint256) {
        // Exact floor(amount * a * b / ((b-a) * Q96)), without rounding a*b/Q96 to zero
        // at small prices. Write amount*a = q*(b-a)+r; retain both division remainders.
        uint256 d = b - a;
        uint256 q = FullMath.mulDiv(amount, a, d);
        uint256 base = FullMath.mulDiv(q, b, 1 << 96);
        uint256 tail = FullMath.mulDiv(mulmod(amount, a, d), b, d);
        return base + (mulmod(q, b, 1 << 96) + tail) / (1 << 96);
    }
}
