// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/Errors.sol";
import "../core/VaultStorage.sol";

/**
 * @title AccessControl
 * @notice Role-based access control system
 * 
 * WHY ROLE-BASED ACCESS CONTROL (RBAC)?
 * Single owner pattern problems:
 * 1. One key controls everything (single point of failure)
 * 2. Can't delegate specific permissions (all or nothing)
 * 3. Key compromise = total loss
 * 4. Can't have operational roles (bot addresses, etc.)
 * 
 * RBAC Benefits:
 * 1. Separation of duties: Fee manager ≠ emergency admin
 * 2. Key segregation: Bot can call operator functions only
 * 3. Audit trail: Know exactly who can do what
 * 4. Flexibility: Add/remove permissions without redeployment
 * 
 * THEORY: How roles work
 * - Roles are 32-byte identifiers (usually keccak256 of name)
 * - Each role can have multiple accounts
 * - Each account can have multiple roles
 * - Roles can grant other roles (role hierarchy)
 * 
 * Common pattern: DEFAULT_ADMIN_ROLE can grant/revoke all roles
 */
contract AccessControl is VaultStorage {
    
    // ========== Role Definitions ==========
    
    /**
     * Role keccak256 hashes
     * WHY keccak256?
     * - Guaranteed unique (collision probability ~0)
     * - Gas-efficient (computed at compile time)
     * - Human-readable in events/errors
     * 
     * Alternative: Simple uint256 increments (0, 1, 2...)
     * Problem: Easy to accidentally reuse numbers
     */
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00; // Special: Can grant any role
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // ========== Events ==========
    
    /**
     * WHY INDEXED PARAMETERS?
     * - Up to 3 indexed params per event (4 topics total)
     * - Topic 0: Event signature
     * - Topics 1-3: Indexed params (can filter by these)
     * - Data: Non-indexed params (cheaper but not searchable)
     * 
     * Gas costs:
     * - Indexed: 375 gas per topic
     * - Non-indexed: 8 gas per byte
     * 
     * Rule of thumb: Index addresses/IDs you'll search by
     */
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );
    
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );
    
    // ========== Modifiers ==========
    
    /**
     * Check if caller has required role
     * 
     * WHY CUSTOM ERROR INSTEAD OF REQUIRE?
     * require(hasRole(role, msg.sender), "Missing role");
     * - Stores string in bytecode: ~50 bytes
     * - Runtime cost: ~100 gas
     * 
     * Custom error:
     * - 4-byte selector only: 4 bytes
     * - Runtime cost: ~50 gas
     * - Can include dynamic data for debugging!
     */
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) {
            revert MissingRole(msg.sender, role);
        }
        _;
    }
    
    /**
     * Admin-only modifier
     * Used for critical operations
     */
    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert MissingRole(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        _;
    }
    
    // ========== View Functions ==========
    
    /**
     * Check if account has role
     * 
     * THEORY: Mapping lookup cost
     * - Cold access: 2100 gas (first access in transaction)
     * - Warm access: 100 gas (subsequent accesses)
     * - Why? EVM caches storage slots during transaction
     */
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return roles[role][account];
    }
    
    /**
     * Check if account has ANY role
     * Useful for UI (check if address has any permissions)
     */
    function hasAnyRole(address account) public view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account) ||
               hasRole(OPERATOR_ROLE, account) ||
               hasRole(FEE_MANAGER_ROLE, account) ||
               hasRole(PAUSER_ROLE, account) ||
               hasRole(UPGRADER_ROLE, account);
    }
    
    // ========== Admin Functions ==========
    
    /**
     * Grant role to account
     * 
     * SECURITY: Only admin can grant roles
     * EXCEPTION: Admins can grant admin to others (allows key rotation)
     * 
     * PATTERN: Check-Effect-Event
     * 1. Check: Verify caller has permission
     * 2. Effect: Update state
     * 3. Event: Emit for off-chain tracking
     */
    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        if (hasRole(role, account)) revert RoleAlreadyGranted(account, role);
        
        _grantRole(role, account);
    }
    
    /**
     * Revoke role from account
     * 
     * CRITICAL: Can't revoke last admin!
     * Why? Would brick the contract (no one could grant roles)
     * 
     * PATTERN: Defensive programming
     * Always validate critical invariants before state changes
     */
    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (!hasRole(role, account)) revert MissingRole(account, role);
        
        // Prevent removing last admin
        if (role == DEFAULT_ADMIN_ROLE) {
            if (adminCount <= 1) revert CannotRenounceLastAdmin();
        }
        
        _revokeRole(role, account);
    }
    
    /**
     * Renounce own role
     * 
     * WHY ALLOW RENOUNCING?
     * - Bot key rotation: Old key renounces, new key granted
     * - Security: Compromised key can lock itself out
     * - Accountability: Someone leaving project can renounce
     * 
     * SECURITY: Only msg.sender can renounce their own roles
     * Prevents: Admin maliciously revoking operator's access
     */
    function renounceRole(bytes32 role) external {
        if (!hasRole(role, msg.sender)) revert MissingRole(msg.sender, role);
        
        // Prevent removing last admin
        if (role == DEFAULT_ADMIN_ROLE) {
            if (adminCount <= 1) revert CannotRenounceLastAdmin();
        }
        
        _revokeRole(role, msg.sender);
    }
    
    /**
     * Batch grant roles
     * WHY BATCH?
     * - Initial setup: Grant multiple roles to multiple addresses
     * - Gas efficiency: Amortize fixed costs across operations
     * - UX: One transaction instead of many
     * 
     * THEORY: Batch operations
     * Fixed costs: 21,000 gas base transaction cost
     * Variable costs: ~20,000 per role grant
     * 
     * Single transactions: 21k + 20k = 41k each → 410k for 10 grants
     * Batch transaction: 21k + (20k × 10) = 221k for 10 grants
     * Savings: ~47% gas reduction!
     */
    function batchGrantRoles(
        bytes32[] calldata roleList,
        address[] calldata accounts
    ) external onlyAdmin {
        if (roleList.length != accounts.length) revert("Array length mismatch");
        
        for (uint256 i = 0; i < roleList.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            if (!hasRole(roleList[i], accounts[i])) {
                _grantRole(roleList[i], accounts[i]);
            }
        }
    }
    
    // ========== Internal Functions ==========
    
    /**
     * Internal grant role logic
     * Separated for reusability (called by both grantRole and initialize)
     * 
     * WHY INTERNAL?
     * - Can't be called externally (security)
     * - Can be called by inheriting contracts
     * - Saves gas vs public (no external call overhead)
     */
    function _grantRole(bytes32 role, address account) internal {
        roles[role][account] = true;
        
        // Track admin count for safety check
        if (role == DEFAULT_ADMIN_ROLE) {
            adminCount++;
        }
        
        emit RoleGranted(role, account, msg.sender);
    }
    
    /**
     * Internal revoke role logic
     */
    function _revokeRole(bytes32 role, address account) internal {
        roles[role][account] = false;
        
        // Decrease admin count
        if (role == DEFAULT_ADMIN_ROLE) {
            adminCount--;
        }
        
        emit RoleRevoked(role, account, msg.sender);
    }
    
    /**
     * Setup initial admin
     * Called during initialization only
     * 
     * WHY SEPARATE FUNCTION?
     * - Initialization needs to grant admin without checks
     * - Regular grantRole requires caller to be admin (chicken-egg problem)
     * - This creates the first admin "from nothing"
     */
    function _setupRole(bytes32 role, address account) internal {
        if (!hasRole(role, account)) {
            _grantRole(role, account);
        }
    }
}