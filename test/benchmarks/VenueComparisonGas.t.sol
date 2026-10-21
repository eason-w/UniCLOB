// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { OrderBookAccounting as Orders } from "../../src/libraries/OrderBookAccounting.sol";

import { ConcentratedLiquidity as CL } from "../../src/libraries/ConcentratedLiquidity.sol";
import { WalletSettlement as Wallet } from "../../src/libraries/WalletSettlement.sol";
import { Test } from "forge-std/Test.sol";
import { ConcentratedRangeBook as Book } from "../../src/ConcentratedRangeBook.sol";
import { TickMath } from "../../src/vendor/uniswap/TickMath.sol";
import { SqrtPriceMath } from "../../src/vendor/uniswap/SqrtPriceMath.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IV3Factory, IV3Pool, IV4Manager, V3BenchmarkAdapter, V4BenchmarkAdapter } from "./UniswapAdapters.sol";

/// @notice Real-artifact comparisons with common liquidity, tokens, gross fee and operation sizes.
/// @dev Committed fixtures; every measured venue and token is cooled. No NFT managers or gas refunds.
abstract contract VenueComparisonGasBase is Test {
    struct Fixture {
        MockERC20 token0;
        MockERC20 token1;
        Book funded;
        Book walletBook;
        bytes32 market;
        V3BenchmarkAdapter v3;
        V4BenchmarkAdapter v4Wallet;
        V4BenchmarkAdapter v4Claims;
    }

    Fixture[6] internal fixtures;
    IV3Factory internal factory;
    IV4Manager internal managerWallet;
    IV4Manager internal managerClaims;
    address internal owner = makeAddr("venue-benchmark-owner");
    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant L = 1e24;
    uint64 internal constant NEVER = type(uint64).max;
    int24 internal constant LOW = -887_270;
    int24 internal constant HIGH = 887_270;
    string internal constant ARTIFACTS = "test/reference/benchmark-artifacts/";

    function setUp() public {
        factory = IV3Factory(_deploy(string.concat(ARTIFACTS, "UniswapV3Factory.json"), ""));
        managerWallet = IV4Manager(_deploy(string.concat(ARTIFACTS, "PoolManager.json"), abi.encode(address(this))));
        managerClaims = IV4Manager(_deploy(string.concat(ARTIFACTS, "PoolManager.json"), abi.encode(address(this))));
        managerWallet.setProtocolFeeController(address(this));
        managerClaims.setProtocolFeeController(address(this));
        for (uint256 i; i < fixtures.length; ++i) {
            Fixture storage f = fixtures[i];
            MockERC20 a = new MockERC20("A", "A", 18);
            MockERC20 b = new MockERC20("B", "B", 18);
            (f.token0, f.token1) = address(a) < address(b) ? (a, b) : (b, a);
            f.token0.mint(owner, 1e35);
            f.token1.mint(owner, 1e35);
            f.funded = new Book(address(this));
            f.walletBook = new Book(address(this));
            Book.Config memory c = Book.Config(address(f.token0), address(f.token1), 1e12, 10, 500, 4, Q96);
            f.market = f.funded.createMarket(c);
            assertEq(f.walletBook.createMarket(c), f.market);
            IV3Pool pool = IV3Pool(factory.createPool(address(f.token0), address(f.token1), 500));
            pool.initialize(Q96);
            pool.setFeeProtocol(4, 4);
            f.v3 = new V3BenchmarkAdapter(pool, address(f.token0), address(f.token1), owner);
            f.v4Wallet = new V4BenchmarkAdapter(managerWallet, address(f.token0), address(f.token1), owner, false);
            f.v4Claims = new V4BenchmarkAdapter(managerClaims, address(f.token0), address(f.token1), owner, true);
            managerWallet.initialize(f.v4Wallet.key(), Q96);
            managerClaims.initialize(f.v4Claims.key(), Q96);
            managerWallet.setProtocolFee(f.v4Wallet.key(), uint24(125 | (125 << 12)));
            managerClaims.setProtocolFee(f.v4Claims.key(), uint24(125 | (125 << 12)));
            vm.startPrank(owner);
            _approve(f.token0, f);
            _approve(f.token1, f);
            f.funded.deposit(address(f.token0), 1e30, owner);
            f.funded.deposit(address(f.token1), 1e30, owner);
            managerClaims.setOperator(address(f.v4Claims), true);
            f.v4Claims.fundClaims(1e30);
            vm.stopPrank();
            if (i != 0) _mintAll(i, LOW, HIGH, false);
            if (i >= 2) _swapAll(i, false, 1e18, "", false);
            if (i == 4) _swapAll(i, true, 1e18, "", false);
            if (i == 3 || i == 4) {
                for (int24 tick = 60; tick <= 960; tick += 60) {
                    _mintAll(i, tick, tick + 60, false);
                }
            }
        }
        // A subsequent-block v3 swap must maintain its oracle, rather than reusing setup's timestamp.
        vm.warp(block.timestamp + 12);
    }

    function test_Gas_ComparisonMintNarrow() public {
        _mintAll(0, -60, 60, true);
    }

    function test_Gas_ComparisonMintWideCustom() public {
        _mintAll(0, -600_000, 420_000, true);
    }

    function test_Gas_ComparisonMintFull() public {
        _mintAll(0, LOW, HIGH, true);
    }

    function test_Gas_ComparisonMintWideOutOfRange() public {
        _mintAll(0, 600, 600_000, true);
    }

    function test_Gas_ComparisonIncreaseFull() public {
        _increaseAll(1);
    }

    function test_Gas_ComparisonCollectFull() public {
        _exitAll(2, 0, "collect_full");
    }

    function test_Gas_ComparisonBurnFull() public {
        _exitAll(2, L, "burn_full");
    }

    function test_Gas_ComparisonSwapFirst() public {
        _swapAll(1, false, 1e18, "swap_first", true);
    }

    function test_Gas_ComparisonSwapEstablished() public {
        _swapAll(2, false, 1e18, "swap_established", true);
    }

    function test_Gas_ComparisonSwapReverseFirst() public {
        _swapAll(2, true, 1e18, "swap_first_reverse", true);
    }

    function test_Gas_ComparisonSwapLargeMove() public {
        _swapAll(2, false, 1e25, "swap_large_move", true);
    }

    function test_Gas_ComparisonCrossRanges() public {
        _swapAll(3, false, 2e23, "swap_adjacent_ranges", true);
    }

    function test_Gas_ComparisonCrossRangesBothHistories() public {
        _swapAll(4, false, 2e23, "swap_adjacent_ranges_both_histories", true);
    }

    function test_Gas_ComparisonRebalanceFullToNarrow() public {
        Fixture storage f = fixtures[1];
        uint256 old0;
        uint256 old1;
        if (_venue() >= 2) (old0, old1,,) = f.walletBook.positionValue(1);
        (uint256 next0, uint256 next1) = _principal(Q96, -600, 600, L);
        uint256 net0 = _venue() >= 2 ? old0 - next0 : 0;
        uint256 net1 = _venue() >= 2 ? old1 - next1 : 0;
        bytes[] memory actions = new bytes[](2);
        actions[0] = abi.encodeCall(Book.burn, (uint256(1), L, uint256(0), uint256(0), NEVER));
        actions[1] = abi.encodeCall(Book.mint, (f.market, int24(-600), int24(600), L, next0, next1, NEVER));
        if (_venue() == 0) {
            _cool(f, address(f.funded));
            vm.prank(owner);
            f.funded.multicall(actions);
            vm.snapshotGasLastCall("VenueHybridFunded", "rebalance_full_to_narrow");
            assertEq(f.funded.getPosition(1).accounting.liquidity, 0);
            assertEq(f.funded.getPosition(2).accounting.liquidity, L);
        } else if (_venue() == 1) {
            bytes[] memory calls = actions;
            _cool(f, address(f.walletBook));
            vm.prank(owner);
            f.walletBook.executeWallet(calls, owner);
            vm.snapshotGasLastCall("VenueHybridWallet", "rebalance_full_to_narrow");
            assertEq(f.walletBook.balanceOf(owner, address(f.token0)), 0);
            assertEq(f.walletBook.balanceOf(owner, address(f.token1)), 0);
        } else if (_venue() == 2) {
            _cool(f, address(f.v3));
            vm.prank(owner);
            (uint256 a, uint256 b) = f.v3.rebalance(LOW, HIGH, -600, 600, L);
            vm.snapshotGasLastCall("VenueV3Wallet", "rebalance_full_to_narrow");
            assertEq(a, net0);
            assertEq(b, net1);
        } else if (_venue() == 3) {
            _cool(f, address(f.v4Wallet));
            vm.prank(owner);
            (int128 a, int128 b) = f.v4Wallet.rebalance(LOW, HIGH, -600, 600, L);
            vm.snapshotGasLastCall("VenueV4Wallet", "rebalance_full_to_narrow");
            assertEq(uint128(a), net0);
            assertEq(uint128(b), net1);
        } else {
            _cool(f, address(f.v4Claims));
            vm.prank(owner);
            (int128 a, int128 b) = f.v4Claims.rebalance(LOW, HIGH, -600, 600, L);
            vm.snapshotGasLastCall("VenueV4Claims", "rebalance_full_to_narrow");
            assertEq(uint128(a), net0);
            assertEq(uint128(b), net1);
        }
    }

    function _mintAll(uint256 index, int24 low, int24 high, bool measure) private {
        Fixture storage f = fixtures[index];
        string memory label = low == LOW
            ? "mint_full"
            : low == -60 ? "mint_narrow" : low == -600_000 ? "mint_wide_custom" : "mint_wide_out_of_range";
        (, uint160 price,,) = f.funded.getMarket(f.market);
        (uint256 a, uint256 b) = _principal(price, low, high, L);
        uint256 x;
        uint256 y;
        if (!measure || _venue() == 0) {
            if (measure) _cool(f, address(f.funded));
            vm.prank(owner);
            (, x, y) = f.funded.mint(f.market, low, high, L, a, b, NEVER);
            if (measure) vm.snapshotGasLastCall("VenueHybridFunded", label);
            assertEq(x, a);
            assertEq(y, b);
        }
        if (!measure || _venue() == 1) {
            bytes[] memory calls = new bytes[](1);
            calls[calls.length - 1] = abi.encodeCall(Book.mint, (f.market, low, high, L, a, b, NEVER));
            if (measure) _cool(f, address(f.walletBook));
            vm.prank(owner);
            f.walletBook.executeWallet(calls, owner);
            if (measure && _venue() == 1) vm.snapshotGasLastCall("VenueHybridWallet", label);
        }
        if (!measure || _venue() == 2) {
            if (measure) _cool(f, address(f.v3));
            vm.prank(owner);
            (x, y) = f.v3.mint(low, high, L);
            if (measure && _venue() == 2) vm.snapshotGasLastCall("VenueV3Wallet", label);
            assertApproxEqAbs(x, a, 1000);
            assertApproxEqAbs(y, b, 1000);
        }
        if (!measure || _venue() == 3) {
            if (measure) _cool(f, address(f.v4Wallet));
            vm.prank(owner);
            (int128 d0, int128 d1) = f.v4Wallet.modify(low, high, int128(L));
            if (measure && _venue() == 3) vm.snapshotGasLastCall("VenueV4Wallet", label);
            assertApproxEqAbs(uint128(-d0), a, 1000);
            assertApproxEqAbs(uint128(-d1), b, 1000);
        }
        if (!measure || _venue() == 4) {
            if (measure) _cool(f, address(f.v4Claims));
            vm.prank(owner);
            (int128 d0, int128 d1) = f.v4Claims.modify(low, high, int128(L));
            if (measure && _venue() == 4) vm.snapshotGasLastCall("VenueV4Claims", label);
            assertApproxEqAbs(uint128(-d0), a, 1000);
            assertApproxEqAbs(uint128(-d1), b, 1000);
        }
    }

    function _increaseAll(uint256 index) private {
        Fixture storage f = fixtures[index];
        (uint256 a, uint256 b) = _principal(Q96, LOW, HIGH, L);
        if (_venue() == 0) {
            _cool(f, address(f.funded));
            vm.prank(owner);
            f.funded.increase(1, L, a, b, NEVER);
            vm.snapshotGasLastCall("VenueHybridFunded", "increase_full");
        }
        if (_venue() == 1) {
            bytes[] memory calls = new bytes[](1);
            calls[calls.length - 1] = abi.encodeCall(Book.increase, (uint256(1), L, a, b, NEVER));
            _cool(f, address(f.walletBook));
            vm.prank(owner);
            f.walletBook.executeWallet(calls, owner);
            if (_venue() == 1) vm.snapshotGasLastCall("VenueHybridWallet", "increase_full");
        }
        if (_venue() == 2) {
            _cool(f, address(f.v3));
            vm.prank(owner);
            f.v3.mint(LOW, HIGH, L);
            if (_venue() == 2) vm.snapshotGasLastCall("VenueV3Wallet", "increase_full");
        }
        if (_venue() == 3) {
            _cool(f, address(f.v4Wallet));
            vm.prank(owner);
            f.v4Wallet.modify(LOW, HIGH, int128(L));
            if (_venue() == 3) vm.snapshotGasLastCall("VenueV4Wallet", "increase_full");
        }
        if (_venue() == 4) {
            _cool(f, address(f.v4Claims));
            vm.prank(owner);
            f.v4Claims.modify(LOW, HIGH, int128(L));
            if (_venue() == 4) vm.snapshotGasLastCall("VenueV4Claims", "increase_full");
        }
    }

    function _exitAll(uint256 index, uint128 liquidity, string memory label) private {
        Fixture storage f = fixtures[index];
        uint256 a;
        uint256 b;
        uint256 fees0;
        uint256 fees1;
        // Only upstream comparisons need this quote. Never warm the linked LP library before measuring a hybrid exit.
        if (_venue() >= 2) (a, b, fees0, fees1) = f.walletBook.positionValue(1);
        if (liquidity == 0) {
            a = 0;
            b = 0;
        }
        a += fees0;
        b += fees1;
        bytes memory action = liquidity == 0
            ? abi.encodeCall(Book.collect, (uint256(1)))
            : abi.encodeCall(Book.burn, (uint256(1), liquidity, uint256(0), uint256(0), NEVER));
        if (_venue() == 0) {
            _cool(f, address(f.funded));
            vm.prank(owner);
            (bool ok,) = address(f.funded).call(action);
            vm.snapshotGasLastCall("VenueHybridFunded", label);
            assertTrue(ok);
        }
        if (_venue() == 1) {
            bytes[] memory calls = new bytes[](1);
            calls[0] = action;
            _cool(f, address(f.walletBook));
            vm.prank(owner);
            f.walletBook.executeWallet(calls, owner);
            if (_venue() == 1) vm.snapshotGasLastCall("VenueHybridWallet", label);
        }
        if (_venue() == 2) {
            _cool(f, address(f.v3));
            vm.prank(owner);
            (uint128 x, uint128 y) = f.v3.exit(LOW, HIGH, liquidity);
            if (_venue() == 2) vm.snapshotGasLastCall("VenueV3Wallet", label);
            assertApproxEqAbs(x, a, 1000);
            assertApproxEqAbs(y, b, 1000);
        }
        if (_venue() == 3) {
            _cool(f, address(f.v4Wallet));
            vm.prank(owner);
            (int128 d0, int128 d1) = f.v4Wallet.modify(LOW, HIGH, -int128(liquidity));
            if (_venue() == 3) vm.snapshotGasLastCall("VenueV4Wallet", label);
            assertApproxEqAbs(uint128(d0), a, 1000);
            assertApproxEqAbs(uint128(d1), b, 1000);
        }
        if (_venue() == 4) {
            _cool(f, address(f.v4Claims));
            vm.prank(owner);
            (int128 d0, int128 d1) = f.v4Claims.modify(LOW, HIGH, -int128(liquidity));
            if (_venue() == 4) vm.snapshotGasLastCall("VenueV4Claims", label);
            assertApproxEqAbs(uint128(d0), a, 1000);
            assertApproxEqAbs(uint128(d1), b, 1000);
        }
    }

    function _swapAll(uint256 index, bool down, uint128 input, string memory label, bool measure) private {
        Fixture storage f = fixtures[index];
        uint160 limit = down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        Book.TradeRequest memory r = Book.TradeRequest(f.market, down, input, limit, 0, 128, NEVER, false);
        if (measure) _cool(f, address(f.funded));
        vm.prank(owner);
        Book.TradeResult memory result = f.funded.trade(r);
        if (measure && _venue() == 0) vm.snapshotGasLastCall("VenueHybridFunded", label);
        assertEq(result.input, input);
        if (!measure || _venue() == 1) {
            if (measure) _cool(f, address(f.walletBook));
            vm.prank(owner);
            Book.TradeResult memory walletResult = f.walletBook.swapWallet(r, owner);
            if (measure && _venue() == 1) vm.snapshotGasLastCall("VenueHybridWallet", label);
            assertEq(abi.encode(walletResult), abi.encode(result));
        }
        if (!measure || _venue() == 2) {
            if (measure) _cool(f, address(f.v3));
            vm.prank(owner);
            (uint256 spent, uint256 output) = f.v3.swap(down, input, limit);
            if (measure && _venue() == 2) vm.snapshotGasLastCall("VenueV3Wallet", label);
            assertEq(spent, input);
            assertApproxEqAbs(output, result.output, 1000);
        }
        if (!measure || _venue() == 3) {
            if (measure) _cool(f, address(f.v4Wallet));
            vm.prank(owner);
            (uint256 spent, uint256 output) = f.v4Wallet.swap(down, input, limit);
            if (measure && _venue() == 3) vm.snapshotGasLastCall("VenueV4Wallet", label);
            assertEq(spent, input);
            assertApproxEqAbs(output, result.output, 1000);
        }
        if (!measure || _venue() == 4) {
            if (measure) _cool(f, address(f.v4Claims));
            vm.prank(owner);
            (uint256 spent, uint256 output) = f.v4Claims.swap(down, input, limit);
            if (measure && _venue() == 4) vm.snapshotGasLastCall("VenueV4Claims", label);
            assertEq(spent, input);
            assertApproxEqAbs(output, result.output, 1000);
        }
    }

    /// @dev Separate tests prevent a preceding venue from dirtying shared ERC-20 balance slots.
    function _venue() internal pure virtual returns (uint8);

    function _approve(MockERC20 token, Fixture storage f) private {
        token.approve(address(f.funded), type(uint256).max);
        token.approve(address(f.walletBook), type(uint256).max);
        token.approve(address(f.v3), type(uint256).max);
        token.approve(address(f.v4Wallet), type(uint256).max);
        token.approve(address(f.v4Claims), type(uint256).max);
    }

    function _cool(Fixture storage f, address target) private {
        vm.cool(address(Orders));
        vm.cool(address(CL));
        vm.cool(address(Wallet));
        vm.cool(target);
        vm.cool(address(f.token0));
        vm.cool(address(f.token1));
        if (target == address(f.v3)) vm.cool(address(f.v3.pool()));
        if (target == address(f.v4Wallet)) vm.cool(address(managerWallet));
        if (target == address(f.v4Claims)) vm.cool(address(managerClaims));
        // Reading the adapter's immutable pool above warms its code; cool it again.
        vm.cool(target);
    }

    function _principal(uint160 price, int24 low, int24 high, uint128 liquidity)
        private
        pure
        returns (uint256 a, uint256 b)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(low);
        uint160 upper = TickMath.getSqrtPriceAtTick(high);
        if (price < upper) a = SqrtPriceMath.getAmount0Delta(price > lower ? price : lower, upper, liquidity, true);
        if (price > lower) b = SqrtPriceMath.getAmount1Delta(lower, price < upper ? price : upper, liquidity, true);
    }

    function _deploy(string memory path, bytes memory args) private returns (address deployed) {
        bytes memory code = abi.encodePacked(vm.getCode(path), args);
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "artifact deployment failed");
    }
}

contract CompareHybridFundedGasTest is VenueComparisonGasBase {
    function _venue() internal pure override returns (uint8) {
        return 0;
    }
}

contract CompareHybridWalletGasTest is VenueComparisonGasBase {
    function _venue() internal pure override returns (uint8) {
        return 1;
    }
}

contract CompareV3WalletGasTest is VenueComparisonGasBase {
    function _venue() internal pure override returns (uint8) {
        return 2;
    }
}

contract CompareV4WalletGasTest is VenueComparisonGasBase {
    function _venue() internal pure override returns (uint8) {
        return 3;
    }
}

contract CompareV4ClaimsGasTest is VenueComparisonGasBase {
    function _venue() internal pure override returns (uint8) {
        return 4;
    }
}
