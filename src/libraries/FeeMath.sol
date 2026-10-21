// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeMath
/// @notice Cumulative input-fee conversion. Source changes must not reset the cumulative principal.
library FeeMath {
    uint256 internal constant DENOMINATOR = 1_000_000;

    /// @notice Maximum principal fundable by a gross input budget.
    function principal(uint256 grossInput, uint24 fee) internal pure returns (uint256) {
        return Math.mulDiv(grossInput, DENOMINATOR - fee, DENOMINATOR);
    }

    /// @notice Least cumulative gross input needed for cumulative principal.
    function gross(uint256 netInput, uint24 fee) internal pure returns (uint256) {
        return Math.mulDiv(netInput, DENOMINATOR, DENOMINATOR - fee, Math.Rounding.Ceil);
    }
}

