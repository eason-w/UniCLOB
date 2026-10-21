// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PriceBitmap } from "../../src/libraries/PriceBitmap.sol";
import { FeeMath } from "../../src/libraries/FeeMath.sol";

contract BitmapHarness {
    using PriceBitmap for PriceBitmap.Map;
    PriceBitmap.Map private map;

    function set(uint16 i, bool yes) external {
        map.set(i, yes);
    }

    function first() external view returns (bool, uint16) {
        return map.first();
    }

    function last() external view returns (bool, uint16) {
        return map.last();
    }

    function next(uint16 i, bool up) external view returns (bool, uint16) {
        return map.next(i, up);
    }
}

contract LibrariesTest is Test {
    BitmapHarness internal map;

    function setUp() public {
        map = new BitmapHarness();
    }

    function test_BitmapWordBoundariesAndRemoval() public {
        map.set(0, true);
        map.set(255, true);
        map.set(256, true);
        map.set(65_535, true);
        (, uint16 price) = map.first();
        assertEq(price, 0);
        (, price) = map.last();
        assertEq(price, 65_535);
        (, price) = map.next(1, true);
        assertEq(price, 255);
        (, price) = map.next(257, false);
        assertEq(price, 256);
        map.set(0, false);
        (, price) = map.first();
        assertEq(price, 255);
        map.set(255, false);
        map.set(256, false);
        map.set(65_535, false);
        (bool exists,) = map.first();
        assertFalse(exists);
        (exists,) = map.last();
        assertFalse(exists);
        (exists,) = map.next(0, false);
        assertFalse(exists);
        (exists,) = map.next(65_535, true);
        assertFalse(exists);
    }

    function testFuzz_FeeConversionIsMinimal(uint128 net, uint24 feeSeed) public pure {
        uint24 fee = uint24(bound(feeSeed, 1, 100_000));
        uint256 gross = FeeMath.gross(net, fee);
        assertEq(FeeMath.principal(gross, fee), net);
        if (net != 0) assertLt(FeeMath.principal(gross - 1, fee), net);
        uint256 charged = gross - net;
        assertEq(charged, (gross * fee + 999_999) / 1_000_000);
    }

    function testFuzz_BitmapMatchesArray(uint256 seed) public {
        uint16[32] memory indices;
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            indices[i] = uint16(seed);
            map.set(indices[i], true);
        }
        uint16 from = uint16(seed >> 16);
        bool foundUp;
        bool foundDown;
        uint16 up = type(uint16).max;
        uint16 down;
        for (uint256 i; i < 32; ++i) {
            if (indices[i] >= from && (!foundUp || indices[i] < up)) {
                up = indices[i];
                foundUp = true;
            }
            if (indices[i] <= from && (!foundDown || indices[i] > down)) {
                down = indices[i];
                foundDown = true;
            }
        }
        (bool exists, uint16 price) = map.next(from, true);
        assertEq(exists, foundUp);
        if (exists) assertEq(price, up);
        (exists, price) = map.next(from, false);
        assertEq(exists, foundDown);
        if (exists) assertEq(price, down);
    }
}
