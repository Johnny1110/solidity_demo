// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Errors
 * @notice Custom errors for gas-efficient reverts
 * 
 * WHY CUSTOM ERRORS?
 * - 50% cheaper than require strings (~50 gas vs ~100 gas)
 * - Smaller contract bytecode (cheaper deployment)
 * - Can include parameters for debugging
 * - Industry standard since Solidity 0.8.4
 * 
 * THEORY: Error selectors
 * - Errors use 4-byte selector (like function signatures)
 * - Example: ZeroAmount() → keccak256("ZeroAmount()")[0:4]
 * - ABI decoders can parse parameters from error data
 */

// ========== General Errors ==========
error ZeroAmount();
error ZeroAddress();
error InvalidAddress(address provided);
error Unauthorized(address caller, bytes32 requiredRole);

// ========== Vault Errors ==========
error InsufficientBalance(address user, address token, uint256 requested, uint256 available);
error TokenNotWhitelisted(address token);
error TokenAlreadyWhitelisted(address token);
error InvalidTokenAddress(address token);
error DepositFailed(address token, uint256 amount);
error WithdrawFailed(address token, uint256 amount);

// ========== Fee Errors ==========
error FeeExceedsMaximum(uint256 provided, uint256 maximum);
error FeeExceedsAmount(uint256 fee, uint256 amount);
error InvalidFeeRecipient();
error NoFeesToCollect(address token);

// ========== Access Control Errors ==========
error MissingRole(address account, bytes32 role);
error RoleAlreadyGranted(address account, bytes32 role);
error CannotRenounceLastAdmin();

// ========== Security Errors ==========
error ContractPaused();
error ContractNotPaused();
error ReentrancyDetected();
error InvalidInitialization();
error AlreadyInitialized();

// ========== Upgrade Errors ==========
error InvalidImplementation(address implementation);
error UpgradeNotAuthorized(address caller);
error StorageSlotCollision(bytes32 slot);