// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { OrderBookAccounting as Orders } from "../../src/libraries/OrderBookAccounting.sol";

import { ConcentratedBase, Book, FeeMath } from "./Base.sol";

/// @notice Real core costs at the former 4096-append limit; committed state and cold manager.
contract QueueCapacityGasTest is ConcentratedBase {
    Book private expanded;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 4096; ++i) {
            order(true, 0, 10);
        }
        Book original = book;
        expanded = new Book(address(this));
        book = expanded;
        assertEq(book.createMarket(config()), market);
        fund(maker);
        fund(taker);
        for (uint256 i; i < 4097; ++i) {
            order(true, 0, 10);
        }
        book = original;
    }

    function test_Gas_Append4097thOrder() public {
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        uint256 id = book.placeOrder(market, true, 0, 10, NEVER);
        vm.snapshotGasLastCall("QueueCapacity", "append_4097th_order");
        (Book.Order memory o, uint128 remaining,) = book.getOrder(id);
        assertEq(o.sequence, 4096);
        assertEq(remaining, 10);
    }

    function test_Gas_Consume4096MakersAtOnce() public {
        vm.cool(address(Orders));
        vm.cool(address(book));
        Book.TradeRequest memory r = request(false, uint128(FeeMath.gross(40_960 * LOT, 3000)));
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        vm.snapshotGasLastCall("QueueCapacity", "fill_4096_makers");
        assertEq(result.output, 40_960 * LOT);
        assertEq(result.steps, 1);
        (, uint128 remaining, uint128 claimable) = book.getOrder(4096);
        assertEq(remaining, 0);
        assertEq(claimable, 10);
    }

    function test_Gas_PartialPrefixAfter4097thAppend() public {
        book = expanded;
        vm.cool(address(Orders));
        vm.cool(address(book));
        Book.TradeRequest memory r = request(false, uint128(FeeMath.gross(20_485 * LOT, 3000)));
        vm.prank(taker);
        book.trade(r);
        vm.snapshotGasLastCall("QueueCapacity", "partial_prefix_seven_levels");
        (, uint128 remaining,) = book.getOrder(2049);
        assertEq(remaining, 5);
    }

    function test_Gas_CancelAtSevenLevels() public {
        book = expanded;
        uint256 id = 4097;
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.cancelOrder(id, 1);
        vm.snapshotGasLastCall("QueueCapacity", "cancel_seven_levels");
        (, uint128 remaining,) = book.getOrder(id);
        assertEq(remaining, 9);
    }
}
