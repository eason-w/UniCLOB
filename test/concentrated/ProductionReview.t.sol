// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, TickMath, FeeMath } from "./Base.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CallbackToken } from "../mocks/HostileTokens.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Regression tests for price anchoring, settlement isolation and hostile callbacks.
contract ProductionReviewTest is ConcentratedBase {
    function testFuzz_EmptyTailCannotSetPostingAnchor(bool down, uint16 distance) public {
        int24 tick = down ? int24(-60) : int24(60);
        order(!down, tick, 100);
        Book.TradeRequest memory r = request(down, 1e20);
        int24 limit = int24(uint24(bound(distance, 2, 1000))) * (down ? int24(-60) : int24(60));
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limit);
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        assertGt(result.orderInput, 0);
        assertLt(result.input, r.maxInput);
        (, uint160 price,, uint128 active) = book.getMarket(market);
        assertEq(price, TickMath.getSqrtPriceAtTick(tick));
        assertEq(active, 0);
        // A new quote one level beyond the fill must remain post-only.
        order(!down, down ? tick - 60 : tick + 60, 100);
        assertAccounting();
    }

    function testFuzz_UnaffordableNextOrderDoesNotMoveSpot(bool down) public {
        order(!down, 0, 1);
        uint256 second = order(!down, down ? int24(-60) : int24(60), 1);
        // One lot executes at par, with less than half a lot left for the next price.
        Book.TradeResult memory result = trade(down, uint128(FeeMath.gross(LOT + LOT / 4, 3000)));
        assertEq(result.orderInput, LOT);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, Q96);
        (, uint128 remaining,) = book.getOrder(second);
        assertEq(remaining, 1);
        assertAccounting();
    }

    function testFuzz_EmptyTailStopsAtLastLPBoundary(bool down) public {
        uint256 id = mint(lp, -60, 60, L);
        Book.TradeResult memory result = trade(down, 1e27);
        assertGt(result.ammInput, 0);
        assertLt(result.input, 1e27);
        (, uint160 price, int24 tick, uint128 active) = book.getMarket(market);
        assertEq(price, TickMath.getSqrtPriceAtTick(down ? int24(-60) : int24(60)));
        assertEq(tick, down ? int24(-61) : int24(60));
        assertEq(active, 0);
        vm.prank(lp);
        book.burn(id, L, 0, 0, NEVER);
        assertAccounting();
    }

    function test_EmptyBookTradeRollsBackPriceAndBalances() public {
        uint256 free = book.balanceOf(taker, address(token1));
        vm.prank(taker);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.trade(request(false, 1e20));
        (, uint160 price, int24 tick,) = book.getMarket(market);
        assertEq(price, Q96);
        assertEq(tick, 0);
        assertEq(book.balanceOf(taker, address(token1)), free);
    }

    function test_FailedSlippageRollsBackOrderConsumptionAndFees() public {
        uint256 id = order(true, 60, 100);
        Book.TradeRequest memory r = request(false, 1e20);
        r.minOutput = type(uint256).max;
        vm.prank(taker);
        vm.expectRevert(Book.Slippage.selector);
        book.trade(r);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining, 100);
        assertEq(claimable, 0);
        assertEq(book.protocolFees(address(token1)), 0);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, Q96);
        assertAccounting();
    }

    function test_DepositForAnotherOwnerDoesNotGrantWithdrawalAuthority() public {
        token0.mint(taker, 100);
        vm.prank(taker);
        book.deposit(address(token0), 100, lp);
        assertEq(book.balanceOf(taker, address(token0)), 1e35);
        assertEq(book.balanceOf(lp, address(token0)), 1e35 + 100);
        vm.prank(taker);
        vm.expectRevert(Book.InsufficientBalance.selector);
        book.withdraw(address(token0), 1e35 + 100, taker);
        assertAccounting();
    }

    function test_DonationsCannotBeClaimedByCollector() public {
        token0.mint(address(book), 123);
        assertEq(token0.balanceOf(address(book)), book.totalLiability(address(token0)) + 123);
        vm.expectRevert(Book.InsufficientBalance.selector);
        book.collectProtocol(address(token0), 123, address(this));
        vm.prank(lp);
        book.withdraw(address(token0), 1e35, lp);
        assertEq(token0.balanceOf(address(book)), book.totalLiability(address(token0)) + 123);
    }

    function test_ZeroAndSelfRecipientsRollBackWithdrawal() public {
        vm.startPrank(lp);
        vm.expectRevert(Book.InvalidRecipient.selector);
        book.withdraw(address(token0), 1, address(0));
        vm.expectRevert(Book.InvalidRecipient.selector);
        book.withdraw(address(token0), 1, address(book));
        vm.expectRevert(Book.InvalidAmount.selector);
        book.withdraw(address(token0), 0, lp);
        vm.stopPrank();
        assertAccounting();
    }

    function test_UnknownMarketAndDuplicateConfiguration() public {
        vm.expectRevert(Book.UnknownMarket.selector);
        book.fullRange(bytes32(uint256(123)));
        vm.expectRevert(Book.MarketExists.selector);
        book.createMarket(config());
        vm.expectRevert(Book.InvalidRecipient.selector);
        new Book(address(0));
    }

    function test_BatchBoundAndNestedAtomicity() public {
        bytes[] memory tooMany = new bytes[](65);
        vm.expectRevert(Book.BatchTooLarge.selector);
        book.multicall(tooMany);
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeCall(book.withdraw, (address(token0), 1, lp));
        inner[1] = abi.encodeCall(book.withdraw, (address(token1), type(uint256).max, lp));
        bytes[] memory outer = new bytes[](1);
        outer[0] = abi.encodeCall(book.multicall, (inner));
        vm.prank(lp);
        vm.expectRevert(Book.InsufficientBalance.selector);
        book.multicall(outer);
        assertEq(token0.balanceOf(lp), 0);
        assertAccounting();
    }

    function test_ExpiredLPAndOrderOperationsAndInclusiveDeadline() public {
        vm.warp(100);
        uint256 id = full(lp, L);
        vm.startPrank(lp);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.increase(id, 1, 1, 1, 99);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.burn(id, 1, 0, 0, 99);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.mint(market, -60, 60, 1, 1, 1, 99);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.placeOrder(market, true, 60, 1, 99);
        book.placeOrder(market, true, 60, 1, 100);
        book.burn(id, L, 0, 0, 100);
        vm.stopPrank();
        assertAccounting();
    }

    function test_AllMutatingEntrypointsRejectTokenCallbackReentry() public {
        CallbackToken callback = new CallbackToken();
        callback.mint(address(this), 1000);
        callback.approve(address(book), type(uint256).max);
        bytes[] memory payloads = new bytes[](15);
        payloads[0] = abi.encodeCall(book.createMarket, (config()));
        payloads[1] = abi.encodeCall(book.deposit, (address(callback), 1, address(callback)));
        payloads[2] = abi.encodeCall(book.withdraw, (address(callback), 1, address(callback)));
        payloads[3] = abi.encodeCall(book.collectProtocol, (address(callback), 1, address(callback)));
        payloads[4] = abi.encodeCall(book.mint, (market, int24(-60), int24(60), uint128(1), 1, 1, NEVER));
        payloads[5] = abi.encodeCall(book.increase, (1, uint128(1), 1, 1, NEVER));
        payloads[6] = abi.encodeCall(book.burn, (1, uint128(1), 0, 0, NEVER));
        payloads[7] = abi.encodeCall(book.collect, (1));
        payloads[8] = abi.encodeCall(book.placeOrder, (market, true, int24(60), uint128(1), NEVER));
        payloads[9] = abi.encodeCall(book.cancelOrder, (1, uint128(1)));
        payloads[10] = abi.encodeCall(book.claimOrder, (1));
        payloads[11] = abi.encodeCall(book.trade, (request(false, 100)));
        payloads[12] = abi.encodeCall(book.swapWallet, (request(false, 100), address(callback)));
        payloads[13] = abi.encodeCall(book.replaceOrder, (1, int24(60), uint128(1), NEVER));
        payloads[14] = abi.encodeCall(book.executeWallet, (new bytes[](0), address(callback)));
        for (uint256 i; i < payloads.length; ++i) {
            bytes[] memory inner = new bytes[](1);
            inner[0] = payloads[i];
            callback.configure(address(book), abi.encodeCall(book.multicall, (inner)));
            book.deposit(address(callback), 1, address(this));
            assertTrue(callback.attempted());
            assertFalse(callback.succeeded());
            assertEq(
                callback.returnData(),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            );
        }
        // Outbound transfers must use the same lock, not only deposits.
        callback.configure(address(book), payloads[2]);
        book.withdraw(address(callback), 1, address(this));
        assertFalse(callback.succeeded());
        assertEq(
            callback.returnData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(book.totalLiability(address(callback)), payloads.length - 1);
    }

    function testFuzz_ExtremeOrderPricesRemainFullyBacked(bool ask, int16 rawTick, uint8 rawA, uint8 rawB) public {
        int24 tick = int24(bound(int256(rawTick), -10_000, 10_000)) * 60;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        uint256 numerator;
        uint256 denominator;
        if (price <= type(uint128).max) {
            numerator = uint256(price) * price;
            denominator = 1 << 192;
        } else {
            numerator = Math.mulDiv(price, price, 1 << 64);
            denominator = 1 << 128;
        }
        Book.Config memory c = config();
        c.initialSqrtPriceX96 = price;
        c.orderLot = uint128(Math.max(1, Math.ceilDiv(denominator, numerator)));
        market = book.createMarket(c);
        uint128 a = uint128(bound(rawA, 2, 100));
        uint128 b = uint128(bound(rawB, 2, 100));
        uint256 first = order(ask, tick, a);
        vm.prank(lp2);
        uint256 second = book.placeOrder(market, ask, tick, b, NEVER);
        uint256 principal = ask ? Math.mulDiv(c.orderLot, numerator, denominator, Math.Rounding.Ceil) : c.orderLot;
        Book.TradeResult memory initial = trade(!ask, uint128(FeeMath.gross(principal, 3000)));
        assertGt(initial.output, 0);
        (, uint128 remaining,) = book.getOrder(first);
        assertEq(remaining, a - 1);
        vm.startPrank(maker);
        book.claimOrder(first);
        book.cancelOrder(first, 1);
        vm.stopPrank();
        trade(!ask, 1e34);
        vm.prank(maker);
        book.claimOrder(first);
        vm.prank(lp2);
        book.claimOrder(second);
        (, remaining,) = book.getOrder(first);
        assertEq(remaining, 0);
        (, remaining,) = book.getOrder(second);
        assertEq(remaining, 0);
        assertAccounting();
    }

    function test_RevertWhen_TradeLimitOutsideDomainOrDirection() public {
        uint160[4] memory invalid = [
            TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, TickMath.MIN_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE + 1
        ];
        for (uint256 side; side < 2; ++side) {
            Book.TradeRequest memory r = request(side == 0, 1e18);
            for (uint256 i; i < invalid.length; ++i) {
                r.sqrtPriceLimitX96 = invalid[i];
                vm.prank(taker);
                vm.expectRevert(Book.InvalidPrice.selector);
                book.trade(r);
            }
            r.sqrtPriceLimitX96 = side == 0 ? Q96 + 1 : Q96 - 1;
            vm.prank(taker);
            vm.expectRevert(Book.InvalidPrice.selector);
            book.trade(r);
        }
        assertAccounting();
    }

    function test_RevertWhen_OrderCollateralOverflowsOrLotIsUnrepresentable() public {
        Book.Config memory c = config();
        c.orderLot = type(uint128).max;
        bytes32 large = book.createMarket(c);
        vm.startPrank(maker);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.placeOrder(large, true, 0, 2, NEVER); // Base exceeds uint128.
        vm.expectRevert(Book.InvalidAmount.selector);
        book.placeOrder(large, true, 60, 1, NEVER); // Quote exceeds uint128.
        vm.stopPrank();
        c.orderLot = 1;
        c.initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(-120);
        bytes32 dust = book.createMarket(c);
        vm.prank(maker);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.placeOrder(dust, true, -60, 100, NEVER); // One base lot buys less than one quote atom.
        assertEq(book.nextOrderId(), 1);
        assertAccounting();
    }

    function test_RuntimeFitsEIP170() public view {
        assertLe(address(book).code.length, 24_576);
    }
}
