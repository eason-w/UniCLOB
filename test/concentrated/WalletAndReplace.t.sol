// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, FeeMath } from "./Base.sol";
import { ConcentratedRangeBook as Book } from "../../src/ConcentratedRangeBook.sol";
import { WalletSettlement as Wallet } from "../../src/libraries/WalletSettlement.sol";
import { CallbackToken, TaxToken, NoReturnToken, FalseReturnToken } from "../mocks/HostileTokens.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TickMath } from "../../src/vendor/uniswap/TickMath.sol";

contract WalletAndReplaceTest is ConcentratedBase {
    function _wallet(address who, bytes memory action) internal returns (bytes memory) {
        bytes[] memory actions = new bytes[](1);
        actions[0] = action;
        vm.prank(who);
        return book.executeWallet(actions, who)[0];
    }

    function _walletFunds(address who) internal {
        token0.mint(who, 1e30);
        token1.mint(who, 1e30);
        vm.startPrank(who);
        token0.approve(address(book), type(uint256).max);
        token1.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_WalletTradeMatchesFundedAndLeavesInternalBalancesUntouched(uint128 amount, bool down) public {
        full(lp, L);
        amount = uint128(bound(amount, 1e6, 1e25));
        Book.TradeRequest memory r = request(down, amount);
        uint256 snap = vm.snapshotState();
        Book.TradeResult memory expected = trade(down, amount);
        vm.revertToState(snap);
        _walletFunds(taker);
        uint256 before0 = token0.balanceOf(taker);
        uint256 before1 = token1.balanceOf(taker);
        uint256 free0 = book.balanceOf(taker, address(token0));
        uint256 free1 = book.balanceOf(taker, address(token1));
        Book.TradeResult memory actual = abi.decode(_wallet(taker, abi.encodeCall(Book.trade, (r))), (Book.TradeResult));
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(token0.balanceOf(taker), down ? before0 - actual.input : before0 + actual.output);
        assertEq(token1.balanceOf(taker), down ? before1 + actual.output : before1 - actual.input);
        assertEq(book.balanceOf(taker, address(token0)), free0);
        assertEq(book.balanceOf(taker, address(token1)), free1);
        assertAccounting();
    }

    function test_WalletPartialFillPullsActualInputOnlyAndRoutesRecipient() public {
        full(lp, L);
        _walletFunds(taker);
        Book.TradeRequest memory r = request(false, 1e25);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.trade, (r));
        uint256 before_ = token1.balanceOf(taker);
        vm.prank(taker);
        Book.TradeResult memory result = abi.decode(book.executeWallet(calls, lp2)[0], (Book.TradeResult));
        assertLt(result.input, r.maxInput);
        assertEq(token1.balanceOf(taker), before_ - result.input);
        assertEq(token0.balanceOf(lp2), result.output);
        assertAccounting();
    }

    function test_WalletMintIncreaseCollectBurnAndTwoBatchesInSameTransaction() public {
        _walletFunds(lp);
        bytes memory encoded = _wallet(
            lp,
            abi.encodeCall(Book.mint, (market, int24(-600), int24(600), L, type(uint256).max, type(uint256).max, NEVER))
        );
        (uint256 id,,) = abi.decode(encoded, (uint256, uint256, uint256));
        _wallet(lp, abi.encodeCall(Book.increase, (id, L, type(uint256).max, type(uint256).max, NEVER)));
        trade(true, 1e18);
        _wallet(lp, abi.encodeCall(Book.collect, (id)));
        _wallet(lp, abi.encodeCall(Book.burn, (id, L * 2, uint256(0), uint256(0), NEVER)));
        assertEq(book.getPosition(id).accounting.liquidity, 0);
        assertAccounting();
    }

    function test_WalletCancelAndPostNetToZeroWithoutApprovalOrWalletFunds() public {
        uint256 id = order(true, 60, 100);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Book.cancelOrder, (id, uint128(100)));
        calls[1] = abi.encodeCall(Book.placeOrder, (market, true, int24(120), uint128(100), NEVER));
        vm.prank(maker);
        token0.approve(address(book), 0);
        vm.prank(maker);
        book.executeWallet(calls, maker);
        assertEq(token0.balanceOf(maker), 0);
        assertEq(book.balanceOf(maker, address(token0)), 1e35 - 100 * LOT);
        assertAccounting();
    }

    function test_WalletSettlementFailureRollsBackAllState() public {
        full(lp, L);
        uint256 beforeLiability = book.totalLiability(address(token1));
        (, uint160 beforePrice,,) = book.getMarket(market);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.trade, (request(false, 1e18)));
        vm.prank(taker);
        vm.expectRevert();
        book.executeWallet(calls, taker);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, beforePrice);
        assertEq(book.totalLiability(address(token1)), beforeLiability);
        // Revert also removes the transient context; a subsequent funded trade must work.
        trade(false, 1e18);
        assertAccounting();
    }

    function test_WalletForbidsCustodyNestedBatchesAndUnknownSelectors() public {
        bytes[] memory forbidden = new bytes[](8);
        forbidden[0] = abi.encodeCall(Book.deposit, (address(token0), uint256(1), maker));
        forbidden[1] = abi.encodeCall(Book.withdraw, (address(token0), uint256(1), maker));
        forbidden[2] = abi.encodeCall(Book.collectProtocol, (address(token0), uint256(1), maker));
        forbidden[3] = abi.encodeCall(Book.createMarket, (config()));
        forbidden[4] = abi.encodeCall(Book.multicall, (new bytes[](0)));
        forbidden[5] = abi.encodeCall(Book.executeWallet, (new bytes[](0), maker));
        forbidden[6] = hex"12345678";
        forbidden[7] = hex"12";
        for (uint256 i; i < forbidden.length; ++i) {
            bytes[] memory calls = new bytes[](1);
            calls[0] = forbidden[i];
            vm.prank(maker);
            vm.expectRevert(Wallet.InvalidWalletBatch.selector);
            book.executeWallet(calls, maker);
        }
        vm.expectRevert(Wallet.InvalidWalletBatch.selector);
        book.executeWallet(new bytes[](0), maker);
        vm.expectRevert(Wallet.InvalidWalletBatch.selector);
        book.executeWallet(new bytes[](65), maker);
        vm.expectRevert(Book.InvalidRecipient.selector);
        book.executeWallet(new bytes[](1), address(0));
        vm.expectRevert(Book.InvalidRecipient.selector);
        book.executeWallet(new bytes[](1), address(book));
    }

    function test_WalletInputAndOutputTransfersCannotReenterAnyMutator() public {
        CallbackToken callback = new CallbackToken();
        Book.Config memory c = config();
        c.token0 = address(callback);
        bytes32 id = book.createMarket(c);
        callback.mint(maker, 1e24);
        vm.prank(maker);
        callback.approve(address(book), type(uint256).max);
        bytes[] memory nested = new bytes[](1);
        nested[0] = abi.encodeCall(Book.placeOrder, (id, true, int24(60), uint128(1), NEVER));
        bytes[] memory attacks = new bytes[](8);
        attacks[0] = abi.encodeCall(Book.executeWallet, (nested, maker));
        attacks[1] = abi.encodeCall(Book.deposit, (address(callback), uint256(1), maker));
        attacks[2] = abi.encodeCall(Book.withdraw, (address(callback), uint256(1), maker));
        attacks[3] = abi.encodeCall(Book.multicall, (nested));
        attacks[4] = abi.encodeCall(Book.collectProtocol, (address(callback), uint256(1), maker));
        attacks[5] = abi.encodeCall(Book.trade, (request(false, 1e18)));
        attacks[6] = abi.encodeCall(Book.cancelRemaining, (uint256(1)));
        attacks[7] = abi.encodeCall(Book.updateOrders, (id, abi.encodePacked(uint256(1), int24(0), uint64(0)), NEVER));
        for (uint256 i; i < attacks.length; ++i) {
            callback.configure(address(book), attacks[i]);
            uint256 orderId = abi.decode(_wallet(maker, nested[0]), (uint256));
            assertTrue(callback.attempted());
            assertFalse(callback.succeeded());
            assertEq(
                callback.returnData(),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            );
            callback.configure(address(book), attacks[i]);
            _wallet(maker, abi.encodeCall(Book.cancelOrder, (orderId, uint128(1))));
            assertTrue(callback.attempted());
            assertFalse(callback.succeeded());
            assertEq(callback.balanceOf(address(book)), 0);
            assertEq(book.totalLiability(address(callback)), 0);
        }
    }

    function test_WalletRejectsTaxOnBothSettlementDirections() public {
        TaxToken taxed = new TaxToken();
        Book.Config memory c = config();
        c.token0 = address(taxed);
        bytes32 id = book.createMarket(c);
        taxed.mint(maker, 1e24);
        vm.prank(maker);
        taxed.approve(address(book), type(uint256).max);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.placeOrder, (id, true, int24(60), uint128(100), NEVER));
        taxed.setTax(true);
        vm.prank(maker);
        vm.expectRevert(Wallet.UnsupportedToken.selector);
        book.executeWallet(calls, maker);
        assertEq(book.totalLiability(address(taxed)), 0);
        taxed.setTax(false);
        uint256 orderId = abi.decode(_wallet(maker, calls[0]), (uint256));
        taxed.setTax(true);
        calls[0] = abi.encodeCall(Book.cancelOrder, (orderId, uint128(100)));
        vm.prank(maker);
        vm.expectRevert(Wallet.UnsupportedToken.selector);
        book.executeWallet(calls, maker);
        (, uint128 remaining,) = book.getOrder(orderId);
        assertEq(remaining, 100);
        assertEq(book.totalLiability(address(taxed)), 100 * LOT);
    }

    function test_WalletMultiMarketRouteNetsIntermediateToken() public {
        // Same two assets, distinct fee configuration: sell token1 then use received token0.
        full(lp, L);
        Book.Config memory c = config();
        c.feePpm = 500;
        c.protocolDivisor = 4;
        bytes32 other = book.createMarket(c);
        vm.prank(lp);
        book.mint(other, -600, 600, L, type(uint256).max, type(uint256).max, NEVER);
        _walletFunds(taker);
        uint256 snap = vm.snapshotState();
        Book.TradeResult memory first = trade(false, 1e18);
        vm.revertToState(snap);
        Book.TradeRequest memory second = request(true, uint128(first.output));
        second.marketId = other;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Book.trade, (request(false, 1e18)));
        calls[1] = abi.encodeCall(Book.trade, (second));
        vm.prank(taker);
        token0.approve(address(book), 0);
        uint256 before0 = token0.balanceOf(taker);
        vm.prank(taker);
        book.executeWallet(calls, taker);
        assertEq(token0.balanceOf(taker), before0);
        assertEq(book.totalLiability(address(token0)), token0.balanceOf(address(book)));
        assertEq(book.totalLiability(address(token1)), token1.balanceOf(address(book)));
    }

    function test_ReplaceReusesIdentifierAndLosesTimePriority() public {
        uint256 id = order(true, 60, 100);
        uint256 second = order(true, 60, 100);
        vm.prank(maker);
        book.replaceOrder(id, 60, 200, NEVER);
        assertEq(book.nextOrderId(), 3);
        (Book.Order memory a, uint128 remain,) = book.getOrder(id);
        (Book.Order memory b,,) = book.getOrder(second);
        assertGt(a.sequence, b.sequence);
        assertEq(remain, 200);
        assertEq(a.cancelled, 0);
        assertEq(a.claimed, 0);
        assertAccounting();
    }

    function test_ReplaceClaimsPartialFillExactlyOnce() public {
        uint256 id = order(true, 60, 1_000_000);
        trade(false, 1e15);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertGt(claimable, 0);
        assertGt(remaining, 0);
        uint256 snap = vm.snapshotState();
        vm.prank(maker);
        uint256 proceeds = book.claimOrder(id);
        vm.revertToState(snap);
        uint256 before_ = book.balanceOf(maker, address(token1));
        vm.prank(maker);
        book.replaceOrder(id, 120, 1_000_000, NEVER);
        assertEq(book.balanceOf(maker, address(token1)), before_ + proceeds);
        vm.prank(maker);
        assertEq(book.claimOrder(id), 0);
        assertAccounting();
    }

    function test_ReplaceFailurePreservesOldQuoteAndAuthorization() public {
        uint256 id = order(true, 60, 100);
        (Book.Order memory before_, uint128 remaining,) = book.getOrder(id);
        vm.prank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.replaceOrder(id, 120, 100, NEVER);
        vm.prank(maker);
        vm.expectRevert(Book.MarketableOrder.selector);
        book.replaceOrder(id, -60, 100, NEVER);
        (Book.Order memory after_, uint128 afterRemaining,) = book.getOrder(id);
        assertEq(abi.encode(before_), abi.encode(after_));
        assertEq(remaining, afterRemaining);
        assertAccounting();
    }

    function test_ReplacementChurnRecyclesEmptyQueueButCannotJumpPinnedMaker() public {
        uint256 id = order(true, 60, 100);
        for (uint256 i; i < 257; ++i) {
            vm.prank(maker);
            book.replaceOrder(id, 60, 100, NEVER);
            (Book.Order memory o, uint128 remaining,) = book.getOrder(id);
            assertEq(o.generation, i + 1);
            assertEq(o.sequence, 0);
            assertEq(remaining, 100);
        }
        uint256 pinned = order(true, 60, 100);
        vm.prank(maker);
        book.replaceOrder(id, 60, 100, NEVER);
        (Book.Order memory a,,) = book.getOrder(id);
        (Book.Order memory b,,) = book.getOrder(pinned);
        assertEq(a.generation, b.generation);
        assertGt(a.sequence, b.sequence);
        assertAccounting();
    }

    function test_ReplacementEmptyGenerationPreservesOlderUnclaimedFill() public {
        uint256 first = order(true, 0, 100);
        uint256 second = order(true, 0, 100);
        trade(false, uint128(FeeMath.gross(200 * LOT, 3000)));
        vm.prank(maker);
        book.replaceOrder(second, 0, 100, NEVER);
        (, uint128 remaining, uint128 claimable) = book.getOrder(first);
        assertEq(remaining, 0);
        assertEq(claimable, 100);
        vm.prank(maker);
        assertEq(book.claimOrder(first), 100 * LOT);
        vm.prank(maker);
        assertEq(book.claimOrder(first), 0);
        assertAccounting();
    }

    function testFuzz_DirectWalletMatchesBatch(uint128 input, bool down) public {
        full(lp, L);
        _walletFunds(taker);
        input = uint128(bound(input, 1e6, 1e25));
        Book.TradeRequest memory r = request(down, input);
        uint256 snap = vm.snapshotState();
        Book.TradeResult memory batched =
            abi.decode(_wallet(taker, abi.encodeCall(Book.trade, (r))), (Book.TradeResult));
        uint256 end0 = token0.balanceOf(taker);
        uint256 end1 = token1.balanceOf(taker);
        vm.revertToState(snap);
        vm.prank(taker);
        Book.TradeResult memory direct = book.swapWallet(r, taker);
        assertEq(abi.encode(direct), abi.encode(batched));
        assertEq(token0.balanceOf(taker), end0);
        assertEq(token1.balanceOf(taker), end1);
        assertAccounting();
    }

    function test_WalletReplacementSettlesOnlyDifference() public {
        uint256 id = order(true, 60, 100);
        _walletFunds(maker);
        uint256 before_ = token0.balanceOf(maker);
        _wallet(maker, abi.encodeCall(Book.replaceOrder, (id, int24(120), uint128(150), NEVER)));
        assertEq(token0.balanceOf(maker), before_ - 50 * LOT);
        assertAccounting();
    }
}
