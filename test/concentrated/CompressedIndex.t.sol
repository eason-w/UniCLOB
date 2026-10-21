// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { Test } from "forge-std/Test.sol";
import { TickTree } from "../../src/libraries/TickTree.sol";

contract CompressedIndexHarness {
    using TickTree for TickTree.Map;
    TickTree.Map private tree;
    int24 public immutable spacing;

    constructor(int24 step) {
        spacing = step;
    }

    function set(int24 tick, bool present) external {
        tree.set(tick, present, spacing);
    }

    function next(int24 tick, bool up) external view returns (bool, int24) {
        return tree.next(tick, up, spacing);
    }

    function best(bool up) external view returns (bool, int24) {
        return tree.best(up, spacing);
    }
}

contract CompressedIndexTest is Test {
    function testFuzz_CompressedIndexMatchesLinearModel(uint256 seed, uint16 rawSpacing, int24 rawStart) public {
        int24 spacing = int24(int256(bound(rawSpacing, 1, 32_767)));
        _model(seed, spacing, rawStart);
    }

    function test_ThresholdsAndNegativeRounding() public {
        int24[8] memory steps = [int24(1), 10, 27, 28, 60, 200, 16_384, 32_767];
        for (uint256 i; i < steps.length; ++i) {
            _model(12_345, steps[i], -1);
            _model(98_765, steps[i], 1);
            _model(67_123, steps[i], type(int24).min);
            _model(87_293, steps[i], type(int24).max);
        }
    }

    function _model(uint256 seed, int24 spacing, int24 start) private {
        CompressedIndexHarness tree = new CompressedIndexHarness(spacing);
        int24 low = -887_272 / spacing;
        int24 high = 887_272 / spacing;
        int24[18] memory ticks;
        bool[18] memory live;
        ticks[0] = low * spacing;
        ticks[1] = high * spacing;
        for (uint256 i; i < ticks.length; ++i) {
            if (i > 1) {
                seed = uint256(keccak256(abi.encode(seed, i)));
                ticks[i] = (low + int24(int256(seed % uint256(int256(high - low + 1))))) * spacing;
            }
            tree.set(ticks[i], true);
            live[i] = true;
        }
        // Remove duplicates consistently in the explicit model.
        for (uint256 i = 2; i < ticks.length; i += 3) {
            tree.set(ticks[i], false);
            for (uint256 j; j < ticks.length; ++j) {
                if (ticks[j] == ticks[i]) live[j] = false;
            }
        }
        for (uint256 dir; dir < 2; ++dir) {
            bool up = dir == 0;
            bool found;
            int24 expected;
            bool any;
            int24 edge;
            for (uint256 i; i < ticks.length; ++i) {
                if (!live[i]) continue;
                if (!any || (up ? ticks[i] < edge : ticks[i] > edge)) edge = ticks[i];
                any = true;
                if (
                    (up ? ticks[i] >= start : ticks[i] <= start)
                        && (!found || (up ? ticks[i] < expected : ticks[i] > expected))
                ) {
                    found = true;
                    expected = ticks[i];
                }
            }
            (bool actualFound, int24 actual) = tree.next(start, up);
            assertEq(actualFound, found);
            if (found) assertEq(actual, expected);
            (actualFound, actual) = tree.best(up);
            assertEq(actualFound, any);
            if (any) assertEq(actual, edge);
        }
        for (uint256 i; i < ticks.length; ++i) {
            tree.set(ticks[i], false);
        }
        (bool remains,) = tree.best(true);
        assertFalse(remains);
    }
}
