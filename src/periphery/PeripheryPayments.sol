// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Minimal wrapped-native asset interface, compatible with WETH9.
interface IWrappedNative is IERC20 {
    /// @notice Wraps msg.value into tokens credited to the caller.
    function deposit() external payable;
    /// @notice Burns caller tokens and returns native currency.
    /// @param amount Wrapped token atoms to unwrap.
    function withdraw(uint256 amount) external;
}

/// @notice Shared exact-transfer payments; no arbitrary spender approvals, sweeps or user balance ledger.
abstract contract PeripheryPayments is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    /// @notice Immutable trusted exchange used for all operations.
    Book public immutable core;
    /// @notice Immutable trusted wrapped-native asset; address zero disables native payment support.
    address public immutable wrappedNative;
    /// @notice A supplied deployment address, recipient or token is invalid.
    error InvalidAddress();
    /// @notice Token transfer or wrapping does not deliver exactly the requested amount.
    error UnsupportedAsset();
    /// @notice Native value does not match the declared wrapped-native input.
    error InvalidNativeValue();
    /// @notice A recipient rejected a native-currency transfer.
    error NativeTransferFailed();
    /// @notice A requested input, output or liquidity limit was violated.
    error PeripherySlippage();

    /// @notice Configures immutable dependencies without administrative privileges.
    /// @param book Deployed exchange.
    /// @param wrapped Deployed WETH-compatible asset, or zero to disable native support.
    constructor(Book book, address wrapped) {
        if (address(book).code.length == 0 || (wrapped != address(0) && wrapped.code.length == 0)) {
            revert InvalidAddress();
        }
        core = book;
        wrappedNative = wrapped;
    }

    /// @notice Accepts native currency only from the configured unwrap operation.
    receive() external payable {
        if (msg.sender != wrappedNative || wrappedNative == address(0)) revert InvalidNativeValue();
    }

    /// @dev Rejects zero or internal destinations so settlement cannot leave user proceeds in shared custody.
    function _recipient(address recipient) internal view {
        if (recipient == address(0) || recipient == address(this) || recipient == address(core)) {
            revert InvalidAddress();
        }
    }

    /// @dev Pulls only caller-owned tokens and requires the contract to receive exactly amount atoms.
    function _pull(address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before_ = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != before_ + amount) revert UnsupportedAsset();
    }

    /// @dev Skips zero requirements and approves only the immutable core when existing allowance is insufficient.
    function _approveCore(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (IERC20(token).allowance(address(this), address(core)) < amount) {
            IERC20(token).forceApprove(address(core), type(uint256).max);
        }
    }

    /// @dev Wraps this call's native input and verifies the exact wrapped-token receipt.
    // The destination is constructor-validated and immutable; callers pass only their own msg.value.
    // slither-disable-next-line arbitrary-send-eth
    function _wrap(uint256 amount) internal {
        uint256 before_ = IERC20(wrappedNative).balanceOf(address(this));
        IWrappedNative(wrappedNative).deposit{ value: amount }();
        if (IERC20(wrappedNative).balanceOf(address(this)) != before_ + amount) revert UnsupportedAsset();
    }

    /// @dev Delivers only the specified call-local amount; ERC20 transfers must debit and credit exactly.
    function _pay(address token, address recipient, uint256 amount, bool nativeOut) internal {
        // Skip a zero-sized transfer; this is not an equality check against a manipulable balance.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return;
        if (nativeOut && token == wrappedNative) {
            uint256 before_ = address(this).balance;
            IWrappedNative(wrappedNative).withdraw(amount);
            // Extra native donations remain untouched; only this withdrawal amount is sent.
            if (address(this).balance < before_ + amount) revert UnsupportedAsset();
            (bool success,) = recipient.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            uint256 beforeSelf = IERC20(token).balanceOf(address(this));
            uint256 beforeRecipient = IERC20(token).balanceOf(recipient);
            IERC20(token).safeTransfer(recipient, amount);
            if (
                IERC20(token).balanceOf(address(this)) + amount != beforeSelf
                    || IERC20(token).balanceOf(recipient) != beforeRecipient + amount
            ) revert UnsupportedAsset();
        }
    }
}
