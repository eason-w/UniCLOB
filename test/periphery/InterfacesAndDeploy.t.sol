// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PeripheryBase, Book, Router, Manager } from "./Periphery.t.sol";
import { IConcentratedRangeBook as IBook } from "../../src/interfaces/IConcentratedRangeBook.sol";
import { IRangeBookRouter as IRouter } from "../../src/interfaces/IRangeBookRouter.sol";
import { IRangeBookPositionManager as IManager } from "../../src/interfaces/IRangeBookPositionManager.sol";
import { DeployPeriphery } from "../../script/DeployPeriphery.s.sol";
import { RangeBookQuoter } from "../../src/periphery/RangeBookQuoter.sol";
import { ConcentratedRangeBookLens } from "../../src/periphery/RangeBookLens.sol";

contract InterfacesAndDeployTest is PeripheryBase {
    function test_StandaloneInterfacesExecuteRealContracts() public {
        IBook ib = IBook(address(book));
        (IBook.Config memory c, uint160 price, int24 tick, uint128 liquidity) = ib.getMarket(market);
        assertEq(abi.encode(c), abi.encode(config()));
        assertEq(price, Q96);
        assertEq(tick, 0);
        assertEq(liquidity, L);
        IRouter.ExactInputSingleParams memory p =
            abi.decode(abi.encode(params(false, 1e18)), (IRouter.ExactInputSingleParams));
        vm.prank(taker);
        IRouter.TradeResult memory r = IRouter(address(router)).exactInputSingle(p);
        assertGt(r.output, 0);
        IManager.MintParams memory m = abi.decode(abi.encode(mintParams(-600, 600)), (IManager.MintParams));
        vm.prank(lp2);
        (uint256 id,,,) = IManager(address(manager)).mint(m);
        assertEq(IManager(address(manager)).ownerOf(id), lp2);
        assertEq(IManager(address(manager)).positions(id).owner, address(manager));
    }

    function _env() private {
        vm.setEnv("OPERATOR", vm.toString(lp));
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("RANGEBOOK", vm.toString(address(book)));
        vm.setEnv("WRAPPED_NATIVE", vm.toString(address(wrapped)));
    }

    function test_DeployScriptWiresAllDependenciesAndFitsRuntimeLimits() public {
        _env();
        DeployPeriphery deploy = new DeployPeriphery();
        (Router r, Manager m, RangeBookQuoter q, ConcentratedRangeBookLens l) = deploy.run();
        assertEq(address(r.core()), address(book));
        assertEq(address(m.core()), address(book));
        assertEq(address(q.core()), address(book));
        assertEq(address(l.core()), address(book));
        assertEq(r.wrappedNative(), address(wrapped));
        assertEq(m.wrappedNative(), address(wrapped));
        assertLe(address(book).code.length, 24_576);
        assertLe(address(r).code.length, 24_576);
        assertLe(address(m).code.length, 24_576);
        assertLe(address(q).code.length, 24_576);
        assertLe(address(l).code.length, 24_576);
    }

    function test_DeployScriptRejectsWrongChainAndOldCore() public {
        _env();
        DeployPeriphery deploy = new DeployPeriphery();
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert("wrong chain");
        deploy.run();
        _env();
        vm.setEnv("RANGEBOOK", vm.toString(address(token0)));
        vm.expectRevert("core lacks quote API");
        deploy.run();
        _env();
        vm.setEnv("OPERATOR", vm.toString(address(0)));
        vm.expectRevert("invalid deployment config");
        deploy.run();
    }
}
