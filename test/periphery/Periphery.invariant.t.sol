// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { ConcentratedBase, Book, MockERC20 } from "../concentrated/Base.sol";
import { RangeBookRouter as Router } from "../../src/periphery/RangeBookRouter.sol";
import { RangeBookPositionManager as Manager } from "../../src/periphery/RangeBookPositionManager.sol";

contract PeripheryHandler is Test {
    Book public book;
    Manager public manager;
    Router public router;
    MockERC20 public token0;
    MockERC20 public token1;
    bytes32 public market;
    address[3] public actors;
    uint256[] public ids;

    constructor(Book b, Manager m, Router r, MockERC20 t0, MockERC20 t1, bytes32 id, address[3] memory users) {
        book = b;
        manager = m;
        router = r;
        token0 = t0;
        token1 = t1;
        market = id;
        actors = users;
    }

    function mint(uint8 actor, uint96 raw, bool wide) external {
        if (ids.length >= 16) return;
        uint256 amount = bound(raw, 1e12, 1e21);
        address owner = actors[actor % 3];
        vm.prank(owner);
        (uint256 id,,,) = manager.mint(
            Manager.MintParams(
                market,
                wide ? int24(-887_270) : int24(-600),
                wide ? int24(887_270) : int24(600),
                amount,
                amount,
                0,
                0,
                owner,
                type(uint64).max
            )
        );
        ids.push(id);
    }

    function transfer(uint256 seed, uint8 to) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address owner = manager.ownerOf(id);
        vm.prank(owner);
        manager.transferFrom(owner, actors[to % 3], id);
    }

    function increase(uint256 seed, uint96 raw) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        uint256 amount = bound(raw, 1e12, 1e21);
        vm.prank(manager.ownerOf(id));
        manager.increaseLiquidity(Manager.IncreaseLiquidityParams(id, amount, amount, 0, 0, type(uint64).max));
    }

    function decrease(uint256 seed, uint96 raw) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        uint128 liquidity = book.getPosition(id).accounting.liquidity;
        if (liquidity == 0) return;
        address owner = manager.ownerOf(id);
        vm.prank(owner);
        manager.decreaseLiquidity(
            Manager.DecreaseLiquidityParams(id, uint128(bound(raw, 1, liquidity)), 0, 0, owner, type(uint64).max, false)
        );
    }

    function collect(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address owner = manager.ownerOf(id);
        vm.prank(owner);
        manager.collect(id, owner, false);
    }

    function swap(uint8 actor, bool down, uint96 raw) external {
        address owner = actors[actor % 3];
        vm.prank(owner);
        router.exactInputSingle(
            Router.ExactInputSingleParams(
                market,
                down ? address(token0) : address(token1),
                owner,
                uint128(bound(raw, 1e14, 1e20)),
                0,
                0,
                128,
                type(uint64).max,
                true,
                false
            )
        );
    }

    function exitAll() external {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            address owner = manager.ownerOf(id);
            uint128 liquidity = book.getPosition(id).accounting.liquidity;
            vm.startPrank(owner);
            if (liquidity != 0) {
                manager.decreaseLiquidity(
                    Manager.DecreaseLiquidityParams(id, liquidity, 0, 0, owner, type(uint64).max, false)
                );
            }
            manager.burn(id);
            vm.stopPrank();
        }
    }
}

contract PeripheryInvariantTest is StdInvariant, ConcentratedBase {
    Manager internal manager;
    Router internal router;
    PeripheryHandler internal handler;

    function config() internal view override returns (Book.Config memory) {
        return Book.Config(address(token0), address(token1), LOT, 10, 500, 4, Q96);
    }

    function setUp() public override {
        super.setUp();
        full(lp, L);
        manager = new Manager(book, address(0));
        router = new Router(book, address(0));
        address[3] memory actors = [lp2, taker, maker];
        for (uint256 i; i < 3; ++i) {
            token0.mint(actors[i], 1e35);
            token1.mint(actors[i], 1e35);
            vm.startPrank(actors[i]);
            token0.approve(address(manager), type(uint256).max);
            token1.approve(address(manager), type(uint256).max);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        token0.mint(address(manager), 11);
        token1.mint(address(manager), 13);
        token0.mint(address(router), 17);
        token1.mint(address(router), 19);
        handler = new PeripheryHandler(book, manager, router, token0, token1, market, actors);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.increase.selector;
        selectors[3] = handler.decrease.selector;
        selectors[4] = handler.collect.selector;
        selectors[5] = handler.swap.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_OnlyDonationsRemainAndCoreLiabilitiesReconcile() public view {
        assertEq(token0.balanceOf(address(manager)), 11);
        assertEq(token1.balanceOf(address(manager)), 13);
        assertEq(token0.balanceOf(address(router)), 17);
        assertEq(token1.balanceOf(address(router)), 19);
        assertEq(
            book.balanceOf(address(manager), address(token0)) + book.balanceOf(address(manager), address(token1)), 0
        );
        assertEq(book.balanceOf(address(router), address(token0)) + book.balanceOf(address(router), address(token1)), 0);
        assertAccounting();
    }

    function afterInvariant() public {
        handler.exitAll();
        invariant_OnlyDonationsRemainAndCoreLiabilitiesReconcile();
    }
}
