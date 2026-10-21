// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { AdaptiveFifoQueue as FifoQueue } from "../../src/libraries/AdaptiveFifoQueue.sol";

contract AdaptiveQueueHarness {
    using FifoQueue for FifoQueue.Queue;
    FifoQueue.Queue private queue;

    function append(uint128 n) external returns (uint64, uint32) {
        return queue.append(n);
    }

    function consume(uint128 n) external {
        queue.consume(n);
    }

    function cancel(uint64 g, uint32 s, uint128 n) external {
        queue.cancel(g, s, n);
    }

    function remaining(uint64 g, uint32 s) external view returns (uint128) {
        return queue.remaining(g, s);
    }

    function total() external view returns (uint128) {
        return queue.total();
    }

    /// @dev Models a generation whose earlier orders were all consumed; no live leaves are fabricated.
    function exhaustedHistory(uint64 count) external {
        require(queue.total() == 0 && count <= 1 << 32, "invalid empty history");
        queue.next = count;
    }

    function restartIfEmpty() external {
        queue.restartIfEmpty();
    }

    function populate(uint32 count) external {
        for (uint32 i; i < count; ++i) {
            queue.append(1);
        }
    }
}

contract AdaptiveQueueTest is Test {
    AdaptiveQueueHarness internal queue;

    function setUp() public {
        queue = new AdaptiveQueueHarness();
    }

    function test_QueuePartialLeafConsumption() public {
        queue.append(100);
        queue.consume(25);
        assertEq(queue.remaining(0, 0), 75);
        queue.cancel(0, 0, 15);
        assertEq(queue.remaining(0, 0), 60);
        assertEq(queue.total(), 60);
    }

    function test_QueueFullSubtreeThenNewInsertCannotReviveClaims() public {
        queue.append(10);
        queue.append(20);
        queue.consume(30);
        // Claims must observe the consumed ancestor before any later insertion clears stale leaves.
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 0);
        queue.append(40);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 0);
        assertEq(queue.remaining(0, 2), 40);
        queue.consume(5);
        queue.append(50);
        assertEq(queue.remaining(0, 2), 35);
        assertEq(queue.remaining(0, 3), 50);
        assertEq(queue.total(), 85);
    }

    function test_QueueCancellationHoleAndAggregatePrefix() public {
        queue.append(10);
        queue.append(20);
        queue.append(30);
        queue.cancel(0, 1, 20);
        queue.consume(25);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 0);
        assertEq(queue.remaining(0, 2), 15);
    }

    function test_QueueCapacityAndGenerationRollover() public {
        queue.exhaustedHistory((uint64(1) << 32) - 4096);
        queue.populate(4096);
        vm.expectRevert(FifoQueue.QueueFull.selector);
        queue.append(1);
        queue.consume(4096);
        (uint64 generation, uint32 sequence) = queue.append(100);
        assertEq(generation, 1);
        assertEq(sequence, 0);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 4095), 0);
        assertEq(queue.remaining(1, 0), 100);
        vm.expectRevert(FifoQueue.InvalidQuantity.selector);
        queue.cancel(0, 0, 1);
    }

    function test_RevertWhen_QueueQuantityInvalid() public {
        vm.expectRevert(FifoQueue.InvalidQuantity.selector);
        queue.append(0);
        vm.expectRevert(FifoQueue.InvalidQuantity.selector);
        queue.consume(1);
        queue.append(1);
        vm.expectRevert(FifoQueue.InvalidQuantity.selector);
        queue.consume(2);
    }

    function test_PackedQueueCapacityCannotCarryIntoSibling() public {
        queue.append(type(uint64).max - 1);
        queue.append(1);
        assertEq(queue.total(), type(uint64).max);
        vm.expectRevert(FifoQueue.InvalidQuantity.selector);
        queue.append(1);
        queue.consume(type(uint64).max - 2);
        assertEq(queue.remaining(0, 0), 1);
        assertEq(queue.remaining(0, 1), 1);
        queue.cancel(0, 0, 1);
        queue.append(type(uint64).max - 1);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 1);
        assertEq(queue.remaining(0, 2), type(uint64).max - 1);
    }

    function test_AdaptiveExpansionPreservesPartialFillAndCancellation() public {
        queue.append(100);
        queue.consume(25);
        queue.cancel(0, 0, 15);
        queue.append(50);
        assertEq(queue.remaining(0, 0), 60);
        assertEq(queue.remaining(0, 1), 50);
        queue.consume(70);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 40);
    }

    function test_AdaptiveExpansionAfterFirstOrderCancelled() public {
        queue.append(100);
        queue.cancel(0, 0, 100);
        queue.append(50);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 1), 50);
    }

    function test_AdaptiveExpansionAfterRolloverClearsStaleDescendants() public {
        queue.populate(4096);
        queue.consume(4096);
        queue.exhaustedHistory(uint64(1) << 32);
        queue.append(100);
        queue.consume(25);
        queue.cancel(1, 0, 15);
        queue.append(50);
        assertEq(queue.remaining(1, 0), 60);
        assertEq(queue.remaining(1, 1), 50);
        queue.consume(65);
        assertEq(queue.remaining(1, 0), 0);
        assertEq(queue.remaining(1, 1), 45);
        queue.append(20);
        assertEq(queue.remaining(1, 2), 20);
        assertEq(queue.remaining(0, 4095), 0);
    }

    function test_AllRootExpansionsPreservePartialConsumptionAndHoles() public {
        for (uint32 count = 4; count <= 1024; count *= 4) {
            queue = new AdaptiveQueueHarness();
            queue.populate(count);
            queue.consume(count / 2);
            queue.cancel(0, count - 1, 1);
            queue.append(7);
            assertEq(queue.total(), count / 2 + 6);
            assertEq(queue.remaining(0, count / 2 - 1), 0);
            assertEq(queue.remaining(0, count / 2), 1);
            assertEq(queue.remaining(0, count - 1), 0);
            assertEq(queue.remaining(0, count), 7);
            queue.consume(count / 2 + 2);
            assertEq(queue.remaining(0, count), 4);
            queue.append(9);
            assertEq(queue.remaining(0, count), 4);
            assertEq(queue.remaining(0, count + 1), 9);
            assertEq(queue.total(), 13);
        }
    }

    function test_AllRootExpansionsAfterRolloverDoNotReviveOldGeneration() public {
        queue.populate(4096);
        queue.consume(4096);
        queue.exhaustedHistory(uint64(1) << 32);
        uint128 expected;
        uint32 drainAt = 4;
        for (uint32 i; i < 4096; ++i) {
            queue.append(1);
            ++expected;
            assertEq(queue.remaining(1, i), 1);
            if (i + 1 == drainAt) {
                assertEq(queue.total(), expected);
                queue.consume(expected);
                expected = 0;
                drainAt *= 4;
                assertEq(queue.remaining(1, i), 0);
            }
        }
        assertEq(queue.total(), 0);
        assertEq(queue.remaining(1, 0), 0);
        assertEq(queue.remaining(1, 4095), 0);
        assertEq(queue.remaining(0, 4095), 0);
    }

    function test_PinnedOrderDoesNotBlock4097thAppend() public {
        queue.append(100);
        for (uint32 i = 1; i < 4096; ++i) {
            (, uint32 sequence) = queue.append(1);
            queue.cancel(0, sequence, 1);
        }
        (uint64 generation, uint32 sequence) = queue.append(50);
        assertEq(generation, 0);
        assertEq(sequence, 4096);
        assertEq(queue.remaining(0, 0), 100);
        assertEq(queue.remaining(0, 4095), 0);
        queue.consume(110);
        assertEq(queue.remaining(0, 0), 0);
        assertEq(queue.remaining(0, 4096), 40);
        assertEq(queue.total(), 40);
    }

    function test_AllSixteenLevelsAndRolloverPreserveFinalOrder() public {
        // Empty prefixes represent fully consumed historical orders. Test each higher expansion.
        for (uint64 boundary = 4; boundary < (uint64(1) << 32); boundary *= 4) {
            queue = new AdaptiveQueueHarness();
            queue.exhaustedHistory(boundary - 1);
            (, uint32 before_) = queue.append(100);
            (, uint32 after_) = queue.append(50);
            assertEq(before_, boundary - 1);
            assertEq(after_, boundary);
            assertEq(queue.total(), 150);
            queue.consume(110);
            assertEq(queue.remaining(0, before_), 0);
            assertEq(queue.remaining(0, after_), 40);
            queue.cancel(0, after_, 15);
            assertEq(queue.total(), 25);
            queue.consume(25);
        }
        queue.exhaustedHistory((uint64(1) << 32) - 1);
        (, uint32 last) = queue.append(9);
        assertEq(last, type(uint32).max);
        vm.expectRevert(FifoQueue.QueueFull.selector);
        queue.append(1);
        queue.consume(9);
        (uint64 generation, uint32 sequence) = queue.append(7);
        assertEq(generation, 1);
        assertEq(sequence, 0);
        assertEq(queue.remaining(0, last), 0);
        assertEq(queue.remaining(1, 0), 7);
    }

    function test_ExplicitRestartClearsDeepStaleHistoryAndCannotRestartLiveQueue() public {
        queue.populate(4096);
        queue.restartIfEmpty();
        assertEq(queue.remaining(0, 4095), 1);
        queue.consume(4096);
        queue.restartIfEmpty();
        for (uint32 i; i < 4097; ++i) {
            (uint64 generation, uint32 sequence) = queue.append(2);
            assertEq(generation, 1);
            assertEq(sequence, i);
            assertEq(queue.total(), uint128(i + 1) * 2);
            assertEq(queue.remaining(0, i), 0);
        }
        queue.consume(8190);
        assertEq(queue.remaining(1, 4095), 2);
        assertEq(queue.remaining(1, 4096), 2);
    }

    function testFuzz_QueueMatchesExplicitFIFO(uint256 seed) public {
        _model(seed, 0);
    }

    function testFuzz_DeepHistoryMatchesExplicitFIFO(uint256 seed, uint32 history) public {
        _model(seed, uint32(bound(history, 0, uint256(type(uint32).max) - 128)));
    }

    function _model(uint256 seed, uint32 history) private {
        queue.exhaustedHistory(history);
        uint128[128] memory quantities;
        uint32 count;
        uint128 total;
        for (uint32 step; step < 128; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 3;
            if (op == 0 || total == 0) {
                uint128 n = uint128((seed >> 32) % 1000 + 1);
                queue.append(n);
                quantities[count++] = n;
                total += n;
            } else if (op == 1) {
                uint128 n = uint128((seed >> 32) % total + 1);
                queue.consume(n);
                total -= n;
                for (uint32 i; i < count && n != 0; ++i) {
                    uint128 take = quantities[i] < n ? quantities[i] : n;
                    quantities[i] -= take;
                    n -= take;
                }
            } else {
                uint32 index = uint32((seed >> 32) % count);
                if (quantities[index] != 0) {
                    uint128 n = uint128((seed >> 64) % quantities[index] + 1);
                    queue.cancel(0, history + index, n);
                    quantities[index] -= n;
                    total -= n;
                }
            }
            assertEq(queue.total(), total);
            // Check a historical claim at every step, not only the aggregate.
            uint32 probe = uint32((seed >> 96) % count);
            assertEq(queue.remaining(0, history + probe), quantities[probe]);
        }
        for (uint32 i; i < count; ++i) {
            assertEq(queue.remaining(0, history + i), quantities[i]);
        }
    }
}

