// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, CL, TickMath, SqrtPriceMath, SwapMath, FeeMath } from "./Base.sol";
import { TickTree } from "../../src/libraries/TickTree.sol";

contract ConcentratedTest is ConcentratedBase {
    function test_FullRangeUsesOnlyTwoEndpoints() public {
        uint256 id = full(lp, L);
        (int24 low, int24 high) = book.fullRange(market);
        assertEq(low, -887_220);
        assertEq(high, 887_220);
        assertEq(book.getTick(market, low).gross, L);
        assertEq(book.getTick(market, high).gross, L);
        assertEq(book.getTick(market, 0).gross, 0);
        (,,, uint128 active) = book.getMarket(market);
        assertEq(active, L);
        uint256 before0 = book.balanceOf(lp, address(token0));
        uint256 before1 = book.balanceOf(lp, address(token1));
        vm.prank(lp);
        (uint256 x, uint256 y) = book.burn(id, L, 0, 0, NEVER);
        assertEq(book.balanceOf(lp, address(token0)) - before0, x);
        assertEq(book.balanceOf(lp, address(token1)) - before1, y);
        assertEq(book.getTick(market, low).gross, 0);
        assertEq(book.getTick(market, high).gross, 0);
        assertAccounting();
    }

    function test_FullRangeLargeMoveIsOneStep() public {
        full(lp, L);
        Book.TradeResult memory r = trade(false, 1e25);
        assertEq(r.steps, 1);
        assertEq(r.orderInput, 0);
        (, uint160 price, int24 tick,) = book.getMarket(market);
        assertGt(tick, 47_000);
        assertGt(price, Q96);
        assertAccounting();
    }

    function test_AMMExecutesBeforeOrderAndResumesAfterIt() public {
        full(lp, L);
        uint256 oid = order(true, 60, 1e8);
        uint256 toOrder = SqrtPriceMath.getAmount1Delta(Q96, TickMath.getSqrtPriceAtTick(60), L, true);
        Book.TradeResult memory before_ = trade(false, uint128(FeeMath.gross(toOrder / 2, 3000)));
        assertEq(before_.orderInput, 0);
        (, uint128 remaining,) = book.getOrder(oid);
        assertEq(remaining, 1e8);
        Book.TradeResult memory after_ = trade(false, 1e22);
        assertGt(after_.ammInput, 0);
        assertGt(after_.orderInput, 0);
        (, remaining,) = book.getOrder(oid);
        assertEq(remaining, 0);
        (, uint160 price,,) = book.getMarket(market);
        assertGt(price, TickMath.getSqrtPriceAtTick(60));
        vm.prank(maker);
        book.claimOrder(oid);
        assertAccounting();
    }

    function test_DownwardAMMBeforeBid() public {
        full(lp, L);
        uint256 oid = order(false, -60, 1e8);
        uint256 toOrder = SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(-60), Q96, L, true);
        assertEq(trade(true, uint128(FeeMath.gross(toOrder / 2, 3000))).orderInput, 0);
        assertGt(trade(true, 1e22).orderInput, 0);
        (, uint128 remaining,) = book.getOrder(oid);
        assertEq(remaining, 0);
        vm.prank(maker);
        book.claimOrder(oid);
        assertAccounting();
    }

    function test_OrdinaryOnlyFeesAllGoToProtocol() public {
        uint256 oid = order(true, 0, 100);
        Book.TradeResult memory r = trade(false, uint128(FeeMath.gross(100 * LOT, 3000)));
        assertEq(r.ammInput, 0);
        assertEq(r.orderInput, 100 * LOT);
        assertEq(r.fee, book.protocolFees(address(token1)));
        vm.prank(maker);
        assertEq(book.claimOrder(oid), 100 * LOT);
        assertAccounting();
    }

    function test_UniformFeeAcrossAMMAndOrderTransitions() public {
        full(lp, L);
        order(true, 60, 1000);
        order(true, 120, 1000);
        Book.TradeResult memory r = trade(false, 1e22);
        assertGt(r.orderInput, 0);
        assertGt(r.ammInput, 0);
        assertEq(r.input, FeeMath.gross(r.ammInput + r.orderInput, 3000));
        assertEq(r.fee, r.input - r.ammInput - r.orderInput);
        assertAccounting();
    }

    function test_AMMFeeSplitAndCollection() public {
        uint256 id = full(lp, L);
        Book.TradeResult memory r = trade(false, 1e21);
        assertEq(book.protocolFees(address(token1)), r.fee / 6);
        vm.prank(lp);
        (uint256 x, uint256 y) = book.collect(id);
        assertEq(x, 0);
        assertApproxEqAbs(y, r.fee - r.fee / 6, 1);
        assertAccounting();
    }

    function test_NewLPDoesNotReceiveOldFees() public {
        uint256 first = full(lp, L);
        trade(false, 1e21);
        uint256 second = full(lp2, L);
        vm.prank(lp2);
        (, uint256 y) = book.collect(second);
        assertEq(y, 0);
        Book.TradeResult memory r = trade(false, 1e21);
        vm.prank(lp2);
        (, y) = book.collect(second);
        assertApproxEqAbs(y, (r.fee - r.fee / 6) / 2, 2);
        vm.prank(lp);
        book.burn(first, L, 0, 0, NEVER);
        vm.prank(lp2);
        book.burn(second, L, 0, 0, NEVER);
        assertAccounting();
    }

    function test_OverlappingRangesCrossAndReverse() public {
        uint256 wide = full(lp, L);
        uint256 narrow = mint(lp2, -60, 60, L);
        trade(false, 1e22);
        (,,, uint128 active) = book.getMarket(market);
        assertEq(active, L);
        (, uint256 firstNarrow,, uint256 narrowFee) = book.positionValue(narrow);
        assertGt(firstNarrow, 0);
        assertGt(narrowFee, 0);
        trade(false, 1e21);
        (,,, uint256 unchanged) = book.positionValue(narrow);
        assertEq(narrowFee, unchanged);
        trade(true, 2e22);
        (uint256 narrowBase,,,) = book.positionValue(narrow);
        assertGt(narrowBase, 0);
        vm.prank(lp2);
        book.burn(narrow, L, 0, 0, NEVER);
        vm.prank(lp);
        book.burn(wide, L, 0, 0, NEVER);
        assertAccounting();
    }

    function test_AdjacentRangesAtExactBoundaryAndReverse() public {
        mint(lp, -120, 60, L);
        mint(lp2, 60, 180, L * 2);
        Book.TradeRequest memory r = request(false, 1e25);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60);
        vm.prank(taker);
        book.trade(r);
        (, uint160 price, int24 tick, uint128 active) = book.getMarket(market);
        assertEq(price, r.sqrtPriceLimitX96);
        assertEq(tick, 60);
        assertEq(active, L * 2);
        trade(true, 1e18);
        (,, tick, active) = book.getMarket(market);
        assertLt(tick, 60);
        assertEq(active, L);
        assertAccounting();
    }

    function test_OrderAtLiquidityBoundaryReceivesNoLPFees() public {
        uint256 first = mint(lp, -60, 60, L);
        uint256 second = mint(lp2, 60, 120, L);
        order(true, 60, 1e12);
        Book.TradeRequest memory r = request(false, 1e22);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60);
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        assertGt(result.ammInput, 0);
        assertGt(result.orderInput, 0);
        (,,, uint256 feeFirst) = book.positionValue(first);
        (,,, uint256 feeSecond) = book.positionValue(second);
        assertGt(feeFirst, 0);
        assertEq(feeSecond, 0);
        assertAccounting();
    }

    function test_ZeroLiquidityGapSkipsToNextRange() public {
        uint256 first = mint(lp, -60, 60, L);
        uint256 second = mint(lp2, 60_000, 60_120, L);
        Book.TradeRequest memory r = request(false, 1e28);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60_100);
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        assertEq(result.steps, 3);
        (, uint160 price,, uint128 active) = book.getMarket(market);
        assertEq(price, r.sqrtPriceLimitX96);
        assertEq(active, L);
        vm.prank(lp);
        book.burn(first, L, 0, 0, NEVER);
        vm.prank(lp2);
        book.burn(second, L, 0, 0, NEVER);
        assertAccounting();
    }

    function test_DustCannotBypassBetterOrder() public {
        full(lp, L);
        uint256 oid = order(true, 0, 100);
        Book.TradeRequest memory r = request(false, 100);
        vm.prank(taker);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.trade(r);
        (, uint128 remaining,) = book.getOrder(oid);
        assertEq(remaining, 100);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, Q96);
    }

    function test_FIFOClaimsAndCancellation() public {
        uint256 a = order(true, 0, 100);
        uint256 b = order(true, 0, 100);
        trade(false, uint128(FeeMath.gross(150 * LOT, 3000)));
        (, uint128 remainingA, uint128 claimA) = book.getOrder(a);
        (, uint128 remainingB, uint128 claimB) = book.getOrder(b);
        assertEq(remainingA, 0);
        assertEq(claimA, 100);
        assertEq(remainingB, 50);
        assertEq(claimB, 50);
        vm.prank(maker);
        book.cancelOrder(b, 50);
        vm.prank(maker);
        book.claimOrder(a);
        vm.prank(maker);
        book.claimOrder(b);
        assertAccounting();
    }

    function test_ReinitializeClearedEndpointsDoesNotAssignHistoricalFees() public {
        uint256 old = mint(lp, -60, 60, L);
        trade(false, 1e18);
        vm.prank(lp);
        book.burn(old, L, 0, 0, NEVER);
        uint256 fresh = mint(lp2, -60, 60, L);
        vm.prank(lp2);
        (uint256 x, uint256 y) = book.collect(fresh);
        assertEq(x, 0);
        assertEq(y, 0);
        vm.prank(lp);
        book.increase(old, L, type(uint256).max, type(uint256).max, NEVER);
        trade(true, 1e18);
        vm.prank(lp);
        book.burn(old, L, 0, 0, NEVER);
        vm.prank(lp2);
        book.burn(fresh, L, 0, 0, NEVER);
        assertAccounting();
    }

    function test_PriceLimitAndWorkLimit() public {
        full(lp, L);
        order(true, 60, 1);
        order(true, 120, 1);
        Book.TradeRequest memory r = request(false, 1e24);
        r.maxSteps = 1;
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        assertEq(result.steps, 1);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, TickMath.getSqrtPriceAtTick(60));
        r = request(false, 1e24);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(90);
        vm.prank(taker);
        book.trade(r);
        (, price,,) = book.getMarket(market);
        assertEq(price, r.sqrtPriceLimitX96);
    }

    function test_FOKRevertsEntirePartialExecution() public {
        full(lp, L);
        Book.TradeRequest memory r = request(false, 1e25);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60);
        r.fillOrKill = true;
        vm.prank(taker);
        vm.expectRevert(Book.IncompleteFill.selector);
        book.trade(r);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, Q96);
        assertAccounting();
    }

    function test_DeadlineOwnershipAndSlippage() public {
        uint256 id = full(lp, L);
        vm.prank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.collect(id);
        Book.TradeRequest memory r = request(false, 1e18);
        r.deadline = 0;
        vm.prank(taker);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.trade(r);
        r.deadline = NEVER;
        r.minOutput = type(uint256).max;
        vm.prank(taker);
        vm.expectRevert(Book.Slippage.selector);
        book.trade(r);
        vm.prank(lp);
        vm.expectRevert(CL.InvalidLiquidity.selector);
        book.burn(id, L + 1, 0, 0, NEVER);
    }

    function testFuzz_FullRangeRoundTripSolvent(uint128 input, bool direction) public {
        input = uint128(bound(input, 1000, 1e26));
        uint256 id = full(lp, L);
        Book.TradeResult memory r = trade(direction, input);
        assertEq(r.input, FeeMath.gross(r.ammInput, 3000));
        assertEq(r.steps, 1);
        trade(!direction, uint128(r.output / 2 + 1000));
        (uint256 expected0, uint256 expected1,,) = book.positionValue(id);
        vm.prank(lp);
        (uint256 actual0, uint256 actual1) = book.burn(id, L, 0, 0, NEVER);
        assertEq(actual0, expected0);
        assertEq(actual1, expected1);
        assertAccounting();
    }

    function testFuzz_PartialBidCancelAndClaim(uint64 raw, uint64 filledRaw, uint64 cancelledRaw) public {
        uint128 lots = uint128(bound(raw, 3, 1e8));
        uint128 filled = uint128(bound(filledRaw, 1, lots - 1));
        uint128 cancelled = uint128(bound(cancelledRaw, 1, lots - filled));
        uint256 oid = order(false, -60, lots);
        trade(true, uint128(FeeMath.gross(uint256(filled) * LOT, 3000)));
        vm.prank(maker);
        book.cancelOrder(oid, cancelled);
        vm.prank(maker);
        book.claimOrder(oid);
        (, uint128 remaining,) = book.getOrder(oid);
        if (remaining != 0) {
            trade(true, uint128(FeeMath.gross(uint256(remaining) * LOT, 3000)));
            vm.prank(maker);
            book.claimOrder(oid);
        }
        assertAccounting();
    }
}

