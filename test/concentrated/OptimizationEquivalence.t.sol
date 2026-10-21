// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedBase, Book, TickMath, FeeMath } from "./Base.sol";
import { ConcentratedRangeBook as BaselineBook } from "../reference/preoptimization/ConcentratedRangeBook.sol";
import { Vm } from "forge-std/Vm.sol";

/// @notice Compare the optimized implementation with the frozen pre-optimization implementation.
/// @dev Exact outputs, nonempty events, revert data and public accounting must agree, including rounding.
///      The optimized empty-claim path intentionally omits the baseline's zero-value OrderClaimed event.
contract OptimizationEquivalenceTest is ConcentratedBase {
    BaselineBook internal baseline;

    function setUp() public override {
        super.setUp();
        baseline = new BaselineBook(address(this));
        BaselineBook.Config memory c = abi.decode(abi.encode(config()), (BaselineBook.Config));
        assertEq(baseline.createMarket(c), market);
        address[4] memory owners = [lp, lp2, maker, taker];
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i];
            token0.mint(owner, 1e35);
            token1.mint(owner, 1e35);
            vm.startPrank(owner);
            token0.approve(address(baseline), type(uint256).max);
            token1.approve(address(baseline), type(uint256).max);
            baseline.deposit(address(token0), 1e35, owner);
            baseline.deposit(address(token1), 1e35, owner);
            vm.stopPrank();
        }
    }

    function test_EquivalentBoundaryCrossingWithBothFeeHistories() public {
        _mint(-887_220, 887_220);
        _both(taker, abi.encodeCall(Book.trade, (request(false, 1e18))), true);
        _both(taker, abi.encodeCall(Book.trade, (request(true, 1e18))), true);
        for (int24 tick = -960; tick <= 960; tick += 60) {
            _mint(tick, tick + 60);
        }
        _both(maker, abi.encodeCall(Book.placeOrder, (market, true, int24(60), uint128(1000), NEVER)), true);
        _both(maker, abi.encodeCall(Book.placeOrder, (market, false, int24(-60), uint128(1000), NEVER)), true);
        _both(taker, abi.encodeCall(Book.trade, (request(false, 2e23))), true);
        _check();
        _both(taker, abi.encodeCall(Book.trade, (request(true, 4e23))), true);
        _check();
        for (uint256 i = 1; i < book.nextPositionId(); ++i) {
            _both(lp, abi.encodeCall(Book.collect, (i)), true);
            _both(lp, abi.encodeCall(Book.burn, (i, L, uint256(0), uint256(0), NEVER)), true);
        }
        _both(maker, abi.encodeCall(Book.claimOrder, (uint256(1))), true);
        _both(maker, abi.encodeCall(Book.claimOrder, (uint256(2))), true);
        _check();
    }

    function test_EquivalentLoneOrderExpansionAndClaims() public {
        _both(maker, abi.encodeCall(Book.placeOrder, (market, true, int24(0), uint128(100), NEVER)), true);
        _both(taker, abi.encodeCall(Book.trade, (request(false, uint128(FeeMath.gross(25 * LOT, 3000))))), true);
        _both(maker, abi.encodeCall(Book.claimOrder, (uint256(1))), true);
        _both(maker, abi.encodeCall(Book.cancelOrder, (uint256(1), uint128(15))), true);
        _both(maker, abi.encodeCall(Book.placeOrder, (market, true, int24(0), uint128(50), NEVER)), true);
        _both(taker, abi.encodeCall(Book.trade, (request(false, uint128(FeeMath.gross(70 * LOT, 3000))))), true);
        _both(maker, abi.encodeCall(Book.claimOrder, (uint256(1))), true);
        _both(maker, abi.encodeCall(Book.claimOrder, (uint256(2))), true);
        _check();
    }

    function testFuzz_OptimizationPreservesHybridEconomics(uint256 seed) public {
        _mint(-887_220, 887_220);
        _mint(-120, 120);
        _both(maker, abi.encodeCall(Book.placeOrder, (market, true, int24(60), uint128(1000), NEVER)), true);
        _both(maker, abi.encodeCall(Book.placeOrder, (market, false, int24(-60), uint128(1000), NEVER)), true);
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 7;
            if (op < 2) {
                Book.TradeRequest memory r = request(op == 0, uint128((seed >> 32) % 2e22 + 1e12));
                r.maxSteps = uint32((seed >> 128) % 8 + 1);
                _both(taker, abi.encodeCall(Book.trade, (r)), false);
            } else if (op == 2) {
                _both(lp, abi.encodeCall(Book.collect, (uint256(seed % 2 + 1))), true);
            } else if (op == 3) {
                bool ask = seed & 256 != 0;
                (, uint160 price,,) = book.getMarket(market);
                int24 tick = TickMath.getTickAtSqrtPrice(price) / 60 * 60 + (ask ? int24(60) : -60);
                _both(
                    maker, abi.encodeCall(Book.placeOrder, (market, ask, tick, uint128(seed % 1000 + 1), NEVER)), false
                );
            } else if (op == 4 || op == 5) {
                uint256 id = (seed >> 32) % (book.nextOrderId() - 1) + 1;
                if (op == 4) _both(maker, abi.encodeCall(Book.cancelOrder, (id, uint128(seed % 100 + 1))), false);
                else _both(maker, abi.encodeCall(Book.claimOrder, (id)), true);
            } else {
                _both(
                    lp,
                    abi.encodeCall(Book.increase, (uint256(2), L / 100, type(uint256).max, type(uint256).max, NEVER)),
                    true
                );
            }
            _check();
        }
    }

    function _mint(int24 low, int24 high) private {
        _both(lp, abi.encodeCall(Book.mint, (market, low, high, L, type(uint256).max, type(uint256).max, NEVER)), true);
    }

    function _both(address owner, bytes memory data, bool mustSucceed) private {
        vm.recordLogs();
        vm.prank(owner);
        (bool ok, bytes memory result) = address(book).call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.recordLogs();
        vm.prank(owner);
        (bool oldOk, bytes memory oldResult) = address(baseline).call(data);
        Vm.Log[] memory oldLogs = vm.getRecordedLogs();
        if (mustSucceed) assertTrue(ok, "required action reverted");
        assertEq(ok, oldOk, "success differs");
        assertEq(result, oldResult, "return/revert data differs");
        if (ok && bytes4(data) == Book.claimOrder.selector && oldLogs.length == 1) {
            (uint128 claimedLots, uint256 proceeds) = abi.decode(oldLogs[0].data, (uint128, uint256));
            if (claimedLots == 0) {
                assertEq(oldLogs[0].topics[0], keccak256("OrderClaimed(uint256,uint128,uint256)"));
                assertEq(proceeds, 0);
                assertEq(logs.length, 0, "empty claim should omit the event");
                return;
            }
        }
        assertEq(logs.length, oldLogs.length, "event count differs");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(abi.encode(logs[i].topics, logs[i].data), abi.encode(oldLogs[i].topics, oldLogs[i].data));
        }
    }

    function _view(bytes memory data) private view {
        (bool ok, bytes memory result) = address(book).staticcall(data);
        (bool oldOk, bytes memory oldResult) = address(baseline).staticcall(data);
        assertTrue(ok && oldOk);
        assertEq(result, oldResult, "public state differs");
    }

    function _check() private view {
        _view(abi.encodeCall(Book.getMarket, (market)));
        _view(abi.encodeCall(Book.reserves, (market)));
        _view(abi.encodeCall(Book.bestOrder, (market, true)));
        _view(abi.encodeCall(Book.bestOrder, (market, false)));
        for (uint256 i; i < book.nextPositionId(); ++i) {
            _view(abi.encodeCall(Book.getPosition, (i)));
            _view(abi.encodeCall(Book.positionValue, (i)));
            Book.Position memory p = book.getPosition(i);
            _view(abi.encodeCall(Book.getTick, (market, p.lower)));
            _view(abi.encodeCall(Book.getTick, (market, p.upper)));
        }
        for (uint256 i; i < book.nextOrderId(); ++i) {
            _view(abi.encodeCall(Book.getOrder, (i)));
        }
        address[4] memory owners = [lp, lp2, maker, taker];
        for (uint256 i; i < owners.length; ++i) {
            _view(abi.encodeCall(book.balanceOf, (owners[i], address(token0))));
            _view(abi.encodeCall(book.balanceOf, (owners[i], address(token1))));
        }
        _view(abi.encodeCall(book.protocolFees, (address(token0))));
        _view(abi.encodeCall(book.protocolFees, (address(token1))));
        assertAccounting();
    }
}
