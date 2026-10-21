// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WalletSettlement
/// @notice Transient net settlement for an atomic batch of exchange bookkeeping operations.
/// @dev Linked library, executed in exchange storage. The exchange guards settlement against reentrancy.
///      Positive deltas are debts to the exchange. Free internal balances are never consumed.
library WalletSettlement {
    using SafeERC20 for IERC20;

    bytes32 private constant OWNER = keccak256("rangebook.wallet.owner");
    bytes32 private constant COUNT = keccak256("rangebook.wallet.count");
    bytes32 private constant DELTA = keccak256("rangebook.wallet.delta");
    bytes32 private constant SEEN = keccak256("rangebook.wallet.seen");
    bytes32 private constant TOKEN = keccak256("rangebook.wallet.token");

    /// @notice A wallet batch is already active, or a ledger operation targets a different owner.
    error InvalidWalletContext();
    /// @notice The batch is empty, too large, or contains a forbidden operation.
    error InvalidWalletBatch();
    /// @notice A token delta cannot be represented in the signed settlement domain.
    error DeltaOverflow();
    /// @notice Token transfer did not produce exact custody and recipient balance deltas.
    error UnsupportedToken();

    /// @notice Returns the owner of the current wallet batch, or zero outside a batch.
    function owner() internal view returns (address activeOwner) {
        bytes32 slot = OWNER;
        assembly ("memory-safe") { activeOwner := tload(slot) }
    }

    /// @notice Accumulates a debit or credit, keeping one transient list entry per touched token.
    /// @param who Owner whose position or order is being changed.
    /// @param token Settlement asset.
    /// @param amount Token atoms to debit or credit.
    /// @param debit True accumulates an input obligation; false accumulates output.
    function account(address who, address token, uint256 amount, bool debit) public {
        if (who != owner()) revert InvalidWalletContext();
        if (amount == 0) return;
        if (amount > uint256(type(int256).max)) revert DeltaOverflow();
        bytes32 deltaSlot = keccak256(abi.encode(DELTA, token));
        bytes32 seenSlot = keccak256(abi.encode(SEEN, token));
        int256 previous;
        uint256 seen;
        assembly ("memory-safe") {
            previous := tload(deltaSlot)
            seen := tload(seenSlot)
        }
        int256 next = debit ? previous + int256(amount) : previous - int256(amount);
        if (next == type(int256).min) revert DeltaOverflow();
        assembly ("memory-safe") { tstore(deltaSlot, next) }
        if (seen == 0) {
            bytes32 countSlot = COUNT;
            uint256 count;
            assembly ("memory-safe") { count := tload(countSlot) }
            bytes32 tokenSlot = keccak256(abi.encode(TOKEN, count));
            assembly ("memory-safe") {
                tstore(seenSlot, 1)
                tstore(tokenSlot, token)
                tstore(countSlot, add(count, 1))
            }
        }
    }

    /// @notice Starts a wallet batch and executes only allowlisted bookkeeping calls.
    /// @param calls One to 64 encoded liquidity, order or trade operations.
    /// @return results Return data in call order. Settlement must follow before returning to the caller.
    function execute(bytes[] calldata calls) public returns (bytes[] memory results) {
        if (owner() != address(0)) revert InvalidWalletContext();
        if (calls.length == 0 || calls.length > 64) revert InvalidWalletBatch();
        bytes32 slot = OWNER;
        assembly ("memory-safe") { tstore(slot, caller()) }
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            bytes calldata action = calls[i];
            if (action.length < 4 || !_allowed(bytes4(action[:4]))) revert InvalidWalletBatch();
            (bool success, bytes memory data) = address(this).delegatecall(action);
            if (!success) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
            results[i] = data;
        }
    }

    /// @notice Settles each net token delta exactly once and clears the transient batch context.
    /// @dev Caller must hold the exchange reentrancy lock across this entire function.
    /// @param liability Exchange-wide deposited token obligations, including locked assets.
    /// @param recipient Destination for net output; validated by the exchange.
    function settle(mapping(address => uint256) storage liability, address recipient) public {
        address payer = owner();
        if (payer == address(0) || payer != msg.sender) revert InvalidWalletContext();
        bytes32 countSlot = COUNT;
        uint256 count;
        assembly ("memory-safe") { count := tload(countSlot) }
        // Apply every asset's liability change before the first external token interaction.
        // The caller holds the exchange-wide reentrancy lock through both passes.
        for (uint256 i; i < count; ++i) {
            bytes32 tokenSlot = keccak256(abi.encode(TOKEN, i));
            address token;
            assembly ("memory-safe") { token := tload(tokenSlot) }
            bytes32 deltaSlot = keccak256(abi.encode(DELTA, token));
            int256 delta;
            assembly ("memory-safe") { delta := tload(deltaSlot) }
            if (delta > 0) liability[token] += uint256(delta);
            else if (delta < 0) liability[token] -= uint256(-delta);
        }
        for (uint256 i; i < count; ++i) {
            bytes32 tokenSlot = keccak256(abi.encode(TOKEN, i));
            address token;
            assembly ("memory-safe") { token := tload(tokenSlot) }
            bytes32 deltaSlot = keccak256(abi.encode(DELTA, token));
            bytes32 seenSlot = keccak256(abi.encode(SEEN, token));
            int256 delta;
            assembly ("memory-safe") { delta := tload(deltaSlot) }
            IERC20 asset = IERC20(token);
            if (delta > 0) {
                uint256 amount = uint256(delta);
                uint256 before_ = asset.balanceOf(address(this));
                asset.safeTransferFrom(msg.sender, address(this), amount);
                if (asset.balanceOf(address(this)) != before_ + amount) revert UnsupportedToken();
            } else if (delta < 0) {
                uint256 amount = uint256(-delta);
                uint256 before_ = asset.balanceOf(address(this));
                uint256 beforeRecipient = asset.balanceOf(recipient);
                asset.safeTransfer(recipient, amount);
                if (
                    asset.balanceOf(address(this)) != before_ - amount
                        || asset.balanceOf(recipient) != beforeRecipient + amount
                ) {
                    revert UnsupportedToken();
                }
            }
            assembly ("memory-safe") {
                tstore(tokenSlot, 0)
                tstore(deltaSlot, 0)
                tstore(seenSlot, 0)
            }
        }
        bytes32 ownerSlot = OWNER;
        assembly ("memory-safe") {
            tstore(countSlot, 0)
            tstore(ownerSlot, 0)
        }
    }

    function _allowed(bytes4 selector) private pure returns (bool) {
        return selector == bytes4(keccak256("mint(bytes32,int24,int24,uint128,uint256,uint256,uint64)"))
            || selector == bytes4(keccak256("increase(uint256,uint128,uint256,uint256,uint64)"))
            || selector == bytes4(keccak256("burn(uint256,uint128,uint256,uint256,uint64)"))
            || selector == bytes4(keccak256("collect(uint256)"))
            || selector == bytes4(keccak256("trade((bytes32,bool,uint128,uint160,uint256,uint32,uint64,bool))"))
            || selector == bytes4(keccak256("placeOrder(bytes32,bool,int24,uint128,uint64)"))
            || selector == bytes4(keccak256("cancelOrder(uint256,uint128)"))
            || selector == bytes4(keccak256("cancelRemaining(uint256)"))
            || selector == bytes4(keccak256("updateOrders(bytes32,bytes,uint64)"))
            || selector == bytes4(keccak256("claimOrder(uint256)"))
            || selector == bytes4(keccak256("replaceOrder(uint256,int24,uint128,uint64)"));
    }
}
