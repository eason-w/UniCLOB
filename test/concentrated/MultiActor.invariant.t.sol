// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Book, TickMath, MockERC20 } from "./Base.sol";

/// @notice Interleaves three independent owners across two markets sharing the same custody assets.
/// @dev No permanent full-range seed: every LP can exit and swaps must handle gaps and empty books.
contract MultiActorHandler is Test {
    Book public book;
    MockERC20 public token0;
    MockERC20 public token1;
    address[3] public actors;
    bytes32[2] public markets;
    uint256[] public positions;
    uint256[] public orders;
    uint256[2] public donations;
    uint256 public successfulTrades;
    uint256 public noExecutionStops;
    uint64 private constant NEVER = type(uint64).max;

    constructor(Book b, MockERC20 t0, MockERC20 t1) {
        book = b;
        token0 = t0;
        token1 = t1;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];
        markets[0] = b.createMarket(Book.Config(address(t0), address(t1), 1e12, 60, 3000, 6, 1 << 96));
        markets[1] = b.createMarket(Book.Config(address(t0), address(t1), 1e12, 60, 500, 4, 1 << 96));
        for (uint256 i; i < actors.length; ++i) {
            t0.mint(actors[i], 2e30);
            t1.mint(actors[i], 2e30);
            vm.startPrank(actors[i]);
            t0.approve(address(b), type(uint256).max);
            t1.approve(address(b), type(uint256).max);
            b.deposit(address(t0), 1e30, actors[i]);
            b.deposit(address(t1), 1e30, actors[i]);
            vm.stopPrank();
        }
    }

    function add(uint8 actor, uint8 market, uint8 width, uint96 raw) external {
        if (positions.length >= 32) return;
        bytes32 id = markets[market % 2];
        (,, int24 tick,) = book.getMarket(id);
        int24 center = tick / 60 * 60;
        int24 distance = int24(uint24(bound(width, 1, 10))) * 60;
        bytes memory data = _action(
            actors[actor % 3],
            abi.encodeCall(
                Book.mint,
                (
                    id,
                    center - distance,
                    center + distance,
                    uint128(bound(raw, 1e12, 1e22)),
                    type(uint256).max,
                    type(uint256).max,
                    NEVER
                )
            ),
            actor & 4 != 0
        );
        (uint256 p,,) = abi.decode(data, (uint256, uint256, uint256));
        positions.push(p);
    }

    function remove(uint256 seed, uint96 raw) external {
        if (positions.length == 0) return;
        uint256 id = positions[seed % positions.length];
        Book.Position memory p = book.getPosition(id);
        if (p.accounting.liquidity == 0) return;
        // Explicitly generate full exits frequently, not only tiny partial removals.
        uint128 amount = seed & 1 == 0 ? p.accounting.liquidity : uint128(bound(raw, 1, p.accounting.liquidity));
        _action(p.owner, abi.encodeCall(Book.burn, (id, amount, uint256(0), uint256(0), NEVER)), seed & 4 != 0);
    }

    function increaseOrCollect(uint256 seed, uint96 raw, bool increase) external {
        if (positions.length == 0) return;
        uint256 id = positions[seed % positions.length];
        Book.Position memory p = book.getPosition(id);
        bytes memory action = increase
            ? abi.encodeCall(
                Book.increase, (id, uint128(bound(raw, 1, 1e21)), type(uint256).max, type(uint256).max, NEVER)
            )
            : abi.encodeCall(Book.collect, (id));
        _action(p.owner, action, seed & 4 != 0);
    }

    function swap(uint8 actor, uint8 market, bool down, uint96 raw, uint8 steps) external {
        Book.TradeRequest memory r = Book.TradeRequest(
            markets[market % 2],
            down,
            uint128(bound(raw, 1e8, 1e23)),
            TickMath.getSqrtPriceAtTick(down ? int24(-6000) : int24(6000)),
            0,
            uint32(bound(steps, 1, 32)),
            NEVER,
            false
        );
        bytes memory action;
        uint256 mode = actor / 3 % 3;
        if (mode == 0) {
            action = abi.encodeCall(Book.trade, (r));
        } else if (mode == 1) {
            action = abi.encodeCall(Book.swapWallet, (r, actors[actor % 3]));
        } else {
            bytes[] memory calls = new bytes[](1);
            calls[0] = abi.encodeCall(Book.trade, (r));
            action = abi.encodeCall(Book.executeWallet, (calls, actors[actor % 3]));
        }
        vm.prank(actors[actor % 3]);
        (bool success, bytes memory reason) = address(book).call(action);
        if (success) {
            ++successfulTrades;
        } else {
            assertEq(reason, abi.encodeWithSelector(Book.InvalidAmount.selector));
            ++noExecutionStops;
        }
    }

    function post(uint8 actor, uint8 market, bool ask, uint8 distance, uint64 raw) external {
        if (orders.length >= 96) return;
        bytes32 id = markets[market % 2];
        (, uint160 price,,) = book.getMarket(id);
        int24 center = TickMath.getTickAtSqrtPrice(price) / 60 * 60;
        int24 delta = int24(uint24(bound(distance, 1, 8))) * 60;
        int24 tick = ask ? center + delta : center - delta;
        if (tick <= -6000 || tick >= 6000) return;
        (bool found, int24 opposite) = book.bestOrder(id, !ask);
        if (found && (ask ? tick <= opposite : tick >= opposite)) return;
        bytes memory data = _action(
            actors[actor % 3],
            abi.encodeCall(Book.placeOrder, (id, ask, tick, uint128(bound(raw, 1, 1e8)), NEVER)),
            actor & 4 != 0
        );
        orders.push(abi.decode(data, (uint256)));
    }

    function cancelOrClaim(uint256 seed, uint64 raw, bool cancel) external {
        if (orders.length == 0) return;
        uint256 id = orders[seed % orders.length];
        (Book.Order memory o, uint128 remaining,) = book.getOrder(id);
        bytes memory action = cancel && remaining != 0
            ? abi.encodeCall(Book.cancelOrder, (id, uint128(bound(raw, 1, remaining))))
            : abi.encodeCall(Book.claimOrder, (id));
        _action(o.owner, action, seed & 4 != 0);
    }

    function replace(uint256 seed, uint64 raw) external {
        if (orders.length == 0) return;
        uint256 id = orders[seed % orders.length];
        (Book.Order memory o,,) = book.getOrder(id);
        (, uint160 price,,) = book.getMarket(o.marketId);
        int24 tick = TickMath.getTickAtSqrtPrice(price) / 60 * 60 + (o.ask ? int24(60) : -int24(60));
        if (tick <= -6000 || tick >= 6000) return;
        (bool found, int24 opposite) = book.bestOrder(o.marketId, !o.ask);
        if (found && (o.ask ? tick <= opposite : tick >= opposite)) return;
        _action(
            o.owner, abi.encodeCall(Book.replaceOrder, (id, tick, uint128(bound(raw, 1, 1e8)), NEVER)), seed & 4 != 0
        );
    }

    function cancelRemaining(uint256 seed) external {
        if (orders.length == 0) return;
        uint256 id = orders[seed % orders.length];
        (Book.Order memory o,,) = book.getOrder(id);
        _action(o.owner, abi.encodeCall(Book.cancelRemaining, (id)), seed & 4 != 0);
    }

    function updateOrders(uint256 seed, uint64 raw, bool reprice) external {
        if (orders.length == 0) return;
        uint256 id = orders[seed % orders.length];
        (Book.Order memory o, uint128 remaining,) = book.getOrder(id);
        int24 tick = o.tick;
        uint64 lots = uint64(bound(raw, 0, remaining));
        if (reprice) {
            (, uint160 price,,) = book.getMarket(o.marketId);
            tick = TickMath.getTickAtSqrtPrice(price) / 60 * 60 + (o.ask ? int24(120) : -int24(120));
            if (tick <= -6000 || tick >= 6000) return;
            (bool found, int24 opposite) = book.bestOrder(o.marketId, !o.ask);
            if (found && (o.ask ? tick <= opposite : tick >= opposite)) return;
            lots = uint64(bound(raw, 1, 1e8));
        }
        if (lots == 0) tick = 0;
        _action(
            o.owner,
            abi.encodeCall(Book.updateOrders, (o.marketId, abi.encodePacked(id, tick, lots), NEVER)),
            seed & 4 != 0
        );
    }

    function _action(address owner, bytes memory action, bool wallet) private returns (bytes memory result) {
        vm.prank(owner);
        if (wallet) {
            bytes[] memory calls = new bytes[](1);
            calls[0] = action;
            return book.executeWallet(calls, owner)[0];
        }
        bool success;
        (success, result) = address(book).call(action);
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function custody(uint8 actor, bool side, bool withdraw, uint64 raw) external {
        MockERC20 asset = side ? token1 : token0;
        address owner = actors[actor % 3];
        uint256 amount = bound(raw, 1, 1e18);
        vm.prank(owner);
        if (withdraw) book.withdraw(address(asset), amount, owner);
        else book.deposit(address(asset), amount, owner);
    }

    function donate(bool side, uint32 raw) external {
        uint256 amount = bound(raw, 1, 1000);
        (side ? token1 : token0).mint(address(book), amount);
        donations[side ? 1 : 0] += amount;
    }

    function protocol(bool side) external {
        address asset = address(side ? token1 : token0);
        uint256 amount = book.protocolFees(asset);
        if (amount == 0) return;
        address collector = book.feeCollector();
        vm.prank(collector);
        book.collectProtocol(asset, amount, collector);
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    function exitAll() external {
        for (uint256 i; i < orders.length; ++i) {
            (Book.Order memory o, uint128 remaining,) = book.getOrder(orders[i]);
            vm.startPrank(o.owner);
            if (remaining != 0) book.cancelOrder(orders[i], remaining);
            book.claimOrder(orders[i]);
            vm.stopPrank();
        }
        for (uint256 i; i < positions.length; ++i) {
            Book.Position memory p = book.getPosition(positions[i]);
            vm.prank(p.owner);
            if (p.accounting.liquidity != 0) book.burn(positions[i], p.accounting.liquidity, 0, 0, NEVER);
            else book.collect(positions[i]);
        }
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            book.withdraw(address(token0), book.balanceOf(actors[i], address(token0)), actors[i]);
            book.withdraw(address(token1), book.balanceOf(actors[i], address(token1)), actors[i]);
            vm.stopPrank();
        }
    }
}

