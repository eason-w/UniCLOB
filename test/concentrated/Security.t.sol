// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, TickMath, CL, FeeMath } from "./Base.sol";
import { TaxToken, CallbackToken, NoReturnToken, FalseReturnToken } from "../mocks/HostileTokens.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract ConcentratedSecurityTest is ConcentratedBase {
    function test_TaxedDepositAndWithdrawalRollBackLiabilities() public {
        TaxToken taxed = new TaxToken();
        taxed.mint(address(this), 1e21);
        taxed.approve(address(book), type(uint256).max);
        taxed.setTax(true);
        vm.expectRevert(Book.UnsupportedToken.selector);
        book.deposit(address(taxed), 1e20, address(this));
        assertEq(book.totalLiability(address(taxed)), 0);
        taxed.setTax(false);
        book.deposit(address(taxed), 1e20, address(this));
        taxed.setTax(true);
        vm.expectRevert(Book.UnsupportedToken.selector);
        book.withdraw(address(taxed), 1e20, address(this));
        assertEq(book.balanceOf(address(this), address(taxed)), 1e20);
        assertEq(book.totalLiability(address(taxed)), 1e20);
    }

    function test_TokenCannotReenterThroughMulticall() public {
        CallbackToken callback = new CallbackToken();
        callback.mint(address(this), 1e20);
        callback.approve(address(book), type(uint256).max);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(book.deposit, (address(callback), 1, address(callback)));
        callback.configure(address(book), abi.encodeCall(book.multicall, (calls)));
        book.deposit(address(callback), 1e20, address(this));
        assertTrue(callback.attempted());
        assertFalse(callback.succeeded());
        assertEq(book.totalLiability(address(callback)), 1e20);
    }

    function test_LegacyNoReturnSupportedAndFalseReturnRejected() public {
        NoReturnToken legacy = new NoReturnToken();
        legacy.mint(address(this), 1e20);
        legacy.approve(address(book), type(uint256).max);
        book.deposit(address(legacy), 1e20, address(this));
        book.withdraw(address(legacy), 1e20, address(this));
        assertEq(book.totalLiability(address(legacy)), 0);
        FalseReturnToken bad = new FalseReturnToken();
        bad.mint(address(this), 1e20);
        bad.approve(address(book), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        book.deposit(address(bad), 1e20, address(this));
    }

    function test_ProtocolAuthorityCannotAccessUserReserves() public {
        full(lp, L);
        trade(false, 1e21);
        uint256 earned = book.protocolFees(address(token1));
        vm.prank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.collectProtocol(address(token1), earned, taker);
        vm.expectRevert(Book.InsufficientBalance.selector);
        book.collectProtocol(address(token1), earned + 1, address(this));
        book.collectProtocol(address(token1), earned, address(this));
        assertAccounting();
    }

    function test_OrdersAndPositionsCannotBeStolen() public {
        uint256 p = full(lp, L);
        uint256 o = order(true, 60, 100);
        vm.startPrank(taker);
        vm.expectRevert(Book.Unauthorized.selector);
        book.increase(p, 1, 100, 100, NEVER);
        vm.expectRevert(Book.Unauthorized.selector);
        book.burn(p, L, 0, 0, NEVER);
        vm.expectRevert(Book.Unauthorized.selector);
        book.claimOrder(o);
        vm.expectRevert(Book.Unauthorized.selector);
        book.cancelOrder(o, 1);
        vm.stopPrank();
    }

    function test_MulticallPreservesOwnerAndAtomicity() public {
        full(lp, L);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(book.trade, (request(false, 1e18)));
        calls[1] = abi.encodeCall(book.withdraw, (address(token0), type(uint256).max, taker));
        vm.prank(taker);
        vm.expectRevert(Book.InsufficientBalance.selector);
        book.multicall(calls);
        (, uint160 price,,) = book.getMarket(market);
        assertEq(price, Q96);
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(book.trade, (request(false, 1e18)));
        vm.prank(taker);
        book.multicall(calls);
        (, price,,) = book.getMarket(market);
        assertGt(price, Q96);
        assertAccounting();
    }

    function test_InvalidAndCrossedOrdersRejected() public {
        vm.startPrank(maker);
        vm.expectRevert(Book.InvalidPrice.selector);
        book.placeOrder(market, true, 1, 1, NEVER);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.placeOrder(market, true, 60, 0, NEVER);
        vm.expectRevert(Book.MarketableOrder.selector);
        book.placeOrder(market, true, -60, 100, NEVER);
        vm.expectRevert(Book.MarketableOrder.selector);
        book.placeOrder(market, false, 60, 100, NEVER);
        book.placeOrder(market, true, 0, 100, NEVER);
        vm.expectRevert(Book.MarketableOrder.selector);
        book.placeOrder(market, false, 0, 100, NEVER);
        vm.stopPrank();
    }

    function test_UnsupportedConfigurationAndRangeRejected() public {
        Book.Config memory c = config();
        c.protocolDivisor = 4;
        vm.expectRevert(Book.InvalidConfiguration.selector);
        book.createMarket(c);
        c = config();
        c.tickSpacing = 0;
        vm.expectRevert(Book.InvalidConfiguration.selector);
        book.createMarket(c);
        c = config();
        c.token1 = c.token0;
        vm.expectRevert(Book.InvalidConfiguration.selector);
        book.createMarket(c);
        vm.prank(lp);
        vm.expectRevert(CL.InvalidRange.selector);
        book.mint(market, -1, 60, L, type(uint256).max, type(uint256).max, NEVER);
        vm.prank(lp);
        vm.expectRevert(Book.InvalidAmount.selector);
        book.mint(market, -60, 60, uint128(type(int128).max) + 1, type(uint256).max, type(uint256).max, NEVER);
    }

    function test_SpacingOneSupportsEntire1774544TickSpan() public {
        Book.Config memory c = config();
        c.tickSpacing = 1;
        market = book.createMarket(c);
        (int24 low, int24 high) = book.fullRange(market);
        assertEq(low, -887_272);
        assertEq(high, 887_272);
        uint256 p = full(lp, L);
        Book.TradeResult memory r = trade(false, 1e25);
        assertEq(r.steps, 1);
        vm.prank(lp);
        book.burn(p, L, 0, 0, NEVER);
        assertAccounting();
    }

    function testFuzz_EmptyRoundTripNeverCreatesTokens(uint128 raw, uint8 count) public {
        uint128 liquidity = uint128(bound(raw, 1, 1e25));
        count = uint8(bound(count, 1, 15));
        uint256 before0 = book.balanceOf(lp, address(token0));
        uint256 before1 = book.balanceOf(lp, address(token1));
        for (uint256 i; i < count; ++i) {
            uint256 p = full(lp, liquidity);
            vm.prank(lp);
            book.burn(p, liquidity, 0, 0, NEVER);
        }
        assertLe(book.balanceOf(lp, address(token0)), before0);
        assertLe(book.balanceOf(lp, address(token1)), before1);
        assertAccounting();
    }

    function testFuzz_CollectFrequencyDoesNotIncreaseFees(uint8 count) public {
        count = uint8(bound(count, 1, 30));
        uint256 frequent = full(lp, L);
        uint256 once = full(lp2, L);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            trade(false, 1e18);
            vm.prank(lp);
            (, uint256 fee) = book.collect(frequent);
            total += fee;
        }
        vm.prank(lp2);
        (, uint256 finalFee) = book.collect(once);
        assertEq(total, finalFee);
        assertAccounting();
    }
}
