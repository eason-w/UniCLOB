// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AdaptiveFifoQueue
/// @notice Packed four-way quantity tree with FIFO prefix consumption and deferred maker claims.
/// @dev Each node stores four uint64 subtree totals in one slot. A zero child is logically cleared.
///      The active root grows toward the fixed 2^32-leaf root as orders are appended.
///      Four orders fit in one node; expansion adds a parent without relocating existing nodes.
///      A price-side queue holds at most 2^64-1 lots and 2^32 insertions per generation.
library AdaptiveFifoQueue {
    uint64 internal constant CAPACITY = 1 << 32;
    uint256 private constant MASK = type(uint64).max;

    /// @notice All 2^32 sequence identifiers are used and unfilled quantities prevent rollover.
    error QueueFull();
    /// @notice Quantity is zero, exceeds available lots or exceeds the uint64 aggregate capacity.
    error InvalidQuantity();

    struct Queue {
        uint64 generation;
        uint64 next;
        mapping(uint32 node => uint256 children) tree;
    }

    /// @notice Total unfilled lots at this price and side.
    function total(Queue storage self) internal view returns (uint128) {
        (uint32 root,) = _root(self.next);
        uint256 word = self.tree[root];
        return uint128((word & MASK) + ((word >> 64) & MASK) + ((word >> 128) & MASK) + (word >> 192));
    }

    /// @notice Appends a funded order; identifiers are (generation, sequence).
    function append(Queue storage self, uint128 lots) internal returns (uint64 generation, uint32 sequence) {
        uint128 current = total(self);
        if (lots == 0 || lots > MASK - current) revert InvalidQuantity();
        if (self.next == CAPACITY) {
            if (current != 0) revert QueueFull();
            ++self.generation;
            self.next = 0;
        }
        generation = self.generation;
        sequence = uint32(self.next++);
        (uint32 root, uint256 bits) = _root(self.next);
        if (sequence == 0) {
            // Starting a generation must discard the old leaf, including its sibling fields.
            self.tree[root] = lots;
        } else {
            (uint32 oldRoot,) = _root(sequence);
            if (root != oldRoot) self.tree[root] = current;
            _append(self, root, bits, sequence, uint64(lots), false);
        }
    }

    /// @notice Recycles empty quote history so repeated replacements retain shallow queue cost.
    /// @dev Only an empty queue can change generation; every prior order then has zero remaining lots.
    function restartIfEmpty(Queue storage self) internal {
        if (self.next != 0 && total(self) == 0) {
            ++self.generation;
            self.next = 0;
        }
    }

    /// @notice Remaining lots of an order, including lazy ancestor consumption.
    function remaining(Queue storage self, uint64 generation, uint32 sequence) internal view returns (uint128 lots) {
        if (generation != self.generation || sequence >= self.next) return 0;
        (uint32 node, uint256 bits) = _root(self.next);
        while (true) {
            uint32 child = (sequence >> bits) & 3;
            uint256 quantity = (self.tree[node] >> (uint256(child) * 64)) & MASK;
            if (quantity == 0 || bits == 0) return uint128(quantity);
            node = node * 4 + child;
            bits -= 2;
        }
    }

    /// @notice Consumes a FIFO prefix in at most sixteen tree levels, independently of filled maker count.
    function consume(Queue storage self, uint128 lots) internal {
        uint128 current = total(self);
        if (lots == 0 || lots > current) revert InvalidQuantity();
        (uint32 root, uint256 bits) = _root(self.next);
        if (lots == current) self.tree[root] = 0;
        else _consume(self, root, bits, uint64(lots));
    }

    /// @notice Cancels unfilled lots without changing the priority of surviving quantities.
    function cancel(Queue storage self, uint64 generation, uint32 sequence, uint128 lots) internal {
        if (lots == 0 || lots > remaining(self, generation, sequence)) revert InvalidQuantity();
        (uint32 node, uint256 bits) = _root(self.next);
        while (true) {
            uint32 child = (sequence >> bits) & 3;
            self.tree[node] -= uint256(lots) << (uint256(child) * 64);
            if (bits == 0) break;
            node = node * 4 + child;
            bits -= 2;
        }
    }

    // Root of the smallest power-of-four subtree containing every sequence in this generation.
    // Nodes keep their fixed full-tree addresses, so expansion never copies existing children.
    function _root(uint64 count) private pure returns (uint32 node, uint256 bits) {
        // Fixed heap addresses in a 16-level tree keep every existing child in place.
        // Common shallow queues retain constant-time branch selection.
        if (count <= 4) return (1 << 30, 0);
        if (count <= 16) return (1 << 28, 2);
        if (count <= 64) return (1 << 26, 4);
        if (count <= 256) return (1 << 24, 6);
        if (count <= 1024) return (1 << 22, 8);
        if (count <= 4096) return (1 << 20, 10);
        bits = Math.log2(count - 1) & ~uint256(1);
        return (uint32(1 << (30 - bits)), bits);
    }

    function _append(Queue storage self, uint32 node, uint256 bits, uint32 sequence, uint64 lots, bool clear) private {
        uint256 word = clear ? 0 : self.tree[node];
        uint32 child = (sequence >> bits) & 3;
        uint256 shift = uint256(child) * 64;
        uint256 previous = (word >> shift) & MASK;
        // The whole queue is capped at uint64, so no addition can carry into a sibling field.
        self.tree[node] = word + (uint256(lots) << shift);
        if (bits != 0) _append(self, node * 4 + child, bits - 2, sequence, lots, previous == 0);
    }

    function _consume(Queue storage self, uint32 node, uint256 bits, uint64 lots) private {
        uint256 word = self.tree[node];
        for (uint32 child; child < 4; ++child) {
            uint256 shift = uint256(child) * 64;
            uint64 quantity = uint64(word >> shift);
            if (lots >= quantity) {
                word &= ~(MASK << shift);
                lots -= quantity;
                if (lots == 0) break;
            } else {
                word -= uint256(lots) << shift;
                if (bits != 0) _consume(self, node * 4 + child, bits - 2, lots);
                break;
            }
        }
        self.tree[node] = word;
    }
}
