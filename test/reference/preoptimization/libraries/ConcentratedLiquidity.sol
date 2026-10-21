// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "../vendor/uniswap/TickMath.sol";
import { SqrtPriceMath } from "../vendor/uniswap/SqrtPriceMath.sol";
import { LiquidityMath } from "../vendor/uniswap/LiquidityMath.sol";
import { TickTree } from "./TickTree.sol";

/// @title ConcentratedLiquidity
/// @notice Endpoint-based concentrated liquidity and fee accounting.
/// @dev Positions touch two endpoints regardless of width. No per-price LP inventory exists.
library ConcentratedLiquidity {
    using TickTree for TickTree.Map;

    uint256 internal constant Q128 = 1 << 128;

    error InvalidRange();
    error InvalidLiquidity();
    error TickCapacity();
    error InvalidInitialPrice();

    struct Tick {
        uint128 gross;
        int128 net;
        uint256 outside0;
        uint256 outside1;
    }

    struct State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 growth0;
        uint256 growth1;
        TickTree.Map initialized;
        mapping(int24 tick => Tick data) ticks;
    }

    struct Position {
        uint128 liquidity;
        uint128 fraction0;
        uint128 fraction1;
        uint256 last0;
        uint256 last1;
    }

    /// @notice Initializes a price strictly inside the supported sqrt-price domain.
    function initialize(State storage self, uint160 price) internal {
        if (price <= TickMath.MIN_SQRT_PRICE || price >= TickMath.MAX_SQRT_PRICE) revert InvalidInitialPrice();
        self.sqrtPriceX96 = price;
        self.tick = TickMath.getTickAtSqrtPrice(price);
    }

    /// @notice Adds/removes liquidity, settling fees before changing ownership.
    /// @return amount0 Principal required on entry or released on exit.
    /// @return amount1 Principal required on entry or released on exit.
    /// @return fees0 Previously earned token0 fees.
    /// @return fees1 Previously earned token1 fees.
    function modify(State storage self, Position storage p, int24 lower, int24 upper, int24 spacing, int128 delta)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % spacing != 0
                || upper % spacing != 0
        ) revert InvalidRange();
        if (delta < 0 && uint128(-delta) > p.liquidity) revert InvalidLiquidity();
        if (delta != 0) {
            _update(self, lower, delta, false, spacing);
            _update(self, upper, delta, true, spacing);
        }
        (fees0, fees1) = checkpoint(self, p, lower, upper);
        if (delta == 0) return (0, 0, fees0, fees1);
        p.liquidity = LiquidityMath.addDelta(p.liquidity, delta);
        bool adding = delta > 0;
        uint128 magnitude = uint128(adding ? delta : -delta);
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        if (self.tick < lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(low, high, magnitude, adding);
        } else if (self.tick >= upper) {
            amount1 = SqrtPriceMath.getAmount1Delta(low, high, magnitude, adding);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(self.sqrtPriceX96, high, magnitude, adding);
            amount1 = SqrtPriceMath.getAmount1Delta(low, self.sqrtPriceX96, magnitude, adding);
            self.liquidity = LiquidityMath.addDelta(self.liquidity, delta);
        }
        // Clear only after calculating inside growth using the old endpoint state.
        if (!adding) {
            if (self.ticks[lower].gross == 0) delete self.ticks[lower];
            if (self.ticks[upper].gross == 0) delete self.ticks[upper];
        }
    }

    /// @notice Realizes fees with fractional carry so repeated collection does not lose fractions.
    function checkpoint(State storage self, Position storage p, int24 lower, int24 upper)
        internal
        returns (uint256 fees0, uint256 fees1)
    {
        (uint256 inside0, uint256 inside1) = inside(self, lower, upper);
        (fees0, p.fraction0) = accrued(p.liquidity, inside0, p.last0, p.fraction0);
        (fees1, p.fraction1) = accrued(p.liquidity, inside1, p.last1, p.fraction1);
        p.last0 = inside0;
        p.last1 = inside1;
    }

    /// @notice Fee growth attributable to an interval, using modular outside-growth arithmetic.
    function inside(State storage self, int24 lower, int24 upper) internal view returns (uint256 x, uint256 y) {
        Tick storage low = self.ticks[lower];
        Tick storage high = self.ticks[upper];
        unchecked {
            if (self.tick < lower) return (low.outside0 - high.outside0, low.outside1 - high.outside1);
            if (self.tick >= upper) return (high.outside0 - low.outside0, high.outside1 - low.outside1);
            return (self.growth0 - low.outside0 - high.outside0, self.growth1 - low.outside1 - high.outside1);
        }
    }

    /// @notice Crosses an initialized boundary after attributing the preceding interval's fees.
    function cross(State storage self, int24 tick, bool zeroForOne) internal {
        Tick storage t = self.ticks[tick];
        unchecked {
            t.outside0 = self.growth0 - t.outside0;
            t.outside1 = self.growth1 - t.outside1;
        }
        self.liquidity = LiquidityMath.addDelta(self.liquidity, zeroForOne ? -t.net : t.net);
        self.tick = zeroForOne ? tick - 1 : tick;
    }

    /// @notice Whole fees plus retained Q128 fractional residue.
    function accrued(uint128 liquidity, uint256 growth, uint256 last, uint128 fraction)
        internal
        pure
        returns (uint256 whole, uint128 remainder)
    {
        uint256 delta;
        unchecked {
            delta = growth - last;
        }
        whole = Math.mulDiv(liquidity, delta, Q128);
        uint256 rest = mulmod(liquidity, delta, Q128) + uint256(fraction);
        whole += rest >> 128;
        remainder = uint128(rest);
    }

    function _update(State storage self, int24 tick, int128 delta, bool upper, int24 spacing) private {
        Tick storage t = self.ticks[tick];
        uint128 before_ = t.gross;
        uint128 after_ = LiquidityMath.addDelta(before_, delta);
        // This conservative cap also bounds total active liquidity and signed boundary deltas.
        uint128 cap = uint128(type(int128).max) / uint128(uint24((TickMath.MAX_TICK - TickMath.MIN_TICK) / spacing + 1));
        if (after_ > cap) revert TickCapacity();
        if (before_ == 0) {
            if (tick <= self.tick) {
                t.outside0 = self.growth0;
                t.outside1 = self.growth1;
            }
            self.initialized.set(tick, true);
        }
        t.gross = after_;
        t.net += upper ? -delta : delta;
        if (after_ == 0) self.initialized.set(tick, false);
    }
}
