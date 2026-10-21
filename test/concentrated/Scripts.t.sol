// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ConcentratedDemo } from "../../script/ConcentratedDemo.s.sol";
import { ConcentratedRangeBook as Book } from "../../src/ConcentratedRangeBook.sol";

contract ConcentratedScriptsTest is Test {
    function test_ConcentratedLocalDemoExitsAndRefusesLiveChain() public {
        vm.chainId(31_337);
        (Book book, bytes32 market, uint256 id) = new ConcentratedDemo().run();
        assertEq(book.getPosition(id).accounting.liquidity, 0);
        (,,, uint128 active) = book.getMarket(market);
        assertEq(active, 0);
        vm.chainId(1);
        ConcentratedDemo demo = new ConcentratedDemo();
        vm.expectRevert("local chain only");
        demo.run();
    }
}
