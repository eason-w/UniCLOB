// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { OrderBookAccounting as Orders } from "../../src/libraries/OrderBookAccounting.sol";

import { ConcentratedBase, Book, TickMath, FeeMath } from "../concentrated/Base.sol";

/// @notice Custody, market-making and price-level traversal benchmarks against committed state.
/// @dev Spacing 1 gives ~1 bp increments. Order/trade rows are prefunded; custody rows include token calls.
///      All measurements exclude transaction intrinsic gas, refunds and L2 data costs.
contract HybridUserGasTest is ConcentratedBase {
    Book[10] internal fixtures;
    address internal newcomer = makeAddr("new-benchmark-user");
    address internal recipient = makeAddr("new-benchmark-recipient");
    uint128 internal constant QUOTE_LOTS = 1e6;

    function config() internal view override returns (Book.Config memory) {
        return Book.Config(address(token0), address(token1), LOT, 1, 500, 4, Q96);
    }

    function setUp() public override {
        super.setUp();
        fixtures[0] = book;
        for (uint256 i = 1; i < fixtures.length; ++i) {
            book = new Book(address(this));
            market = book.createMarket(config());
            fixtures[i] = book;
            fund(lp);
            fund(maker);
            fund(taker);
            if (i != 5 && i != 6 && i != 8 && i != 9) full(lp, L);
            if (i == 2 || i == 3) {
                uint256 levels = i == 2 ? 1 : 5;
                for (uint256 j = 1; j <= levels; ++j) {
                    order(true, int24(int256(j)), QUOTE_LOTS);
                    order(false, -int24(int256(j)), QUOTE_LOTS);
                }
            }
            if (i == 4 || i == 5 || i == 6) {
                for (int24 j = 1; j <= 10; ++j) {
                    order(true, j, QUOTE_LOTS);
                }
                if (i == 6) {
                    Book.TradeRequest memory r = request(false, 2e19);
                    r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(10);
                    vm.prank(taker);
                    book.trade(r);
                }
            }
            if (i == 7 || i == 8 || i == 9) {
                order(i == 7, 0, 100);
                trade(i != 7, uint128(FeeMath.gross((i == 9 ? 100 : 50) * LOT, 500)));
            }
        }
        token0.mint(lp, 1e18);
        token0.mint(newcomer, 1e30);
        vm.prank(newcomer);
        token0.approve(address(fixtures[0]), type(uint256).max);
    }

    function test_Gas_DepositFirstUserCredit() public {
        book = fixtures[0];
        _cool();
        vm.prank(newcomer);
        book.deposit(address(token0), 1e12, newcomer);
        vm.snapshotGasLastCall("HybridUser", "deposit_first_user_credit");
        assertEq(book.balanceOf(newcomer, address(token0)), 1e12);
    }

    function test_Gas_DepositExistingUserCredit() public {
        book = fixtures[0];
        _cool();
        vm.prank(lp);
        book.deposit(address(token0), 1e12, lp);
        vm.snapshotGasLastCall("HybridUser", "deposit_existing_user_credit");
    }

    function test_Gas_WithdrawPartialExistingRecipient() public {
        _withdraw(1e12, lp, "withdraw_partial_existing_recipient");
    }

    function test_Gas_WithdrawAllExistingRecipient() public {
        _withdraw(1e35, lp, "withdraw_all_existing_recipient");
    }

    function test_Gas_WithdrawNewRecipient() public {
        _withdraw(1e12, recipient, "withdraw_new_recipient");
    }

    function test_Gas_CreateMarket() public {
        book = fixtures[0];
        Book.Config memory c = config();
        c.initialSqrtPriceX96 = Q96 + 1;
        _cool();
        book.createMarket(c);
        vm.snapshotGasLastCall("HybridUser", "create_market");
    }

    function test_Gas_PostAskWithAMM() public {
        _post(true);
    }

    function test_Gas_PostBidWithAMM() public {
        _post(false);
    }

    function test_Gas_PostTwoSidedQuote() public {
        _postQuotes(1, "post_two_sided_quote");
    }

    function test_Gas_PostTenQuotes() public {
        _postQuotes(5, "post_ten_quotes");
    }

    function test_Gas_CancelAskFully() public {
        _cancel(2, 1, QUOTE_LOTS, "cancel_ask_full");
    }

    function test_Gas_CancelBidFully() public {
        _cancel(2, 2, QUOTE_LOTS, "cancel_bid_full");
    }

    function test_Gas_CancelBidPartially() public {
        _cancel(8, 1, 25, "cancel_bid_partial_after_fill");
    }

    function test_Gas_ReplaceTwoQuotesSamePrices() public {
        _replace(2, 1, 0, "replace_two_same_prices");
    }

    function test_Gas_ReplaceTwoQuotesNewPrices() public {
        _replace(2, 1, 1, "replace_two_new_prices");
    }

    function test_Gas_ReplaceTenQuotesSamePrices() public {
        _replace(3, 5, 0, "replace_ten_same_prices");
    }

    function test_Gas_ReplaceTenQuotesNewPrices() public {
        _replace(3, 5, 5, "replace_ten_new_prices");
    }

    function test_Gas_ReuseTwoQuotesSamePrices() public {
        _reuse(2, 1, 0, "reuse_two_same_prices");
    }

    function test_Gas_ReuseTwoQuotesNewPrices() public {
        _reuse(2, 1, 1, "reuse_two_new_prices");
    }

    function test_Gas_ReuseTenQuotesSamePrices() public {
        _reuse(3, 5, 0, "reuse_ten_same_prices");
    }

    function test_Gas_ReuseTenQuotesNewPrices() public {
        _reuse(3, 5, 5, "reuse_ten_new_prices");
    }

    function _reuse(uint256 index, uint256 levels, uint256 shift, string memory label) private {
        book = fixtures[index];
        bytes[] memory calls = new bytes[](levels * 2);
        for (uint256 i; i < levels; ++i) {
            int24 tick = int24(int256(i + shift + 1));
            calls[i * 2] = abi.encodeCall(Book.replaceOrder, (i * 2 + 1, tick, QUOTE_LOTS, NEVER));
            calls[i * 2 + 1] = abi.encodeCall(Book.replaceOrder, (i * 2 + 2, -tick, QUOTE_LOTS, NEVER));
        }
        _batch(calls, label);
        assertEq(book.nextOrderId(), levels * 2 + 1);
        for (uint256 i = 1; i <= levels * 2; ++i) {
            (, uint128 remaining, uint128 claimable) = book.getOrder(i);
            assertEq(remaining, QUOTE_LOTS);
            assertEq(claimable, 0);
        }
    }

    function test_Gas_CancelTenQuotes() public {
        book = fixtures[3];
        bytes[] memory calls = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            calls[i] = abi.encodeCall(Book.cancelOrder, (i + 1, QUOTE_LOTS));
        }
        _batch(calls, "cancel_ten_quotes");
        for (uint256 i = 1; i <= 10; ++i) {
            (, uint128 remaining,) = book.getOrder(i);
            assertEq(remaining, 0);
        }
    }

    function test_Gas_ClaimTenFilledAsks() public {
        book = fixtures[6];
        bytes[] memory calls = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            calls[i] = abi.encodeCall(Book.claimOrder, (i + 1));
        }
        _batch(calls, "claim_ten_filled_asks");
        for (uint256 i = 1; i <= 10; ++i) {
            (, uint128 remaining, uint128 claimable) = book.getOrder(i);
            assertEq(remaining + claimable, 0);
        }
    }

    function test_Gas_ClaimFilledBid() public {
        book = fixtures[9];
        _cool();
        vm.prank(maker);
        book.claimOrder(1);
        vm.snapshotGasLastCall("HybridUser", "claim_filled_bid");
    }

    function test_Gas_ClaimCancelAndReplacePartiallyFilledAsk() public {
        book = fixtures[7];
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Book.claimOrder, (uint256(1)));
        calls[1] = abi.encodeCall(Book.cancelOrder, (uint256(1), uint128(50)));
        calls[2] = abi.encodeCall(Book.placeOrder, (market, true, int24(1), uint128(100), NEVER));
        _batch(calls, "claim_cancel_replace_partial_ask");
        (, uint128 remaining, uint128 claimable) = book.getOrder(1);
        assertEq(remaining + claimable, 0);
        (, remaining,) = book.getOrder(2);
        assertEq(remaining, 100);
    }

    function test_Gas_SweepTenOrdinaryLevels() public {
        _sweep(5, "sweep_ten_ordinary_levels");
    }

    function test_Gas_SweepTenHybridLevels() public {
        _sweep(4, "sweep_ten_hybrid_levels");
    }

    function test_Gas_CollectProtocolFees() public {
        book = fixtures[7];
        uint256 amount = book.protocolFees(address(token1));
        _cool();
        book.collectProtocol(address(token1), amount, recipient);
        vm.snapshotGasLastCall("HybridUser", "collect_protocol_fees");
        assertEq(book.protocolFees(address(token1)), 0);
    }

    /// @notice Empty tails must not turn an arbitrary taker limit into the next posting anchor.
    function test_EmptyTailRetainsLastExecutionPrice() public {
        book = fixtures[5]; // Ten ask levels and no AMM liquidity.
        Book.TradeRequest memory r = request(false, 1e22);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(120);
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        assertEq(result.output, uint256(10) * QUOTE_LOTS * LOT);
        assertLt(result.input, r.maxInput);
        (, uint160 price,,) = book.getMarket(market);
        // The last fill, rather than the unused limit, anchors subsequent posting.
        assertEq(price, TickMath.getSqrtPriceAtTick(10));
        (bool hasBid,) = book.bestOrder(market, false);
        assertFalse(hasBid);
        vm.prank(maker);
        book.placeOrder(market, true, 11, QUOTE_LOTS, NEVER);
    }

    function _withdraw(uint256 amount, address to, string memory label) private {
        book = fixtures[0];
        _cool();
        vm.prank(lp);
        book.withdraw(address(token0), amount, to);
        vm.snapshotGasLastCall("HybridUser", label);
    }

    function _post(bool ask) private {
        book = fixtures[1];
        _cool();
        vm.prank(maker);
        book.placeOrder(market, ask, ask ? int24(1) : -1, QUOTE_LOTS, NEVER);
        vm.snapshotGasLastCall("HybridUser", ask ? "post_ask_new_level_with_amm" : "post_bid_new_level_with_amm");
    }

    function _postQuotes(uint256 levels, string memory label) private {
        book = fixtures[1];
        bytes[] memory calls = new bytes[](levels * 2);
        for (uint256 i; i < levels; ++i) {
            calls[i * 2] = abi.encodeCall(Book.placeOrder, (market, true, int24(int256(i + 1)), QUOTE_LOTS, NEVER));
            calls[i * 2 + 1] =
                abi.encodeCall(Book.placeOrder, (market, false, -int24(int256(i + 1)), QUOTE_LOTS, NEVER));
        }
        _batch(calls, label);
    }

    function _cancel(uint256 index, uint256 id, uint128 lots, string memory label) private {
        book = fixtures[index];
        _cool();
        vm.prank(maker);
        book.cancelOrder(id, lots);
        vm.snapshotGasLastCall("HybridUser", label);
    }

    function _replace(uint256 index, uint256 levels, uint256 shift, string memory label) private {
        book = fixtures[index];
        bytes[] memory calls = new bytes[](levels * 4);
        for (uint256 i; i < levels * 2; ++i) {
            calls[i] = abi.encodeCall(Book.cancelOrder, (i + 1, QUOTE_LOTS));
        }
        for (uint256 i; i < levels; ++i) {
            int24 tick = int24(int256(i + shift + 1));
            calls[levels * 2 + i * 2] = abi.encodeCall(Book.placeOrder, (market, true, tick, QUOTE_LOTS, NEVER));
            calls[levels * 2 + i * 2 + 1] = abi.encodeCall(Book.placeOrder, (market, false, -tick, QUOTE_LOTS, NEVER));
        }
        _batch(calls, label);
        for (uint256 i = 1; i <= levels * 2; ++i) {
            (, uint128 remaining,) = book.getOrder(i);
            assertEq(remaining, 0);
            (, remaining,) = book.getOrder(i + levels * 2);
            assertEq(remaining, QUOTE_LOTS);
        }
    }

    function _sweep(uint256 index, string memory label) private {
        book = fixtures[index];
        Book.TradeRequest memory r = request(false, 1e22);
        r.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(10);
        _cool();
        vm.prank(taker);
        Book.TradeResult memory result = book.trade(r);
        vm.snapshotGasLastCall("HybridUser", label);
        assertEq(result.steps, 10);
        assertGt(result.orderInput, 0);
        if (index == 4) assertGt(result.ammInput, 0);
        else assertEq(result.ammInput, 0);
        for (uint256 i = 1; i <= 10; ++i) {
            (, uint128 remaining,) = book.getOrder(i);
            assertEq(remaining, 0);
        }
    }

    function _batch(bytes[] memory calls, string memory label) private {
        _cool();
        vm.prank(maker);
        book.multicall(calls);
        vm.snapshotGasLastCall("HybridUser", label);
    }

    function _cool() private {
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.cool(address(token0));
        vm.cool(address(token1));
    }
}
