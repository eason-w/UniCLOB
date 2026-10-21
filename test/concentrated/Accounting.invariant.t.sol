// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Book, TickMath, MockERC20 } from "./Base.sol";

/// @notice Stateful sequence generator with real principal, fee and order exits after each campaign.
contract ConcentratedHandler is Test {
    Book public book;
    MockERC20 public token0;
    MockERC20 public token1;
    bytes32 public market;
    uint256[] public positionIds;
    uint256[] public orderIds;
    uint256 public trades;
    uint256 public expectedDustStops;
    uint256 public added;
    uint256 public burned;
    uint256 public collected;
    uint256 public posted;
    uint256 public cancelled;
    uint256 public claimed;
    uint64 private constant NEVER = type(uint64).max;

    constructor(Book book_, MockERC20 t0, MockERC20 t1, bytes32 id) {
        book = book_;
        token0 = t0;
        token1 = t1;
        market = id;
        t0.mint(address(this), 1e35);
        t1.mint(address(this), 1e35);
        t0.approve(address(book), type(uint256).max);
        t1.approve(address(book), type(uint256).max);
        book.deposit(address(t0), 1e35, address(this));
        book.deposit(address(t1), 1e35, address(this));
        (int24 low, int24 high) = book.fullRange(market);
        (uint256 first,,) = book.mint(market, low, high, 1e24, type(uint256).max, type(uint256).max, NEVER);
        positionIds.push(first);
    }

    function swap(bool down, uint128 raw) external {
        uint128 amount = uint128(bound(raw, 1e15, 1e23));
        Book.TradeRequest memory r = Book.TradeRequest(
            market, down, amount, down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, 0, 128, NEVER, false
        );
        try book.trade(r) {
            ++trades;
        } catch (bytes memory reason) {
            // An unaffordable ordinary lot at the current price must stop execution.
            assertEq(bytes4(reason), Book.InvalidAmount.selector);
            ++expectedDustStops;
        }
    }

    function addRange(uint24 rawWidth, uint128 rawL) external {
        if (positionIds.length >= 32) return;
        (,, int24 tick,) = book.getMarket(market);
        int24 center = (tick / 60) * 60;
        int24 width = int24(uint24(bound(rawWidth, 1, 200))) * 60;
        int24 low = center - width;
        int24 high = center + width;
        if (low < -887_220 || high > 887_220) return;
        uint128 liquidity = uint128(bound(rawL, 1e12, 1e24));
        (uint256 id,,) = book.mint(market, low, high, liquidity, type(uint256).max, type(uint256).max, NEVER);
        positionIds.push(id);
        ++added;
    }

    function increase(uint256 seed, uint128 rawL) external {
        uint256 id = positionIds[seed % positionIds.length];
        uint128 liquidity = uint128(bound(rawL, 1e12, 1e23));
        book.increase(id, liquidity, type(uint256).max, type(uint256).max, NEVER);
        ++added;
    }

    function burn(uint256 seed, uint128 rawL) external {
        // Keep the seed range until campaign teardown, ensuring useful swaps remain possible.
        if (positionIds.length < 2) return;
        uint256 id = positionIds[1 + seed % (positionIds.length - 1)];
        uint128 liquidity = book.getPosition(id).accounting.liquidity;
        if (liquidity == 0) return;
        book.burn(id, uint128(bound(rawL, 1, liquidity)), 0, 0, NEVER);
        ++burned;
    }

    function collect(uint256 seed) external {
        book.collect(positionIds[seed % positionIds.length]);
        ++collected;
    }

    function post(bool ask, uint24 distance, uint64 rawLots) external {
        if (orderIds.length >= 64) return;
        (,, int24 current,) = book.getMarket(market);
        int24 center = (current / 60) * 60;
        int24 step = int24(uint24(bound(distance, 1, 20))) * 60;
        int24 tick = ask ? center + step : center - step;
        if (tick <= -887_220 || tick >= 887_220) return;
        (bool found, int24 other) = book.bestOrder(market, !ask);
        if (found && (ask ? tick <= other : tick >= other)) return;
        uint128 lots = uint128(bound(rawLots, 1, 1e9));
        orderIds.push(book.placeOrder(market, ask, tick, lots, NEVER));
        ++posted;
    }

    function cancel(uint256 seed, uint64 rawLots) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[seed % orderIds.length];
        (, uint128 remaining,) = book.getOrder(id);
        if (remaining == 0) return;
        book.cancelOrder(id, uint128(bound(rawLots, 1, remaining)));
        ++cancelled;
    }

    function claim(uint256 seed) external {
        if (orderIds.length == 0) return;
        book.claimOrder(orderIds[seed % orderIds.length]);
        ++claimed;
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function exitAll() external {
        for (uint256 i; i < orderIds.length; ++i) {
            (, uint128 remaining,) = book.getOrder(orderIds[i]);
            if (remaining != 0) book.cancelOrder(orderIds[i], remaining);
            book.claimOrder(orderIds[i]);
        }
        for (uint256 i; i < positionIds.length; ++i) {
            uint128 liquidity = book.getPosition(positionIds[i]).accounting.liquidity;
            if (liquidity != 0) book.burn(positionIds[i], liquidity, 0, 0, NEVER);
            else book.collect(positionIds[i]);
        }
        book.withdraw(address(token0), book.balanceOf(address(this), address(token0)), address(this));
        book.withdraw(address(token1), book.balanceOf(address(this), address(token1)), address(this));
    }
}

