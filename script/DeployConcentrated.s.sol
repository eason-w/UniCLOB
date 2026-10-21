// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { ConcentratedRangeBook } from "../src/ConcentratedRangeBook.sol";

/// @notice Deploys the endpoint-based replacement core. Supply OPERATOR and FEE_COLLECTOR.
contract DeployConcentrated is Script {
    /// @notice Deploys using OPERATOR and FEE_COLLECTOR after checking EXPECTED_CHAIN_ID.
    /// @dev Signing is supplied separately through Foundry; no private key is read from environment.
    /// @return book Newly deployed concentrated exchange.
    function run() external returns (ConcentratedRangeBook book) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
        address operator = vm.envAddress("OPERATOR");
        require(operator != address(0), "zero operator");
        address collector = vm.envAddress("FEE_COLLECTOR");
        require(collector != address(0), "zero collector");
        vm.startBroadcast(operator);
        book = new ConcentratedRangeBook(collector);
        vm.stopBroadcast();
    }
}