contract TickTreeTest is ConcentratedBase {
    using TickTree for TickTree.Map;
    TickTree.Map internal tree;

    function test_EntireDomainSparseLookups() public {
        (bool empty,) = tree.best(true);
        assertFalse(empty);
        (empty,) = tree.best(false);
        assertFalse(empty);
        tree.set(-887_272, true);
        tree.set(-1, true);
        tree.set(0, true);
        tree.set(887_272, true);
        (bool found, int24 tick) = tree.next(-887_271, true);
        assertTrue(found);
        assertEq(tick, -1);
        (found, tick) = tree.next(887_271, false);
        assertTrue(found);
        assertEq(tick, 0);
        tree.set(0, false);
        tree.set(-1, false);
        (found, tick) = tree.next(0, true);
        assertTrue(found);
        assertEq(tick, 887_272);
        (found, tick) = tree.next(0, false);
        assertTrue(found);
        assertEq(tick, -887_272);
        (found,) = tree.next(887_273, true);
        assertFalse(found);
        (found,) = tree.next(-887_273, false);
        assertFalse(found);
        (found, tick) = tree.best(true);
        assertTrue(found);
        assertEq(tick, -887_272);
        (found, tick) = tree.best(false);
        assertTrue(found);
        assertEq(tick, 887_272);
    }

    function testFuzz_NearestPair(int24 a, int24 b, int24 origin) public {
        a = int24(bound(a, -887_272, 887_272));
        b = int24(bound(b, -887_272, 887_272));
        origin = int24(bound(origin, -887_273, 887_273));
        tree.set(a, true);
        tree.set(b, true);
        (bool found, int24 actual) = tree.next(origin, true);
        bool expected = a >= origin || b >= origin;
        assertEq(found, expected);
        if (expected) assertEq(actual, a >= origin && (b < origin || a < b) ? a : b);
        (found, actual) = tree.next(origin, false);
        expected = a <= origin || b <= origin;
        assertEq(found, expected);
        if (expected) assertEq(actual, a <= origin && (b > origin || a > b) ? a : b);
        (found, actual) = tree.best(true);
        assertTrue(found);
        assertEq(actual, a < b ? a : b);
        (found, actual) = tree.best(false);
        assertTrue(found);
        assertEq(actual, a > b ? a : b);
        tree.set(a, false);
        (found, actual) = tree.best(true);
        assertEq(found, a != b);
        if (found) assertEq(actual, b);
        tree.set(b, false);
        (found,) = tree.best(false);
        assertFalse(found);
    }
}
