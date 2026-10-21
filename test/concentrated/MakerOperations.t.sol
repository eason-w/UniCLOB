// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, FeeMath, TickMath } from "./Base.sol";

/// @notice Maker risk controls, packed decoding, FIFO semantics and wallet settlement regressions.
contract MakerOperationsTest is ConcentratedBase {
    function _record(uint256 id, int24 tick, uint64 lots) internal pure returns (bytes memory) {
        return abi.encodePacked(id, tick, lots);
    }

    function _update(bytes memory data) internal {
        vm.prank(maker);
        book.updateOrders(market, data, NEVER);
    }

    function _fill(bool ask, uint128 lots) internal {
        Book.TradeRequest memory r = request(!ask, uint128(FeeMath.gross(lots * LOT, 3000)));
        r.sqrtPriceLimitX96 = Q96;
        vm.prank(taker);
        book.trade(r);
    }

    function testFuzz_CancelRemainingAfterPartialFill(bool ask, uint64 posted, uint64 filled) public {
        posted = uint64(bound(posted, 2, 1e8));
        filled = uint64(bound(filled, 1, posted - 1));
        uint256 id = order(ask, 0, posted);
        _fill(ask, filled);
        uint256 before_ = book.balanceOf(maker, address(ask ? token0 : token1));
        vm.prank(maker);
        assertEq(book.cancelRemaining(id), posted - filled);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining, 0);
        assertEq(claimable, filled);
        assertEq(book.balanceOf(maker, address(ask ? token0 : token1)), before_ + (posted - filled) * LOT);
        vm.prank(maker);
        assertEq(book.cancelRemaining(id), 0);
        vm.prank(maker);
        assertEq(book.claimOrder(id), filled * LOT);
        assertAccounting();
    }

    function test_CancelRemainingFullyFilledPreservesClaimAndAuthorization() public {
        uint256 id = order(true, 0, 100);
        _fill(true, 100);
        vm.prank(maker);
        assertEq(book.cancelRemaining(id), 0);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining, 0);
        assertEq(claimable, 100);
        vm.prank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.cancelRemaining(id);
        vm.prank(maker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.cancelRemaining(id + 1);
        assertAccounting();
    }

    function test_BatchCancelSurvivesRacingPartialAndFullFills() public {
        uint256 first = order(true, 0, 100);
        uint256 second = order(true, 0, 100);
        _fill(true, 150);
        uint256 before0 = book.balanceOf(maker, address(token0));
        uint256 before1 = book.balanceOf(maker, address(token1));
        _update(bytes.concat(_record(first, 0, 0), _record(second, 0, 0)));
        assertEq(book.balanceOf(maker, address(token0)), before0 + 50 * LOT);
        assertEq(book.balanceOf(maker, address(token1)), before1 + 150 * LOT);
        for (uint256 id = first; id <= second; ++id) {
            (, uint128 remaining, uint128 claimable) = book.getOrder(id);
            assertEq(remaining + claimable, 0);
        }
        _update(bytes.concat(_record(first, 0, 0), _record(second, 0, 0)));
        assertEq(book.balanceOf(maker, address(token1)), before1 + 150 * LOT);
        assertAccounting();
    }

    function test_UnchangedAndReducedOrdersRetainFifoPriority() public {
        uint256 first = order(true, 0, 100);
        vm.prank(lp2);
        uint256 second = book.placeOrder(market, true, 0, 100, NEVER);
        (Book.Order memory before_,,) = book.getOrder(first);
        _update(_record(first, 0, 100));
        _update(_record(first, 0, 75));
        (Book.Order memory after_, uint128 remaining,) = book.getOrder(first);
        assertEq(after_.generation, before_.generation);
        assertEq(after_.sequence, before_.sequence);
        assertEq(remaining, 75);
        _fill(true, 75);
        (, remaining,) = book.getOrder(second);
        assertEq(remaining, 100);
        assertAccounting();
    }

    function test_SamePriceIncreaseLosesFifoPriority() public {
        uint256 first = order(true, 0, 100);
        vm.prank(lp2);
        uint256 second = book.placeOrder(market, true, 0, 100, NEVER);
        _update(_record(first, 0, 101));
        _fill(true, 100);
        (, uint128 remaining, uint128 claimable) = book.getOrder(first);
        assertEq(remaining, 101);
        assertEq(claimable, 0);
        (, remaining, claimable) = book.getOrder(second);
        assertEq(remaining, 0);
        assertEq(claimable, 100);
        assertEq(book.nextOrderId(), 3);
        assertAccounting();
    }

    function test_TargetQuantityMeansRemainingAfterFillAndClaimsExactlyOnce() public {
        uint256 id = order(true, 0, 100);
        _fill(true, 40);
        uint256 before_ = book.balanceOf(maker, address(token1));
        (Book.Order memory old,,) = book.getOrder(id);
        _update(_record(id, 0, 50));
        (Book.Order memory o, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(o.sequence, old.sequence);
        assertEq(o.generation, old.generation);
        assertEq(remaining, 50);
        assertEq(claimable, 0);
        assertEq(book.balanceOf(maker, address(token1)), before_ + 40 * LOT);
        _update(_record(id, 0, 50));
        assertEq(book.balanceOf(maker, address(token1)), before_ + 40 * LOT);
        assertAccounting();
    }

    function testFuzz_PackedRepricingMatchesIndividualReplacement(bool ask, uint16 distance, uint64 lots) public {
        distance = uint16(bound(distance, 1, 100));
        lots = uint64(bound(lots, 1, 1e8));
        uint256 id = order(ask, 0, 100);
        _fill(ask, 40);
        int24 tick = int24(uint24(distance)) * (ask ? int24(60) : -int24(60));
        uint256 snap = vm.snapshotState();
        vm.prank(maker);
        book.replaceOrder(id, tick, lots, NEVER);
        bytes32 expected = _state(id);
        vm.revertToState(snap);
        _update(_record(id, tick, lots));
        assertEq(_state(id), expected);
        assertAccounting();
    }

    function test_DuplicateRecordsExecuteSequentially() public {
        uint256 id = order(false, -60, 100);
        _update(bytes.concat(_record(id, -120, 90), _record(id, -120, 80), _record(id, 0, 0)));
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining + claimable, 0);
        assertEq(book.nextOrderId(), 2);
        assertAccounting();
    }

    function test_MalformedEmptyOversizedAndNoncanonicalRecordsRevert() public {
        uint256 id = order(true, 60, 100);
        bytes32 before_ = _state(id);
        _bad("", Book.InvalidOrderUpdates.selector);
        _bad(new bytes(42), Book.InvalidOrderUpdates.selector);
        _bad(new bytes(44), Book.InvalidOrderUpdates.selector);
        _bad(new bytes(43 * 65), Book.BatchTooLarge.selector);
        _bad(_record(id, 60, 0), Book.InvalidOrderUpdates.selector);
        _bad(_record(id, 61, 100), Book.InvalidPrice.selector);
        _bad(_record(id, type(int24).min, 100), Book.InvalidPrice.selector);
        _bad(_record(id, type(int24).max, 100), Book.InvalidPrice.selector);
        assertEq(_state(id), before_);
    }

    function testFuzz_MalformedLengthsCannotSilentlyIgnoreTrailingBytes(uint16 length) public {
        length = uint16(bound(length, 1, 3000));
        vm.assume(length % 43 != 0);
        _bad(new bytes(length), Book.InvalidOrderUpdates.selector);
    }

    function test_DeadlineUnknownMarketAndUnauthorizedRecords() public {
        uint256 id = order(true, 60, 100);
        vm.warp(100);
        vm.prank(maker);
        vm.expectRevert(Book.DeadlineExpired.selector);
        book.updateOrders(market, _record(id, 60, 50), 99);
        vm.prank(maker);
        vm.expectRevert(Book.UnknownMarket.selector);
        book.updateOrders(bytes32(uint256(1)), _record(id, 60, 50), NEVER);
        vm.prank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.updateOrders(market, _record(id, 60, 50), NEVER);
        _bad(_record(0, 0, 0), Book.Unauthorized.selector);
    }

    function test_FailedLaterRecordRollsBackFillsClaimsAndEarlierUpdates() public {
        uint256 id = order(true, 0, 100);
        _fill(true, 40);
        bytes32 before_ = _state(id);
        _bad(bytes.concat(_record(id, 60, 80), _record(id, -60, 80)), Book.MarketableOrder.selector);
        assertEq(_state(id), before_);
        assertAccounting();
    }

    function test_CrossMarketRecordsRevertAtomically() public {
        uint256 first = order(true, 60, 100);
        Book.Config memory c = config();
        c.feePpm = 100;
        c.protocolDivisor = 4;
        bytes32 other = book.createMarket(c);
        vm.prank(maker);
        uint256 second = book.placeOrder(other, false, -60, 100, NEVER);
        bytes32 before_ = _state(first);
        _bad(bytes.concat(_record(first, 120, 50), _record(second, 0, 0)), Book.InvalidOrderUpdates.selector);
        assertEq(_state(first), before_);
        (, uint128 remaining,) = book.getOrder(second);
        assertEq(remaining, 100);
    }

    function test_SixtyFourRecordsAndWalletCancellation() public {
        bytes memory data;
        for (uint256 i; i < 64; ++i) {
            uint256 id = order(true, 60, 100);
            data = bytes.concat(data, _record(id, 0, 0));
        }
        uint256 beforeFree = book.balanceOf(maker, address(token0));
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.updateOrders, (market, data, NEVER));
        vm.prank(maker);
        book.executeWallet(calls, maker);
        assertEq(token0.balanceOf(maker), 6400 * LOT);
        assertEq(book.balanceOf(maker, address(token0)), beforeFree);
        assertAccounting();
    }

    function test_WalletUpdateNetsCollateralWithoutAllowance() public {
        uint256 ask = order(true, 60, 100);
        uint256 bid = order(false, -60, 100);
        vm.prank(maker);
        token0.approve(address(book), 0);
        bytes32 free =
            keccak256(abi.encode(book.balanceOf(maker, address(token0)), book.balanceOf(maker, address(token1))));
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            Book.updateOrders, (market, bytes.concat(_record(ask, 120, 100), _record(bid, -120, 100)), NEVER)
        );
        vm.prank(maker);
        book.executeWallet(calls, maker);
        assertEq(token0.balanceOf(maker), 0);
        assertGt(token1.balanceOf(maker), 0);
        assertEq(
            keccak256(abi.encode(book.balanceOf(maker, address(token0)), book.balanceOf(maker, address(token1)))), free
        );
        assertAccounting();
    }

    function test_WalletUnfundedIncreaseRevertsWholeBatch() public {
        uint256 id = order(true, 60, 100);
        bytes32 before_ = _state(id);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.updateOrders, (market, _record(id, 120, 101), NEVER));
        vm.prank(maker);
        vm.expectRevert();
        book.executeWallet(calls, maker);
        assertEq(_state(id), before_);
        assertAccounting();
    }

    function test_WalletCancelRemainingPreservesUnclaimedProceeds() public {
        uint256 id = order(true, 0, 100);
        _fill(true, 40);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.cancelRemaining, (id));
        vm.prank(maker);
        assertEq(abi.decode(book.executeWallet(calls, maker)[0], (uint128)), 60);
        assertEq(token0.balanceOf(maker), 60 * LOT);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining, 0);
        assertEq(claimable, 40);
        assertAccounting();
    }

    function testFuzz_PackedUint64QuantityIsNotTruncated(uint64 lots, bool ask) public {
        vm.assume(lots != 0);
        uint256 id = order(ask, 0, 1);
        _update(_record(id, 0, lots));
        (, uint128 remaining,) = book.getOrder(id);
        assertEq(remaining, lots);
        assertAccounting();
    }

    function _bad(bytes memory data, bytes4 reason) private {
        vm.prank(maker);
        vm.expectRevert(reason);
        book.updateOrders(market, data, NEVER);
    }

    function _state(uint256 id) private view returns (bytes32) {
        (Book.Order memory o, uint128 remaining, uint128 claimable) = book.getOrder(id);
        (uint256 a0, uint256 a1, uint256 o0, uint256 o1) = book.reserves(market);
        return keccak256(
            abi.encode(
                o,
                remaining,
                claimable,
                a0,
                a1,
                o0,
                o1,
                book.balanceOf(maker, address(token0)),
                book.balanceOf(maker, address(token1))
            )
        );
    }
}
