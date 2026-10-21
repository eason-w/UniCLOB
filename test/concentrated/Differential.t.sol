// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, TickMath, FeeMath } from "./Base.sol";
import { Pool } from "../reference/uniswap-v4/libraries/Pool.sol";
import { Slot0, Slot0Library } from "../reference/uniswap-v4/types/Slot0.sol";
import { BalanceDelta } from "../reference/uniswap-v4/types/BalanceDelta.sol";

/// @notice Differential tests against the unmodified v4.0.0 Pool library.
/// @dev Reference uses zero fees and the hybrid's net principal to isolate curve/accounting correctness.
contract ConcentratedDifferentialTest is ConcentratedBase {
    using Pool for Pool.State;
    using Slot0Library for Slot0;
    Pool.State internal referencePool;

    function setUp() public override {
        super.setUp();
        referencePool.initialize(Q96, 0);
    }

    function referenceMint(int24 lower, int24 upper, uint128 liquidity) internal returns (BalanceDelta d) {
        (d,) = referencePool.modifyLiquidity(
            Pool.ModifyLiquidityParams(address(this), lower, upper, int128(liquidity), 60, 0)
        );
    }

    function testFuzz_MintPrincipalMatchesUniswap(int24 lowerRaw, int24 upperRaw, uint128 liquidity) public {
        int24 low = int24(bound(lowerRaw, -14_787, 14_786)) * 60;
        int24 high = int24(bound(upperRaw, low / 60 + 1, 14_787)) * 60;
        // Keep the entire extreme-price domain within the reference's int128 token delta.
        liquidity = uint128(bound(liquidity, 1000, 1e15));
        BalanceDelta d = referenceMint(low, high, liquidity);
        vm.prank(lp);
        (, uint256 a, uint256 b) = book.mint(market, low, high, liquidity, type(uint256).max, type(uint256).max, NEVER);
        assertEq(a, uint128(-d.amount0()));
        assertEq(b, uint128(-d.amount1()));
    }

    function testFuzz_FullRangeSwapMatchesUniswapCurve(bool down, uint128 raw) public {
        uint128 input = uint128(bound(raw, 1000, 1e26));
        full(lp, L);
        (int24 low, int24 high) = book.fullRange(market);
        referenceMint(low, high, L);
        Book.TradeResult memory actual = trade(down, input);
        (BalanceDelta d,,,) = referencePool.swap(
            Pool.SwapParams(
                -int256(actual.ammInput), 60, down, down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, 0
            )
        );
        uint256 output = uint128(down ? d.amount1() : d.amount0());
        // Upstream stops at empty bitmap-word edges and rounds each step; this implementation
        // skips those edges. Bound the resulting atom-level difference, not a percentage.
        assertApproxEqAbs(actual.output, output, 100);
        (, uint160 price,,) = book.getMarket(market);
        assertApproxEqAbs(price, referencePool.slot0.sqrtPriceX96(), 1e9);
        assertAccounting();
    }

    function test_OverlappingCrossingsAndBurnMatchUniswapPrincipal() public {
        uint256 a = mint(lp, -600, 600, L);
        uint256 b = mint(lp2, -120, 120, L / 2);
        referenceMint(-600, 600, L);
        referenceMint(-120, 120, L / 2);
        Book.TradeResult memory first = trade(false, 1e22);
        referencePool.swap(Pool.SwapParams(-int256(first.ammInput), 60, false, TickMath.MAX_SQRT_PRICE - 1, 0));
        Book.TradeResult memory second = trade(true, 2e22);
        referencePool.swap(Pool.SwapParams(-int256(second.ammInput), 60, true, TickMath.MIN_SQRT_PRICE + 1, 0));
        (BalanceDelta d,) =
            referencePool.modifyLiquidity(Pool.ModifyLiquidityParams(address(this), -120, 120, -int128(L / 2), 60, 0));
        vm.prank(lp2);
        (uint256 x, uint256 y) = book.burn(b, L / 2, 0, 0, NEVER);
        assertApproxEqAbs(x, uint128(d.amount0()), 10);
        assertApproxEqAbs(y, uint128(d.amount1()), 10);
        (d,) = referencePool.modifyLiquidity(Pool.ModifyLiquidityParams(address(this), -600, 600, -int128(L), 60, 0));
        vm.prank(lp);
        (x, y) = book.burn(a, L, 0, 0, NEVER);
        assertApproxEqAbs(x, uint128(d.amount0()), 10);
        assertApproxEqAbs(y, uint128(d.amount1()), 10);
        assertAccounting();
    }
}
