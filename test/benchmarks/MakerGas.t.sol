// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, FeeMath } from "../concentrated/Base.sol";
import { OrderBookAccounting as Orders } from "../../src/libraries/OrderBookAccounting.sol";
import { WalletSettlement as Wallet } from "../../src/libraries/WalletSettlement.sol";

/// @notice Compact maker batches measured against committed state, with 5 bp market fees.
/// @dev Callee execution before refunds/intrinsic gas. Untouched quotes are explicit no-ops, not replacements.
contract MakerGasTest is ConcentratedBase {
    Book internal ten;
    Book internal sixtyFour;
    Book internal partiallyFilled;

    function config() internal view override returns (Book.Config memory) {
        return Book.Config(address(token0), address(token1), LOT, 1, 500, 4, Q96);
    }

    function setUp() public override {
        super.setUp();
        full(lp, L);
        _ladder(10);
        ten = book;
        book = new Book(address(this));
        market = book.createMarket(config());
        fund(lp);
        fund(maker);
        fund(taker);
        full(lp, L);
        _ladder(64);
        sixtyFour = book;
        book = new Book(address(this));
        market = book.createMarket(config());
        fund(lp);
        fund(maker);
        fund(taker);
        full(lp, L);
        order(true, 0, 100);
        trade(false, uint128(FeeMath.gross(50 * LOT, 500)));
        partiallyFilled = book;
    }

    function _ladder(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            order(i % 2 == 0, (int24(int256(i / 2)) + 1) * (i % 2 == 0 ? int24(1) : -int24(1)), 1e6);
        }
    }

    function test_Gas_PackedTenNewPrices() public {
        _packed(10, 0, false, "packed_ten_new_prices");
    }

    function test_Gas_PackedSixtyFourNewPrices() public {
        _packed(64, 0, false, "packed_64_new_prices");
    }

    function test_Gas_PackedTenNoChanges() public {
        _packed(10, 1, false, "packed_ten_unchanged");
    }

    function test_Gas_PackedTenSizeReductions() public {
        _packed(10, 2, false, "packed_ten_reduce_size");
    }

    function test_Gas_PackedTenSizeIncreases() public {
        _packed(10, 3, false, "packed_ten_increase_size");
    }

    function test_Gas_PackedTenCancels() public {
        _packed(10, 4, false, "packed_ten_cancel_remaining");
    }

    function test_Gas_PackedSixtyFourCancels() public {
        _packed(64, 4, false, "packed_64_cancel_remaining");
    }

    function test_Gas_WalletPackedTenNewPrices() public {
        _packed(10, 0, true, "wallet_packed_ten_new_prices");
    }

    function test_Gas_CancelRemainingAfterPartialFill() public {
        book = partiallyFilled;
        _cool();
        vm.prank(maker);
        uint128 cancelled = book.cancelRemaining(1);
        vm.snapshotGasLastCall("MakerOperations", "cancel_remaining_partial_fill");
        assertEq(cancelled, 50);
    }

    function _packed(uint256 count, uint256 mode, bool wallet, string memory label) private {
        book = count == 10 ? ten : sixtyFour;
        bytes memory data;
        for (uint256 i; i < count; ++i) {
            int24 tick = (int24(int256(i / 2)) + 1) * (i % 2 == 0 ? int24(1) : -int24(1));
            uint64 lots = 1e6;
            if (mode == 0) tick += i % 2 == 0 ? int24(int256(count / 2)) : -int24(int256(count / 2));
            if (mode == 2) lots /= 2;
            if (mode == 3) lots *= 2;
            if (mode == 4) {
                tick = 0;
                lots = 0;
            }
            data = bytes.concat(data, abi.encodePacked(i + 1, tick, lots));
        }
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Book.updateOrders, (market, data, NEVER));
        _cool();
        vm.prank(maker);
        if (wallet) book.executeWallet(calls, maker);
        else book.updateOrders(market, data, NEVER);
        vm.snapshotGasLastCall("MakerOperations", label);
        for (uint256 i = 1; i <= count; ++i) {
            (, uint128 remaining, uint128 claimable) = book.getOrder(i);
            assertEq(remaining, mode == 4 ? 0 : mode == 3 ? 2e6 : mode == 2 ? 5e5 : 1e6);
            assertEq(claimable, 0);
        }
        assertEq(book.nextOrderId(), count + 1);
    }

    function _cool() private {
        vm.cool(address(book));
        vm.cool(address(Orders));
        vm.cool(address(Wallet));
        vm.cool(address(token0));
        vm.cool(address(token1));
    }
}
