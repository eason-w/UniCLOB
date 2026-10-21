// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PriceBitmap } from "./PriceBitmap.sol";

/// @title TickTree
/// @notice Three-level bitmap with bounded lookup across the entire Uniswap tick domain.
/// @dev Empty bitmap words are skipped through summaries, not scanned sequentially.
library TickTree {
    using PriceBitmap for PriceBitmap.Map;

    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    error InvalidTick();

    struct Map {
        PriceBitmap.Map branches;
        mapping(uint16 word => uint256 bits) leaves;
    }

    /// @notice Changes membership of a valid tick.
    function set(Map storage self, int24 tick, bool present) internal {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
        uint24 key = uint24(tick - MIN_TICK);
        uint16 word = uint16(key >> 8);
        uint256 mask = uint256(1) << (key & 255);
        uint256 before_ = self.leaves[word];
        uint256 after_ = present ? before_ | mask : before_ & ~mask;
        if (before_ == after_) return;
        self.leaves[word] = after_;
        if (before_ == 0 || after_ == 0) self.branches.set(word, after_ != 0);
    }

    /// @notice Finds the nearest member inclusively in either direction.
    function next(Map storage self, int24 from, bool ascending) internal view returns (bool found, int24 tick) {
        if (ascending && from > MAX_TICK || !ascending && from < MIN_TICK) return (false, 0);
        if (from < MIN_TICK) from = MIN_TICK;
        if (from > MAX_TICK) from = MAX_TICK;
        uint24 key = uint24(from - MIN_TICK);
        uint16 word = uint16(key >> 8);
        uint256 bit = key & 255;
        uint256 bits = self.leaves[word];
        bits &= ascending ? type(uint256).max << bit : type(uint256).max >> (255 - bit);
        if (bits == 0) {
            if (ascending) {
                (found, word) = self.branches.next(word + 1, true);
            } else {
                if (word == 0) return (false, 0);
                (found, word) = self.branches.next(word - 1, false);
            }
            if (!found) return (false, 0);
            bits = self.leaves[word];
        }
        uint256 offset = ascending ? PriceBitmap.leastBit(bits) : Math.log2(bits);
        tick = int24(uint24((uint256(word) << 8) | offset)) + MIN_TICK;
        return (true, tick);
    }
}
