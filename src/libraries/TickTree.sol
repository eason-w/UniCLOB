// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PriceBitmap } from "./PriceBitmap.sol";

/// @title TickTree
/// @notice Spacing-compressed bitmap with bounded lookup over the complete supported tick grid.
/// @dev Grids with at most 65,536 points use two levels; finer grids use three. A map's spacing is immutable.
library TickTree {
    using PriceBitmap for PriceBitmap.Map;
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;

    /// @notice Tick or spacing is outside its domain, or membership is changed at an unaligned tick.
    error InvalidTick();

    struct Map {
        PriceBitmap.Map branches;
        mapping(uint16 word => uint256 bits) leaves;
    }

    /// @notice Changes membership on the spacing-one grid.
    function set(Map storage self, int24 tick, bool present) internal {
        set(self, tick, present, 1);
    }

    /// @notice Finds the best member on the spacing-one grid.
    function best(Map storage self, bool ascending) internal view returns (bool found, int24 tick) {
        return best(self, ascending, 1);
    }

    /// @notice Finds an inclusive neighbor on the spacing-one grid.
    function next(Map storage self, int24 from, bool ascending) internal view returns (bool found, int24 tick) {
        return next(self, from, ascending, 1);
    }

    /// @notice Changes membership of an aligned tick using the map's immutable spacing.
    /// @param self Price index.
    /// @param tick Aligned tick to update.
    /// @param present Whether the tick is populated.
    /// @param spacing Positive immutable grid spacing.
    function set(Map storage self, int24 tick, bool present, int24 spacing) internal {
        if (spacing <= 0 || tick < MIN_TICK || tick > MAX_TICK || tick % spacing != 0) revert InvalidTick();
        uint24 key = uint24(tick / spacing - MIN_TICK / spacing);
        if (spacing >= 28) {
            self.branches.set(uint16(key), present);
            return;
        }
        uint16 word = uint16(key >> 8);
        uint256 mask = uint256(1) << (key & 255);
        uint256 before_ = self.leaves[word];
        uint256 after_ = present ? before_ | mask : before_ & ~mask;
        if (before_ == after_) return;
        self.leaves[word] = after_;
        if (before_ == 0 || after_ == 0) self.branches.set(word, after_ != 0);
    }

    /// @notice Finds the lowest/highest member, reading only the root when empty.
    /// @param self Price index.
    /// @param ascending True selects the lowest price; false selects the highest.
    /// @param spacing Positive immutable grid spacing.
    /// @return found Whether the index contains a tick.
    /// @return tick Best tick; undefined when found is false.
    function best(Map storage self, bool ascending, int24 spacing) internal view returns (bool found, int24 tick) {
        uint16 key;
        (found, key) = ascending ? self.branches.first() : self.branches.last();
        if (!found) return (false, 0);
        uint256 index = key;
        if (spacing < 28) {
            uint256 bits = self.leaves[key];
            index = (index << 8) | (ascending ? PriceBitmap.leastBit(bits) : Math.log2(bits));
        }
        tick = (int24(uint24(index)) + MIN_TICK / spacing) * spacing;
    }

    /// @notice Finds the nearest aligned member inclusively in either direction.
    /// @dev Ascending searches round their starting tick up; descending searches round it down.
    /// @param self Price index.
    /// @param from Inclusive starting tick; alignment is not required.
    /// @param ascending True searches toward higher prices.
    /// @param spacing Positive immutable grid spacing.
    /// @return found Whether a matching tick exists.
    /// @return tick Nearest matching tick; undefined when found is false.
    function next(Map storage self, int24 from, bool ascending, int24 spacing)
        internal
        view
        returns (bool found, int24 tick)
    {
        int24 compressed = from / spacing;
        int24 remainder = from % spacing;
        if (ascending && remainder > 0) ++compressed;
        else if (!ascending && remainder < 0) --compressed;
        int24 low = MIN_TICK / spacing;
        int24 high = MAX_TICK / spacing;
        if (ascending && compressed > high || !ascending && compressed < low) return (false, 0);
        if (compressed < low) compressed = low;
        if (compressed > high) compressed = high;
        uint24 key = uint24(compressed - low);
        if (spacing >= 28) {
            uint16 index;
            (found, index) = self.branches.next(uint16(key), ascending);
            return (found, (int24(uint24(index)) + low) * spacing);
        }
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
        tick = (int24(uint24((uint256(word) << 8) | offset)) + low) * spacing;
        return (true, tick);
    }
}