contract MultiActorInvariantTest is StdInvariant, Test {
    Book private book;
    MockERC20 private t0;
    MockERC20 private t1;
    MultiActorHandler private handler;

    function setUp() public {
        book = new Book(address(this));
        t0 = new MockERC20("Asset0", "A0", 18);
        t1 = new MockERC20("Asset1", "A1", 6);
        handler = new MultiActorHandler(book, t0, t1);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.add.selector;
        selectors[1] = handler.remove.selector;
        selectors[2] = handler.increaseOrCollect.selector;
        selectors[3] = handler.swap.selector;
        selectors[4] = handler.post.selector;
        selectors[5] = handler.cancelOrClaim.selector;
        selectors[6] = handler.custody.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.protocol.selector;
        selectors[9] = handler.replace.selector;
        selectors[10] = handler.cancelRemaining.selector;
        selectors[11] = handler.updateOrders.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @notice No market or actor can spend custody allocated to another obligation.
    function invariant_SharedCustodyAndAllRedeemableClaims() public view {
        uint256 allocated0 = book.protocolFees(address(t0));
        uint256 allocated1 = book.protocolFees(address(t1));
        for (uint256 i; i < 3; ++i) {
            allocated0 += book.balanceOf(handler.actors(i), address(t0));
            allocated1 += book.balanceOf(handler.actors(i), address(t1));
        }
        for (uint256 m; m < 2; ++m) {
            bytes32 market = handler.markets(m);
            (uint256 a0, uint256 a1, uint256 o0, uint256 o1) = book.reserves(market);
            allocated0 += a0 + o0;
            allocated1 += a1 + o1;
            _claims(market, a0, a1, o0, o1);
        }
        assertEq(allocated0, book.totalLiability(address(t0)));
        assertEq(allocated1, book.totalLiability(address(t1)));
        assertEq(t0.balanceOf(address(book)), allocated0 + handler.donations(0));
        assertEq(t1.balanceOf(address(book)), allocated1 + handler.donations(1));
    }

    function _claims(bytes32 market, uint256 a0, uint256 a1, uint256 o0, uint256 o1) private view {
        (,, int24 tick, uint128 active) = book.getMarket(market);
        uint256 expected;
        uint256 owed0;
        uint256 owed1;
        for (uint256 i; i < handler.positionCount(); ++i) {
            uint256 id = handler.positions(i);
            Book.Position memory p = book.getPosition(id);
            if (p.marketId != market) continue;
            if (p.lower <= tick && tick < p.upper) expected += p.accounting.liquidity;
            (uint256 x, uint256 y, uint256 f0, uint256 f1) = book.positionValue(id);
            owed0 += x + f0;
            owed1 += y + f1;
        }
        assertEq(expected, active);
        assertLe(owed0, a0);
        assertLe(owed1, a1);
        owed0 = 0;
        owed1 = 0;
        for (uint256 i; i < handler.orderCount(); ++i) {
            (Book.Order memory o, uint128 remaining, uint128 claimable) = book.getOrder(handler.orders(i));
            if (o.marketId != market) continue;
            uint256 rate = uint256(TickMath.getSqrtPriceAtTick(o.tick)) ** 2;
            if (o.ask) {
                owed0 += uint256(remaining) * 1e12;
                owed1 += Math.mulDiv(uint256(o.claimed + claimable) * 1e12, rate, 1 << 192)
                - Math.mulDiv(uint256(o.claimed) * 1e12, rate, 1 << 192);
            } else {
                owed0 += uint256(claimable) * 1e12;
                owed1 += Math.mulDiv(uint256(o.cancelled + remaining) * 1e12, rate, 1 << 192)
                - Math.mulDiv(uint256(o.cancelled) * 1e12, rate, 1 << 192);
            }
        }
        assertLe(owed0, o0);
        assertLe(owed1, o1);
    }

    /// @notice Every campaign must allow all three owners to exit both markets completely.
    function afterInvariant() public {
        handler.exitAll();
        invariant_SharedCustodyAndAllRedeemableClaims();
        for (uint256 i; i < 2; ++i) {
            (,,, uint128 active) = book.getMarket(handler.markets(i));
            assertEq(active, 0);
            (bool ask,) = book.bestOrder(handler.markets(i), true);
            (bool bid,) = book.bestOrder(handler.markets(i), false);
            assertFalse(ask || bid);
        }
    }
}
