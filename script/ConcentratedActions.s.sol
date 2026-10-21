// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ConcentratedRangeBook as Book } from "../src/ConcentratedRangeBook.sol";

/// @notice Creates a concentrated market from explicitly supplied immutable parameters.
contract CreateConcentratedMarket is Script {
    /// @notice Creates a market using explicitly configured token addresses, fees, grid and initial price.
    /// @return id Identifier of the newly created immutable market.
    function run() external returns (bytes32 id) {
        Book book = Book(vm.envAddress("RANGEBOOK"));
        uint256 spacing = vm.envUint("TICK_SPACING");
        uint256 fee = vm.envUint("FEE_PPM");
        uint256 divisor = vm.envUint("PROTOCOL_DIVISOR");
        uint256 lot = vm.envUint("ORDER_LOT");
        uint256 price = vm.envUint("INITIAL_SQRT_PRICE_X96");
        require(spacing <= 32_767 && fee <= 100_000 && divisor <= 10, "parameter overflow");
        require(lot <= type(uint128).max && price <= type(uint160).max, "amount overflow");
        Book.Config memory config = Book.Config(
            vm.envAddress("TOKEN0"),
            vm.envAddress("TOKEN1"),
            uint128(lot),
            int24(uint24(spacing)),
            uint24(fee),
            uint8(divisor),
            uint160(price)
        );
        vm.startBroadcast(vm.envAddress("OPERATOR"));
        id = book.createMarket(config);
        vm.stopBroadcast();
    }
}

/// @notice Funds and mints the full aligned market range with explicit input limits and deadline.
contract FundFullRange is Script {
    using SafeERC20 for IERC20;

    /// @notice Approves and deposits MAX_TOKEN0/MAX_TOKEN1, then mints LIQUIDITY before DEADLINE.
    /// @dev Broadcasts separate transactions; if mint fails, deposited balances remain withdrawable.
    /// @return positionId Nontransferable position owned by OPERATOR.
    function run() external returns (uint256 positionId) {
        Book book = Book(vm.envAddress("RANGEBOOK"));
        bytes32 id = vm.envBytes32("MARKET_ID");
        address operator = vm.envAddress("OPERATOR");
        (Book.Config memory config,,,) = book.getMarket(id);
        (int24 lower, int24 upper) = book.fullRange(id);
        uint256 liquidity = vm.envUint("LIQUIDITY");
        uint256 deadline = vm.envUint("DEADLINE");
        uint256 max0 = vm.envUint("MAX_TOKEN0");
        uint256 max1 = vm.envUint("MAX_TOKEN1");
        require(liquidity <= uint128(type(int128).max) && deadline <= type(uint64).max, "parameter overflow");
        vm.startBroadcast(operator);
        if (max0 != 0) {
            IERC20(config.token0).forceApprove(address(book), max0);
            book.deposit(config.token0, max0, operator);
        }
        if (max1 != 0) {
            IERC20(config.token1).forceApprove(address(book), max1);
            book.deposit(config.token1, max1, operator);
        }
        (positionId,,) = book.mint(id, lower, upper, uint128(liquidity), max0, max1, uint64(deadline));
        vm.stopBroadcast();
    }
}

/// @notice Executes a prefunded exact-input hybrid trade with explicit price/output/work limits.
contract TradeConcentrated is Script {
    /// @notice Executes the environment-configured trade from OPERATOR's existing internal balances.
    /// @return result Actual input, output, fees, source inputs and attempted work.
    function run() external returns (Book.TradeResult memory result) {
        Book book = Book(vm.envAddress("RANGEBOOK"));
        uint256 input = vm.envUint("MAX_INPUT");
        uint256 limit = vm.envUint("SQRT_PRICE_LIMIT_X96");
        uint256 steps = vm.envUint("MAX_STEPS");
        uint256 deadline = vm.envUint("DEADLINE");
        require(input <= type(uint128).max && limit <= type(uint160).max, "amount overflow");
        require(steps <= type(uint32).max && deadline <= type(uint64).max, "parameter overflow");
        Book.TradeRequest memory request = Book.TradeRequest(
            vm.envBytes32("MARKET_ID"),
            vm.envBool("ZERO_FOR_ONE"),
            uint128(input),
            uint160(limit),
            vm.envUint("MIN_OUTPUT"),
            uint32(steps),
            uint64(deadline),
            vm.envBool("FILL_OR_KILL")
        );
        vm.startBroadcast(vm.envAddress("OPERATOR"));
        result = book.trade(request);
        vm.stopBroadcast();
    }
}
