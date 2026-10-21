// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ConcentratedRangeBook as Book } from "../../src/ConcentratedRangeBook.sol";
import { ConcentratedLiquidity as CL } from "../../src/libraries/ConcentratedLiquidity.sol";
import { TickMath } from "../../src/vendor/uniswap/TickMath.sol";
import { SqrtPriceMath } from "../../src/vendor/uniswap/SqrtPriceMath.sol";
import { SwapMath } from "../../src/vendor/uniswap/SwapMath.sol";
import { FeeMath } from "../../src/libraries/FeeMath.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

abstract contract ConcentratedBase is Test {
    Book internal book;
    MockERC20 internal token0;
    MockERC20 internal token1;
    bytes32 internal market;
    address internal lp = makeAddr("concentrated-lp");
    address internal lp2 = makeAddr("concentrated-lp2");
    address internal maker = makeAddr("concentrated-maker");
    address internal taker = makeAddr("concentrated-taker");
    uint64 internal constant NEVER = type(uint64).max;
    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant L = 1e24;
    uint128 internal constant LOT = 1e12;

    function setUp() public virtual {
        book = new Book(address(this));
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        market = book.createMarket(config());
        fund(lp);
        fund(lp2);
        fund(maker);
        fund(taker);
    }

    function config() internal view virtual returns (Book.Config memory) {
        return Book.Config(address(token0), address(token1), LOT, 60, 3000, 6, Q96);
    }

    function fund(address owner) internal {
        token0.mint(owner, 1e35);
        token1.mint(owner, 1e35);
        vm.startPrank(owner);
        token0.approve(address(book), type(uint256).max);
        token1.approve(address(book), type(uint256).max);
        book.deposit(address(token0), 1e35, owner);
        book.deposit(address(token1), 1e35, owner);
        vm.stopPrank();
    }

    function mint(address owner, int24 low, int24 high, uint128 liquidity) internal returns (uint256 id) {
        vm.prank(owner);
        (id,,) = book.mint(market, low, high, liquidity, type(uint256).max, type(uint256).max, NEVER);
    }

    function full(address owner, uint128 liquidity) internal returns (uint256 id) {
        (int24 low, int24 high) = book.fullRange(market);
        return mint(owner, low, high, liquidity);
    }

    function request(bool down, uint128 input) internal view returns (Book.TradeRequest memory) {
        return Book.TradeRequest(
            market, down, input, down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, 0, 128, NEVER, false
        );
    }

    function trade(bool down, uint128 input) internal returns (Book.TradeResult memory) {
        vm.prank(taker);
        return book.trade(request(down, input));
    }

    function order(bool ask, int24 tick, uint128 lots) internal returns (uint256 id) {
        vm.prank(maker);
        return book.placeOrder(market, ask, tick, lots, NEVER);
    }

    function assertAccounting() internal view {
        (uint256 a0, uint256 a1, uint256 o0, uint256 o1) = book.reserves(market);
        uint256 free0;
        uint256 free1;
        address[4] memory owners = [lp, lp2, maker, taker];
        for (uint256 i; i < owners.length; ++i) {
            free0 += book.balanceOf(owners[i], address(token0));
            free1 += book.balanceOf(owners[i], address(token1));
        }
        assertEq(free0 + a0 + o0 + book.protocolFees(address(token0)), book.totalLiability(address(token0)));
        assertEq(free1 + a1 + o1 + book.protocolFees(address(token1)), book.totalLiability(address(token1)));
        assertEq(token0.balanceOf(address(book)), book.totalLiability(address(token0)));
        assertEq(token1.balanceOf(address(book)), book.totalLiability(address(token1)));
    }
}
