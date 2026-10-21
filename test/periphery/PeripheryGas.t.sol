// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PeripheryBase, Book, Router, Manager, MockERC20 } from "./Periphery.t.sol";
import { ConcentratedLiquidity } from "../../src/libraries/ConcentratedLiquidity.sol";
import { OrderBookAccounting } from "../../src/libraries/OrderBookAccounting.sol";
import { WalletSettlement } from "../../src/libraries/WalletSettlement.sol";

/// @notice Cold callee snapshots against committed fixtures; includes wrapper execution, not intrinsic gas/refunds.
contract PeripheryGasTest is PeripheryBase {
    uint256 internal positionId;
    uint128 internal liquidity;
    uint256 internal emptyId;
    Router internal freshRouter;
    bytes32 internal second;
    MockERC20 internal third;

    function setUp() public override {
        super.setUp();
        (positionId, liquidity) = nft();
        uint128 emptyLiquidity;
        (emptyId, emptyLiquidity) = _empty();
        vm.prank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(emptyId, emptyLiquidity, 0, 0, lp2, NEVER, false));
        vm.prank(taker);
        router.exactInputSingle(params(false, 1e18));
        freshRouter = new Router(book, address(wrapped));
        vm.prank(taker);
        token1.approve(address(freshRouter), type(uint256).max);
        third = new MockERC20("Third", "C", 18);
        second = book.createMarket(Book.Config(address(token0), address(third), LOT, 10, 500, 4, Q96));
        third.mint(lp, 1e30);
        vm.startPrank(lp);
        third.approve(address(book), type(uint256).max);
        book.deposit(address(third), 1e30, lp);
        book.mint(second, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
        vm.stopPrank();
        for (int24 tick = 10; tick <= 160; tick += 10) {
            order(true, tick, 100);
        }
    }

    function _empty() private returns (uint256 id, uint128 amount) {
        vm.prank(lp2);
        (id, amount,,) = manager.mint(mintParams(-1000, 1000));
    }

    function _cool() private {
        vm.cool(address(book));
        vm.cool(address(router));
        vm.cool(address(freshRouter));
        vm.cool(address(manager));
        vm.cool(address(quoter));
        vm.cool(address(lens));
        vm.cool(address(ConcentratedLiquidity));
        vm.cool(address(OrderBookAccounting));
        vm.cool(address(WalletSettlement));
        vm.cool(address(token0));
        vm.cool(address(token1));
        vm.cool(address(third));
    }

    function test_Gas_RouterSingleEstablished() public {
        _cool();
        vm.prank(taker);
        router.exactInputSingle(params(false, 1e18));
        vm.snapshotGasLastCall("Periphery", "router_single_established");
    }

    function test_Gas_RouterSingleFirstApproval() public {
        _cool();
        vm.prank(taker);
        freshRouter.exactInputSingle(params(false, 1e18));
        vm.snapshotGasLastCall("Periphery", "router_single_first_core_approval");
    }

    function test_Gas_RouterTwoHops() public {
        Router.Hop[] memory path = new Router.Hop[](2);
        path[0] = Router.Hop(market, address(token0), 0, 128);
        path[1] = Router.Hop(second, address(third), 0, 128);
        Router.ExactInputParams memory p = Router.ExactInputParams(address(token1), path, taker, 1e18, 0, NEVER, false);
        _cool();
        vm.prank(taker);
        router.exactInput(p);
        vm.snapshotGasLastCall("Periphery", "router_two_hops");
    }

    function test_Gas_ManagerMintNewEndpoints() public {
        Manager.MintParams memory p = mintParams(-6000, 6000);
        _cool();
        vm.prank(lp2);
        manager.mint(p);
        vm.snapshotGasLastCall("Periphery", "nft_mint_new_endpoints");
    }

    function test_Gas_ManagerMintFullExistingEndpoints() public {
        Manager.MintParams memory p = mintParams(-887_270, 887_270);
        _cool();
        vm.prank(lp2);
        manager.mint(p);
        vm.snapshotGasLastCall("Periphery", "nft_mint_full_existing_endpoints");
    }

    function test_Gas_ManagerIncreaseWithFees() public {
        _cool();
        vm.prank(lp2);
        manager.increaseLiquidity(Manager.IncreaseLiquidityParams(positionId, 1e20, 1e20, 0, 0, NEVER));
        vm.snapshotGasLastCall("Periphery", "nft_increase_with_fees");
    }

    function test_Gas_ManagerExitWithFees() public {
        _cool();
        vm.prank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(positionId, liquidity, 0, 0, lp2, NEVER, false));
        vm.snapshotGasLastCall("Periphery", "nft_exit_with_fees");
    }

    function test_Gas_ManagerCollect() public {
        _cool();
        vm.prank(lp2);
        manager.collect(positionId, lp2, false);
        vm.snapshotGasLastCall("Periphery", "nft_collect");
    }

    function test_Gas_ManagerTransfer() public {
        _cool();
        vm.prank(lp2);
        manager.transferFrom(lp2, taker, positionId);
        vm.snapshotGasLastCall("Periphery", "nft_transfer");
    }

    function test_Gas_ManagerBurnEmpty() public {
        _cool();
        vm.prank(lp2);
        manager.burn(emptyId);
        vm.snapshotGasLastCall("Periphery", "nft_burn_empty");
    }

    function test_Gas_Quoter() public {
        _cool();
        quoter.quoteExactInputSingle(params(false, 1e18));
        vm.snapshotGasLastCall("Periphery", "quote_single");
    }

    function test_Gas_Depth16() public {
        _cool();
        lens.orderDepth(market, true, -887_272, 16);
        vm.snapshotGasLastCall("Periphery", "depth_16");
    }
}
