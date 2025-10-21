// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VaultStorage
 * @notice Centralized storage for upgradeable vault
 * 
 * WHY SEPARATE STORAGE CONTRACT?
 * - Upgradeable contracts must maintain consistent storage layout
 * - Adding variables in wrong order = storage collision = lost funds
 * - This pattern makes storage layout explicit and auditable
 * 
 * THEORY: Storage Slots in Proxy Pattern
 * When using proxy pattern:
 * 1. Proxy holds storage, implementation holds logic
 * 2. delegatecall executes implementation code in proxy's context
 * 3. Storage slot numbers must NEVER change between versions
 * 
 * Storage collision example:
 * V1: deposits at slot 0, owner at slot 1
 * V2 (wrong): newFeature at slot 0, deposits at slot 1, owner at slot 2
 * Result: deposits overwrite newFeature's data!
 * 
 * STORAGE GAP PATTERN:
 * Reserve slots for future variables. If V2 adds features, uses gap space.
 * This is why all storage contracts end with __gap array.
 */
contract VaultStorage {
    
    // ========== Constants ==========
    // Constants don't use storage slots (inlined in bytecode)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_FEE = 1000; // 10%
    
    // ========== Core Storage ==========
    
    /**
     * User deposits: user => token => amount
     * Storage cost: ~20,000 gas for new slot, ~5,000 for update
     * 
     * WHY NESTED MAPPING?
     * Alternative: mapping(bytes32 => uint256) with keccak256(user, token)
     * Pro: Single mapping, cleaner
     * Con: Manual key computation, easy to mess up
     * Winner: Nested mapping (compiler handles hashing, safer)
     */
    mapping(address => mapping(address => uint256)) public deposits;
    
    /**
     * Total deposits per token (for TVL tracking)
     * Alternative: Calculate by iterating users
     * Why store separately? Can't iterate mappings on-chain!
     */
    mapping(address => uint256) public totalDepositsPerToken;
    
    /**
     * Token whitelist
     * Why whitelist? Prevents scam tokens, malicious ERC20s
     */
    mapping(address => bool) public whitelistedTokens;
    
    // ========== Fee Configuration ==========
    
    /**
     * Struct packing optimization
     * BEFORE: 4 slots = 8,000 gas per access
     * AFTER: 2 slots = 4,000 gas per access
     * 
     * THEORY: EVM storage slots
     * - Each slot = 256 bits (32 bytes)
     * - address = 160 bits (20 bytes)
     * - uint64 = 64 bits (8 bytes)
     * - bool = 8 bits (1 byte)
     * Total: 160 + 64 + 64 + 8 = 296 bits → needs 2 slots
     * 
     * Compiler packs sequentially, so order matters:
     * [address(160) + uint64(64) + uint32(32)] fits in 256 bits ✓
     * [uint64 + address + uint32] needs 3 slots ✗ (address breaks alignment)
     */
    struct FeeConfig {
        address feeRecipient;      // Slot N (160 bits)
        uint64 depositFeeBps;      // Slot N (64 bits) - 224 bits total
        uint64 withdrawFeeBps;     // Slot N+1 (64 bits) - starts new slot
        bool exemptFromFees;       // Slot N+1 (8 bits)
        // 184 bits used in second slot, 72 bits remaining unused
    }
    
    /**
     * Token-specific fee configurations
     */
    mapping(address => FeeConfig) public feeConfigs;
    
    /**
     * Default fee config for tokens without specific settings
     */
    FeeConfig public defaultFeeConfig;
    
    /**
     * User-specific fee discounts (in basis points)
     * Use case: VIP users, governance token holders, protocols
     */
    mapping(address => uint256) public feeDiscounts;
    
    /**
     * Collected fees waiting to be claimed
     * WHY SEPARATE FROM DEPOSITS?
     * - Clear accounting (user funds vs protocol revenue)
     * - Can't accidentally withdraw fees as user deposits
     * - Easy audit trail
     */
    mapping(address => uint256) public collectedFees;
    
    // ========== Access Control Storage ==========
    
    /**
     * Role-based access control
     * THEORY: Roles as bytes32
     * - Roles are keccak256 hashes: keccak256("ADMIN_ROLE")
     * - Why? Prevents collisions, clear naming, gas-efficient
     * 
     * Structure: role => account => hasRole
     * This allows multiple accounts per role and multiple roles per account
     */
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    /**
     * Track admin count (prevents accidentally removing all admins)
     * Critical: Must always have at least one admin!
     */
    uint256 public adminCount;
    
    // ========== Security Storage ==========
    
    /**
     * Reentrancy guard state
     * THEORY: Uses 1/2 pattern instead of 0/1 for gas efficiency
     * - Writing to non-zero costs 5,000 gas
     * - Writing to zero costs 20,000 gas first time
     * - By using 1/2, we avoid zero→non-zero transition
     */
    uint256 public reentrancyStatus;
    
    /**
     * Pause state for emergency stops
     */
    bool public paused;
    
    // ========== Initialization ==========
    
    /**
     * Track initialization to prevent double-init
     * WHY NEEDED? Proxies don't use constructors!
     * - Constructor runs during implementation deployment
     * - But proxy uses its own storage, so constructor state is lost
     * - Must use initialize() function called after proxy deployment
     */
    bool public initialized;
    
    /**
     * Contract version (for tracking upgrades)
     */
    uint256 public version;
    
    // ========== Storage Gap ==========
    
    /**
     * CRITICAL: Storage gap for future variables
     * 
     * WHY 50 SLOTS?
     * - Current version uses ~15 slots
     * - 50 slots = room for ~35 new features
     * - Standard practice (OpenZeppelin uses 50)
     * 
     * HOW TO USE IN UPGRADES:
     * V1: uint256[50] private __gap;
     * V2: mapping(address => uint256) newFeature;
     *     uint256[49] private __gap;  // Reduced by 1
     * 
     * NEVER:
     * - Reorder existing variables
     * - Change variable types
     * - Remove variables
     * 
     * ALWAYS:
     * - Append new variables
     * - Reduce gap by number of slots used
     * - Document changes in upgrade notes
     * 
     * THEORY: Why storage collisions are catastrophic
     * Example disaster scenario:
     * V1: deposits at slot 5
     * V2: Add variable without gap, pushes deposits to slot 6
     * Result: All user balances read from wrong slot = appears as zero
     * Users can't withdraw! Funds effectively locked forever.
     */
    uint256[50] private __gap;
}