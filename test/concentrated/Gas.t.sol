// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { OrderBookAccounting as Orders } from "../../src/libraries/OrderBookAccounting.sol";

import { ConcentratedBase, Book, TickMath, FeeMath, CL } from "./Base.sol";

/// @notice Committed setup, cold-manager, callee-only snapshots. Excludes funding/withdrawal and tx intrinsic gas.
contract ConcentratedGasTest is ConcentratedBase {
    Book[27] internal fixtures;
    uint256 internal burnId;
    uint256 internal collectId;
    uint256 internal increaseId;
    uint256 internal cancelId;
    uint256 internal claimId;
    uint256 internal denseCancelId;
    uint256 internal denseClaimId;

    function setUp() public override {
        super.setUp();
        book = _newBook();
        market = book.createMarket(config());
        fund(lp);
        fixtures[0] = book;
        for (uint256 i = 1; i < fixtures.length; ++i) {
            book = _newBook();
            market = book.createMarket(config());
            fixtures[i] = book;
            fund(lp);
            fund(taker);
            fund(maker);
            if (i >= 20) {
                uint256 count = i <= 24 ? 4 ** (i - 19) : 128;
                for (uint256 j; j < count; ++j) {
                    uint256 o = order(true, 0, 100);
                    if (i == 25 && j == 64) denseCancelId = o;
                    if (i == 26 && j == 0) denseClaimId = o;
                }
                if (i == 25) trade(false, uint128(FeeMath.gross(6450 * LOT, 3000)));
                if (i == 26) trade(false, uint128(FeeMath.gross(12_800 * LOT, 3000)));
                continue;
            }
            if (i >= 9 && i <= 18) {
                if (i == 10) order(true, 0, 1024);
                if (i == 11 || i == 12 || i == 13) {
                    uint256 count = i == 12 ? 1024 : 128;
                    for (uint256 j; j < count; ++j) {
                        order(true, 0, i == 12 ? 1 : i == 11 ? 8 : 10);
                    }
                }
                if (i == 14 || i == 15) {
                    uint256 o = order(true, 0, 100);
                    if (i == 14) cancelId = o;
                    else claimId = o;
                    trade(false, uint128(FeeMath.gross((i == 14 ? 50 : 100) * LOT, 3000)));
                }
                if (i == 16 || i == 17) {
                    order(true, 0, 100);
                    if (i == 17) trade(false, uint128(FeeMath.gross(100 * LOT, 3000)));
                }
                continue;
            }
            uint256 p = full(lp, L);
            if (i == 1 || i == 2 || i == 4 || i == 5 || i == 6 || i == 8) trade(false, 1e18);
            if (i == 2) burnId = p;
            if (i == 4) collectId = p;
            if (i == 8) increaseId = p;
            if (i == 5) order(true, 60, 1000);
            if (i == 19) {
                trade(false, 1e18);
                trade(true, 1e18);
            }
            if (i == 6 || i == 19) {
                for (int24 j = 60; j <= 960; j += 60) {
                    mint(lp, j, j + 60, L);
                }
            }
        }
    }

    function test_Gas_MintFullRange() public {
        book = fixtures[0];
        (int24 low, int24 high) = book.fullRange(market);
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(lp);
        book.mint(market, low, high, L, type(uint256).max, type(uint256).max, NEVER);
        uint256 gasUsed = vm.snapshotGasLastCall(_group(), "mint_full_range");
        assertLt(gasUsed, 600_000);
    }

    function test_Gas_MintNarrowRange() public {
        book = fixtures[0];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(lp);
        book.mint(market, -60, 60, L, type(uint256).max, type(uint256).max, NEVER);
        uint256 gasUsed = vm.snapshotGasLastCall(_group(), "mint_narrow_range");
        assertLt(gasUsed, 600_000);
    }

    function test_Gas_BurnFullRange() public {
        book = fixtures[2];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(lp);
        book.burn(burnId, L, 0, 0, NEVER);
        uint256 gasUsed = vm.snapshotGasLastCall(_group(), "burn_full_range");
        assertLt(gasUsed, 250_000);
    }

    function test_Gas_CollectFullRange() public {
        book = fixtures[4];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(lp);
        book.collect(collectId);
        uint256 gasUsed = vm.snapshotGasLastCall(_group(), "collect_full_range");
        assertLt(gasUsed, 150_000);
    }

    function test_Gas_IncreaseFullRange() public {
        book = fixtures[8];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(lp);
        book.increase(increaseId, L, type(uint256).max, type(uint256).max, NEVER);
        vm.snapshotGasLastCall(_group(), "increase_full_range");
    }

    function test_Gas_EstablishedAMM() public {
        _measure(1, 1e18, "amm_established");
    }

    function test_Gas_FirstAMM() public {
        _measure(3, 1e18, "amm_first");
    }

    function test_Gas_LargeMoveFullRange() public {
        _measure(1, 1e25, "amm_large_move_full_range");
    }

    function test_Gas_MixedAMMOrder() public {
        _measure(5, 1e22, "amm_order_amm");
    }

    function test_Gas_Cross16InitializedBoundaries() public {
        _measure(6, 2e23, "amm_16_initialized_boundaries");
    }

    function test_Gas_CrossBoundariesBothFeeHistories() public {
        _measure(19, 2e23, "amm_boundaries_both_fee_histories");
    }

    function test_Gas_OrdinaryOneMaker() public {
        _measure(10, uint128(FeeMath.gross(1024 * LOT, 3000)), "ordinary_1_maker_full_level");
    }

    function test_Gas_Ordinary128Makers() public {
        _measure(11, uint128(FeeMath.gross(1024 * LOT, 3000)), "ordinary_128_makers_full_level");
    }

    function test_Gas_Ordinary1024Makers() public {
        _measure(12, uint128(FeeMath.gross(1024 * LOT, 3000)), "ordinary_1024_makers_full_level");
    }

    function test_Gas_OrdinaryPartialPrefix() public {
        _measure(13, uint128(FeeMath.gross(635 * LOT, 3000)), "ordinary_partial_prefix");
    }

    function test_Gas_PlaceFirstAtLevel() public {
        _place(9, "place_first_ask_level");
    }

    function test_Gas_PlaceSecondAtLevel() public {
        _place(16, "place_second_ask_level");
    }

    function test_Gas_PlaceReopenedLevel() public {
        _place(17, "place_reopened_ask_level");
    }

    function test_Gas_CancelPartiallyFilled() public {
        book = fixtures[14];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.cancelOrder(cancelId, 25);
        vm.snapshotGasLastCall(_group(), "cancel_partially_filled_ask");
    }

    function test_Gas_ClaimFilled() public {
        book = fixtures[15];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.claimOrder(claimId);
        vm.snapshotGasLastCall(_group(), "claim_filled_ask");
    }

    function test_Gas_PlaceFifthAtLevel() public {
        _place(20, "place_5th_ask_level");
    }

    function test_Gas_Place17thAtLevel() public {
        _place(21, "place_17th_ask_level");
    }

    function test_Gas_Place65thAtLevel() public {
        _place(22, "place_65th_ask_level");
    }

    function test_Gas_Place257thAtLevel() public {
        _place(23, "place_257th_ask_level");
    }

    function test_Gas_Place1025thAtLevel() public {
        _place(24, "place_1025th_ask_level");
    }

    function test_Gas_CancelDensePartiallyFilled() public {
        book = fixtures[25];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.cancelOrder(denseCancelId, 25);
        vm.snapshotGasLastCall(_group(), "cancel_dense_partially_filled_ask");
    }

    function test_Gas_ClaimDenseFilled() public {
        book = fixtures[26];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.claimOrder(denseClaimId);
        vm.snapshotGasLastCall(_group(), "claim_dense_filled_ask");
    }

    function _newBook() internal virtual returns (Book) {
        return new Book(address(this));
    }

    function _group() internal pure virtual returns (string memory) {
        return "ConcentratedRangeBook";
    }

    function _place(uint256 fixture, string memory name) private {
        book = fixtures[fixture];
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(maker);
        book.placeOrder(market, true, 0, 100, NEVER);
        vm.snapshotGasLastCall(_group(), name);
    }

    function _measure(uint256 fixture, uint128 amount, string memory name) private {
        book = fixtures[fixture];
        Book.TradeRequest memory r = request(false, amount);
        vm.cool(address(CL));
        vm.cool(address(Orders));
        vm.cool(address(book));
        vm.prank(taker);
        book.trade(r);
        vm.snapshotGasLastCall(_group(), name);
    }
}
