// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { ConcentratedRangeBook as Book } from "../src/ConcentratedRangeBook.sol";
import { TickMath } from "../src/vendor/uniswap/TickMath.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";

/// @notice Local-only full-range LP, hybrid trade, fee claim and complete withdrawal demonstration.
/// @dev Uses Anvil's public development account. Never run with real assets.
contract ConcentratedDemo is Script {
    /// @notice Runs the complete concentrated lifecycle on chain 31337 only.
    /// @return book Local demonstration exchange.
    /// @return market Demonstration market identifier.
    /// @return positionId Fully exited demonstration position.
    function run() external returns (Book book, bytes32 market, uint256 positionId) {
        require(block.chainid == 31_337, "local chain only");
        uint256 key = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address owner = vm.addr(key);
        vm.startBroadcast(key);
        book = new Book(owner);
        MockERC20 t0 = new MockERC20("Demo0", "D0", 18);
        MockERC20 t1 = new MockERC20("Demo1", "D1", 18);
        t0.mint(owner, 1e28);
        t1.mint(owner, 1e28);
        t0.approve(address(book), 1e28);
        t1.approve(address(book), 1e28);
        book.deposit(address(t0), 1e28, owner);
        book.deposit(address(t1), 1e28, owner);
        market = book.createMarket(Book.Config(address(t0), address(t1), 1e12, 60, 3000, 6, 1 << 96));
        (int24 lower, int24 upper) = book.fullRange(market);
        (positionId,,) = book.mint(market, lower, upper, 1e24, 1e25, 1e25, type(uint64).max);
        uint256 orderId = book.placeOrder(market, true, 60, 1000, type(uint64).max);
        Book.TradeResult memory result = book.trade(
            Book.TradeRequest(market, false, 1e22, TickMath.getSqrtPriceAtTick(120), 1, 32, type(uint64).max, false)
        );
        require(result.ammInput != 0 && result.orderInput != 0, "hybrid execution");
        book.claimOrder(orderId);
        book.collect(positionId);
        book.burn(positionId, 1e24, 0, 0, type(uint64).max);
        book.collectProtocol(address(t1), book.protocolFees(address(t1)), owner);
        book.withdraw(address(t0), book.balanceOf(owner, address(t0)), owner);
        book.withdraw(address(t1), book.balanceOf(owner, address(t1)), owner);
        vm.stopBroadcast();
    }
}
