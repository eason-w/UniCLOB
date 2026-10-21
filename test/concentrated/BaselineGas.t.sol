// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedGasTest, Book } from "./Gas.t.sol";
import { ConcentratedRangeBook as BaselineBook } from "../reference/preoptimization/ConcentratedRangeBook.sol";

/// @notice Identical gas fixtures executed against the frozen baseline implementation.
contract ConcentratedBaselineGasTest is ConcentratedGasTest {
    function _newBook() internal override returns (Book) {
        return Book(address(new BaselineBook(address(this))));
    }

    function _group() internal pure override returns (string memory) {
        return "ConcentratedRangeBookBaseline";
    }
}