contract ConcentratedAccountingInvariant is StdInvariant, Test {
    Book internal book;
    MockERC20 internal t0;
    MockERC20 internal t1;
    bytes32 internal market;
    ConcentratedHandler internal handler;

    function setUp() public {
        book = new Book(address(this));
        t0 = new MockERC20("T0", "T0", 18);
        t1 = new MockERC20("T1", "T1", 18);
        market = book.createMarket(Book.Config(address(t0), address(t1), 1e12, 60, 3000, 6, 1 << 96));
        handler = new ConcentratedHandler(book, t0, t1, market);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.addRange.selector;
        selectors[2] = handler.increase.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.collect.selector;
        selectors[5] = handler.post.selector;
        selectors[6] = handler.cancel.selector;
        selectors[7] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ConservationAndCustody() public view {
        (uint256 a0, uint256 a1, uint256 o0, uint256 o1) = book.reserves(market);
        assertEq(
            a0 + o0 + book.balanceOf(address(handler), address(t0)) + book.protocolFees(address(t0)),
            book.totalLiability(address(t0))
        );
        assertEq(
            a1 + o1 + book.balanceOf(address(handler), address(t1)) + book.protocolFees(address(t1)),
            book.totalLiability(address(t1))
        );
        assertEq(t0.balanceOf(address(book)), book.totalLiability(address(t0)));
        assertEq(t1.balanceOf(address(book)), book.totalLiability(address(t1)));
    }

    function invariant_ActiveLiquidityAndRedeemableAMMClaims() public view {
        (,, int24 tick, uint128 actual) = book.getMarket(market);
        uint256 expected;
        uint256 owed0;
        uint256 owed1;
        for (uint256 i; i < handler.positionCount(); ++i) {
            uint256 id = handler.positionIds(i);
            Book.Position memory p = book.getPosition(id);
            if (p.lower <= tick && tick < p.upper) expected += p.accounting.liquidity;
            (uint256 x, uint256 y, uint256 f0, uint256 f1) = book.positionValue(id);
            owed0 += x + f0;
            owed1 += y + f1;
        }
        assertEq(actual, expected);
        (uint256 reserve0, uint256 reserve1,,) = book.reserves(market);
        assertLe(owed0, reserve0);
        assertLe(owed1, reserve1);
    }

    /// @notice Claims, cancels, burns and withdraws after every invariant campaign.
    function afterInvariant() public {
        handler.exitAll();
        invariant_ConservationAndCustody();
        (,,, uint128 liquidity) = book.getMarket(market);
        assertEq(liquidity, 0);
    }
}
