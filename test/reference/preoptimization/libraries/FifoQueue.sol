// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title FifoQueue
/// @notice Packed four-way quantity tree with FIFO prefix consumption and deferred maker claims.
/// @dev Each node stores four uint64 subtree totals in one slot. A zero child is logically cleared.
///      A price-side queue holds at most 2^64-1 lots and 4096 insertions per generation.
library FifoQueue {
    uint32 internal constant CAPACITY = 4096;
    uint256 private constant MASK = type(uint64).max;

    error QueueFull();
    error InvalidQuantity();

    struct Queue {
        uint64 generation;
        uint32 next;
        mapping(uint32 node => uint256 children) tree;
    }

    /// @notice Total unfilled lots at this price and side.
    function total(Queue storage self) internal view returns (uint128) {
        uint256 word = self.tree[1];
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
        sequence = self.next++;
        _append(self, 1, 10, sequence, uint64(lots), false);
    }

    /// @notice Remaining lots of an order, including lazy ancestor consumption.
    function remaining(Queue storage self, uint64 generation, uint32 sequence) internal view returns (uint128 lots) {
        if (generation != self.generation || sequence >= self.next) return 0;
        uint32 node = 1;
        uint256 bits = 10;
        while (true) {
            uint32 child = (sequence >> bits) & 3;
            uint256 quantity = (self.tree[node] >> (uint256(child) * 64)) & MASK;
            if (quantity == 0 || bits == 0) return uint128(quantity);
            node = node * 4 + child;
            bits -= 2;
        }
    }

    /// @notice Consumes a FIFO prefix in at most six tree levels, independently of filled maker count.
    function consume(Queue storage self, uint128 lots) internal {
        uint128 current = total(self);
        if (lots == 0 || lots > current) revert InvalidQuantity();
        if (lots == current) self.tree[1] = 0;
        else _consume(self, 1, 10, uint64(lots));
    }

    /// @notice Cancels unfilled lots without changing the priority of surviving quantities.
    function cancel(Queue storage self, uint64 generation, uint32 sequence, uint128 lots) internal {
        if (lots == 0 || lots > remaining(self, generation, sequence)) revert InvalidQuantity();
        uint32 node = 1;
        uint256 bits = 10;
        while (true) {
            uint32 child = (sequence >> bits) & 3;
            self.tree[node] -= uint256(lots) << (uint256(child) * 64);
            if (bits == 0) break;
            node = node * 4 + child;
            bits -= 2;
        }
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
