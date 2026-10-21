// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PriceBitmap
/// @notice Two-level bitmap covering 65,536 prices with bounded best-price lookup.
library PriceBitmap {
    struct Map {
        uint256 groups;
        mapping(uint256 group => uint256 bits) words;
    }

    /// @notice Sets or clears a price, avoiding writes when membership is unchanged.
    function set(Map storage self, uint16 price, bool present) internal {
        uint256 group = uint256(price) >> 8;
        uint256 mask = uint256(1) << (price & 255);
        uint256 beforeWord = self.words[group];
        uint256 afterWord = present ? beforeWord | mask : beforeWord & ~mask;
        if (beforeWord == afterWord) return;
        self.words[group] = afterWord;
        if (beforeWord == 0) self.groups |= uint256(1) << group;
        else if (afterWord == 0) self.groups &= ~(uint256(1) << group);
    }

    /// @notice Returns the lowest present price; the value is undefined if empty.
    function first(Map storage self) internal view returns (bool exists, uint16 price) {
        uint256 groups = self.groups;
        if (groups == 0) return (false, 0);
        uint256 group = leastBit(groups);
        return (true, uint16((group << 8) | leastBit(self.words[group])));
    }

    /// @notice Returns the highest present price; the value is undefined if empty.
    function last(Map storage self) internal view returns (bool exists, uint16 price) {
        uint256 groups = self.groups;
        if (groups == 0) return (false, 0);
        uint256 group = Math.log2(groups);
        return (true, uint16((group << 8) | Math.log2(self.words[group])));
    }

    /// @notice Finds a present index at or above/below `from`, inclusively.
    function next(Map storage self, uint16 from, bool ascending) internal view returns (bool exists, uint16 price) {
        uint256 group = uint256(from) >> 8;
        uint256 bit = from & 255;
        uint256 word = self.words[group];
        if (ascending) {
            word &= type(uint256).max << bit;
            if (word != 0) return (true, uint16((group << 8) | leastBit(word)));
            uint256 groups = group == 255 ? 0 : self.groups & (type(uint256).max << (group + 1));
            if (groups == 0) return (false, 0);
            group = leastBit(groups);
            return (true, uint16((group << 8) | leastBit(self.words[group])));
        }
        word &= type(uint256).max >> (255 - bit);
        if (word != 0) return (true, uint16((group << 8) | Math.log2(word)));
        uint256 lower = group == 0 ? 0 : self.groups & (type(uint256).max >> (256 - group));
        if (lower == 0) return (false, 0);
        group = Math.log2(lower);
        return (true, uint16((group << 8) | Math.log2(self.words[group])));
    }

    /// @notice Index of the least significant set bit of a nonzero word.
    function leastBit(uint256 word) internal pure returns (uint256) {
        return Math.log2(word & (~word + 1));
    }
}

