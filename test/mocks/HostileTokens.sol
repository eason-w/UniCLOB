// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @notice Test-only mutable tax on transfers, including tax enabled after initial deposits.
contract TaxToken is MockERC20 {
    bool public tax;
    constructor() MockERC20("Tax", "TAX", 18) { }

    function setTax(bool enabled) external {
        tax = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (tax && from != address(0) && to != address(0) && value >= 100) {
            super._update(from, address(0), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}

/// @notice Test-only token that probes reentry during a transfer without requiring it to succeed.
contract CallbackToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public enabled;
    bool public attempted;
    bool public succeeded;
    bytes public returnData;

    constructor() MockERC20("Callback", "CALL", 18) { }

    function configure(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        enabled = true;
        attempted = false;
        succeeded = false;
        delete returnData;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (enabled && from != address(0)) {
            enabled = false;
            attempted = true;
            (succeeded, returnData) = target.call(payload);
        }
    }
}

/// @notice Legacy token with empty transfer return data; SafeERC20 should support it.
contract NoReturnToken is MockERC20 {
    constructor() MockERC20("Legacy", "OLD", 18) { }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        assembly ("memory-safe") { return(0, 0) }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        assembly ("memory-safe") { return(0, 0) }
    }
}

contract FalseReturnToken is MockERC20 {
    constructor() MockERC20("False", "FALSE", 18) { }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

