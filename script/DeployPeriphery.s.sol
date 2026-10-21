// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { ConcentratedRangeBook as Book } from "../src/ConcentratedRangeBook.sol";
import { RangeBookRouter } from "../src/periphery/RangeBookRouter.sol";
import { RangeBookPositionManager } from "../src/periphery/RangeBookPositionManager.sol";
import { RangeBookQuoter } from "../src/periphery/RangeBookQuoter.sol";
import { ConcentratedRangeBookLens } from "../src/periphery/RangeBookLens.sol";

/// @notice Deploys immutable integration contracts against an explicitly selected, already deployed core.
contract DeployPeriphery is Script {
    /// @notice Deploys using OPERATOR, EXPECTED_CHAIN_ID, RANGEBOOK and WRAPPED_NATIVE (zero disables native support).
    /// @return router Exact-input wallet router.
    /// @return positions ERC-721 LP manager.
    /// @return quoter Revert-based production matcher quoter.
    /// @return lens Bounded integration reads.
    function run()
        external
        returns (
            RangeBookRouter router,
            RangeBookPositionManager positions,
            RangeBookQuoter quoter,
            ConcentratedRangeBookLens lens
        )
    {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
        address operator = vm.envAddress("OPERATOR");
        Book book = Book(vm.envAddress("RANGEBOOK"));
        address wrapped = vm.envAddress("WRAPPED_NATIVE");
        require(operator != address(0) && address(book).code.length != 0, "invalid deployment config");
        require(wrapped == address(0) || wrapped.code.length != 0, "invalid wrapped asset");
        // Old cores without quoteTrade must not be silently paired with this periphery.
        (bool ok, bytes memory data) = address(book)
            .call(
                abi.encodeCall(
                    Book.quoteTrade, (Book.TradeRequest(bytes32(0), false, 1, 1, 0, 1, type(uint64).max, false))
                )
            );
        require(!ok && data.length == 4 && bytes4(data) == Book.UnknownMarket.selector, "core lacks quote API");
        vm.startBroadcast(operator);
        router = new RangeBookRouter(book, wrapped);
        positions = new RangeBookPositionManager(book, wrapped);
        quoter = new RangeBookQuoter(book);
        lens = new ConcentratedRangeBookLens(book);
        vm.stopBroadcast();
    }
}
