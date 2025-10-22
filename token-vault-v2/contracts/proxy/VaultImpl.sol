// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/VaultCore.sol";
import "../libraries/Errors.sol";

/**
 * @title VaultImplementation
 * @notice UUPS upgradeable implementation of TokenVault
 * 
 * UUPS PATTERN THEORY:
 * In UUPS (Universal Upgradeable Proxy Standard):
 * - Proxy is minimal (just forwards calls)
 * - Implementation contains upgrade logic
 * - Implementation validates who can upgrade
 * 
 * WHY PUT UPGRADE LOGIC IN IMPLEMENTATION?
 * Transparent Proxy: Upgrade logic in proxy
 * - Every call checks "is this admin?"
 * - Costs ~1000 gas per call
 * - Admin calls handled differently than user calls
 * 
 * UUPS: Upgrade logic in implementation
 * - Proxy just forwards (no checks)
 * - Saves ~1000 gas per call
 * - All calls treated the same
 * 
 * At scale (millions of transactions):
 * - UUPS saves 1000 gas × 1M = 1B gas
 * - At 50 gwei, 30 ETH, that's $100K+ saved!
 * 
 * TRADEOFF:
 * - Must remember to include upgrade function in every version
 * - If V2 forgets upgrade(), you're stuck on V2 forever
 * - Requires discipline and testing
 * 
 * INITIALIZATION PATTERN:
 * 
 * Normal contracts: Use constructor
 * ```
 * constructor(address _owner) {
 *     owner = _owner;
 * }
 * ```
 * 
 * Proxy contracts: Use initialize() function
 * Why? Constructor runs during implementation deployment
 * But implementation's constructor state doesn't transfer to proxy!
 * 
 * Flow:
 * 1. Deploy Implementation (constructor runs, but doesn't matter)
 * 2. Deploy Proxy pointing to Implementation
 * 3. Call proxy.initialize() → delegatecalls to implementation.initialize()
 * 4. Initialize() runs in proxy's context, setting proxy's storage
 * 
 * CRITICAL: Prevent double initialization
 * Without protection:
 * - Attacker calls initialize() again
 * - Resets admin to attacker
 * - Attacker now controls contract
 * 
 * Solution: initialized flag
 */
contract VaultImplementation is VaultCore {
    
    /**
     * IMPLEMENTATION VERSION
     * Track which version is deployed
     * Useful for:
     * - Verification: "Are we running V2?"
     * - Analytics: "How many users on each version?"
     * - Safety: "Don't downgrade from V3 to V2"
     */
    uint256 public constant VERSION = 1;
    
    /**
     * DISABLE IMPLEMENTATION CONSTRUCTOR
     * 
     * WHY DISABLE?
     * Implementation contract shouldn't be used directly!
     * - Users should use proxy
     * - Direct use bypasses proxy's storage
     * - Could cause confusion
     * 
     * _disableInitializers() from OpenZeppelin:
     * - Prevents initialize() from being called on implementation
     * - Only works on proxy (via delegatecall)
     * 
     * Security: Prevents implementation from being initialized and controlled
     */
    constructor() {
        // Mark implementation as initialized to prevent direct use
        initialized = true;
    }
    
    /**
     * @notice Initialize the vault (replaces constructor)
     * @param admin Initial admin address
     * @param defaultFeeRecipient Where fees go by default
     * 
     * INITIALIZER PATTERN:
     * 1. Check not already initialized
     * 2. Set initialized = true
     * 3. Initialize all inherited contracts
     * 4. Set up roles and configuration
     * 
     * ORDER MATTERS:
     * - Check initialized first (prevent re-init)
     * - Set initialized early (prevent reentrancy)
     * - Initialize base contracts (dependencies first)
     * - Set up roles (authorization last)
     * 
     * WHY THIS ORDER?
     * If initialize() is called during initialize():
     * - First check catches it (already initialized)
     * - Reentrancy prevented
     */
    function initialize(
        address admin,
        address defaultFeeRecipient
    ) external {
        // CHECKS
        if (initialized) revert AlreadyInitialized();
        if (admin == address(0)) revert ZeroAddress();
        if (defaultFeeRecipient == address(0)) revert ZeroAddress();
        
        // EFFECTS - Mark as initialized FIRST (reentrancy protection)
        initialized = true;
        version = VERSION;
        
        // Initialize inherited contracts
        _initReentrancyGuard();
        
        // Set up default fee configuration
        defaultFeeConfig = FeeConfig({
            feeRecipient: defaultFeeRecipient,
            depositFeeBps: 0,      // 0% deposit fee
            withdrawFeeBps: 30,    // 0.3% withdrawal fee
            exemptFromFees: false
        });
        
        // Grant admin role
        // This creates the first admin "from nothing"
        // Uses _setupRole (internal) not grantRole (needs admin)
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        
        // Admin also gets all operational roles initially
        // Can delegate these roles to others later
        _setupRole(OPERATOR_ROLE, admin);
        _setupRole(FEE_MANAGER_ROLE, admin);
        _setupRole(PAUSER_ROLE, admin);
        _setupRole(UPGRADER_ROLE, admin);
    }
    
    /**
     * @notice Upgrade to new implementation
     * @param newImplementation Address of new implementation contract
     * 
     * UPGRADE AUTHORIZATION:
     * Only UPGRADER_ROLE can upgrade
     * Why separate role?
     * - Separation of duties (upgrader ≠ fee manager)
     * - Can use multi-sig for upgrades
     * - Can use timelock for upgrade delays
     * 
     * UPGRADE SAFETY CHECKS:
     * 1. Caller has UPGRADER_ROLE
     * 2. New implementation is a contract (not EOA)
     * 3. New implementation is different from current
     * 
     * CRITICAL: What makes a valid implementation?
     * - Must inherit from same base (compatible storage)
     * - Must include upgradeTo() function (or stuck forever!)
     * - Must not reorder storage variables
     * - Must not change variable types
     * 
     * THEORY: Why upgrades are dangerous
     * Storage layout must match EXACTLY:
     * 
     * V1: deposits at slot 5
     * V2: deposits at slot 6 (added var before it)
     * Result: V2 reads wrong slot, all balances corrupted!
     * 
     * Prevention:
     * - Use storage gaps
     * - Never reorder variables
     * - Use tools like OpenZeppelin Upgrades plugin
     * - Test upgrade on testnet first
     */
    function upgradeTo(address newImplementation) public onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) {
            revert InvalidImplementation(newImplementation);
        }
        
        // Get current implementation from proxy storage
        address currentImplementation = _getImplementation();
        if (currentImplementation == newImplementation) {
            revert("Already on this implementation");
        }
        
        // Update implementation in proxy storage
        _setImplementation(newImplementation);
    }
    
    /**
     * @notice Upgrade and call initialization on new implementation
     * @param newImplementation New implementation address
     * @param data Calldata to pass to new implementation's initializer
     * 
     * USE CASE:
     * V2 adds new feature that needs setup
     * Instead of:
     * 1. upgradeTo(V2)
     * 2. call V2.setupNewFeature()
     * 
     * Do atomically:
     * upgradeToAndCall(V2, abi.encodeWithSignature("setupNewFeature()"))
     * 
     * WHY ATOMIC?
     * - No gap where contract is upgraded but not configured
     * - No one can front-run setup
     * - Cleaner, safer
     * 
     * SECURITY NOTE:
     * The 'data' parameter is dangerous!
     * - Can call ANY function on new implementation
     * - Must trust UPGRADER_ROLE completely
     * - Consider requiring data to call specific function only
     */
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external onlyRole(UPGRADER_ROLE) {
        // First upgrade
        upgradeTo(newImplementation);
        
        // Then call initialization on new implementation
        // Uses delegatecall so runs in proxy's context
        if (data.length > 0) {
            (bool success, bytes memory returndata) = newImplementation.delegatecall(data);
            if (!success) {
                // Bubble up revert reason
                if (returndata.length > 0) {
                    assembly {
                        let returndata_size := mload(returndata)
                        revert(add(32, returndata), returndata_size)
                    }
                } else {
                    revert("Initialization failed");
                }
            }
        }
    }
    
    // ========== Internal Helper Functions ==========
    
    /**
     * Get implementation address from proxy storage
     * 
     * WHY INTERNAL VIEW?
     * - Used by upgrade functions only
     * - No need to expose externally
     * - Reads from specific storage slot
     * 
     * IMPLEMENTATION SLOT:
     * Standard EIP-1967 slot: keccak256("eip1967.proxy.implementation") - 1
     * This ensures no collision with logical storage
     */
    function _getImplementation() internal view returns (address impl) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly {
            impl := sload(slot)
        }
    }
    
    /**
     * Set new implementation address in proxy storage
     * 
     * CRITICAL: This is where upgrade actually happens!
     * Writing to IMPLEMENTATION_SLOT changes which contract
     * the proxy delegates to.
     * 
     * After this write:
     * - All future calls use new implementation
     * - Storage remains unchanged
     * - Proxy address stays the same
     * 
     * EVENT EMISSION:
     * Emitted at proxy level (not implementation level)
     * Because it's a proxy-level change
     */
    function _setImplementation(address newImplementation) internal {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly {
            sstore(slot, newImplementation)
        }
        
        // Emit event (EIP-1967 standard)
        emit Upgraded(newImplementation);
    }
    
    /**
     * Event defined for upgrade
     */
    event Upgraded(address indexed implementation);
}

/**
 * UPGRADE EXAMPLE WALKTHROUGH:
 * 
 * === INITIAL DEPLOYMENT ===
 * 
 * 1. Deploy VaultImplementationV1
 *    Address: 0xAAA (implementation contract)
 *    Storage: Empty (constructor runs but doesn't matter)
 * 
 * 2. Deploy VaultProxy(0xAAA, adminAddress)
 *    Address: 0xBBB (proxy contract)
 *    Storage: IMPLEMENTATION_SLOT = 0xAAA
 * 
 * 3. Call 0xBBB.initialize(admin, feeRecipient)
 *    Flow: Proxy.fallback() → delegatecall(0xAAA.initialize)
 *    Result: Proxy's storage initialized (deposits, roles, etc.)
 * 
 * 4. Users interact with 0xBBB forever
 *    Every call: 0xBBB delegates to 0xAAA
 * 
 * === UPGRADE TO V2 ===
 * 
 * 5. Deploy VaultImplementationV2
 *    Address: 0xCCC (new implementation)
 *    New feature: Add stakingRewards mapping
 *    Storage layout: Same as V1, plus new variables in gap
 * 
 * 6. Call 0xBBB.upgradeTo(0xCCC)
 *    Flow: Proxy.fallback() → delegatecall(0xAAA.upgradeTo)
 *    Effect: Proxy's IMPLEMENTATION_SLOT = 0xCCC
 * 
 * 7. Now all calls use V2
 *    Every call: 0xBBB delegates to 0xCCC
 *    Storage: Same storage, new logic!
 * 
 * 8. Old deposits still work
 *    deposits[user][token] at same slot
 *    V2 reads them correctly
 * 
 * === WHAT USERS SEE ===
 * 
 * Before upgrade: Interact with 0xBBB (uses V1 logic)
 * After upgrade: Interact with 0xBBB (uses V2 logic)
 * 
 * Key point: Users NEVER change address!
 * - No migration needed
 * - No token approvals needed
 * - Seamless transition
 * 
 * === STORAGE LAYOUT V1 vs V2 ===
 * 
 * V1 Storage:
 * Slot 0-9: Core vault variables (deposits, etc.)
 * Slot 10-59: __gap (50 slots reserved)
 * 
 * V2 Storage:
 * Slot 0-9: Core vault variables (SAME positions!)
 * Slot 10: stakingRewards (uses first gap slot)
 * Slot 11-59: __gap (49 slots remaining)
 * 
 * This is why gaps are critical!
 * 
 * === TESTING CHECKLIST ===
 * 
 * Before deploying V2:
 * ✓ Deploy V1 on testnet
 * ✓ Make test deposits
 * ✓ Record all balances
 * ✓ Deploy V2 on testnet
 * ✓ Upgrade V1 proxy to V2
 * ✓ Verify old balances readable
 * ✓ Test V2 new features
 * ✓ Try all V1 functions still work
 * ✓ Check events emit correctly
 * ✓ Verify storage layout with tools
 * ✓ Run gas comparison
 * ✓ Security audit V2
 * ✓ Simulate on mainnet fork
 * ✓ Multi-sig test upgrade process
 * ✓ Document upgrade in changelog
 * 
 * === EMERGENCY CONSIDERATIONS ===
 * 
 * What if V2 has a critical bug?
 * - Can upgrade to V2.1 (fixed version)
 * - Can upgrade back to V1 (rollback)
 * - Can upgrade to EmergencyMode contract (pause all)
 * 
 * What if upgrade function is broken?
 * - This is catastrophic (stuck forever)
 * - Prevention: Test upgradeTo() works in V2 before deploying
 * - Include admin override in proxy (rarely used)
 * 
 * What if storage is corrupted?
 * - Usually can't fix (storage is permanent)
 * - Prevention: Thorough testing and audits
 * - Mitigation: Emergency pause, manual compensation
 * 
 * === GOVERNANCE CONSIDERATIONS ===
 * 
 * Who should control upgrades?
 * 
 * Option 1: Multi-sig (3-of-5, 5-of-9, etc.)
 * Pro: Fast response to bugs
 * Con: Centralized, trust required
 * 
 * Option 2: Timelock (24-48 hour delay)
 * Pro: Users can exit if they disagree
 * Con: Slow response to exploits
 * 
 * Option 3: Governance vote (token holders)
 * Pro: Fully decentralized
 * Con: Very slow, low participation
 * 
 * Best practice: Combination
 * - Multi-sig with timelock for upgrades
 * - Governance can veto upgrades
 * - Emergency multi-sig for critical bugs (no timelock)
 * - Gradual decentralization over time
 * 
 * === REAL WORLD EXAMPLES ===
 * 
 * Compound V3: UUPS proxy
 * - Upgrader role is governance
 * - 2-day timelock on upgrades
 * - Emergency admin can pause
 * 
 * Aave V3: UUPS proxy
 * - Multiple proxies (pool, config, etc.)
 * - Governance controls upgrades
 * - Guardian can pause
 * 
 * Uniswap V2: No proxy (immutable)
 * - Can't upgrade
 * - Had to deploy V3 separately
 * - Users migrated manually
 * 
 * Lessons: Upgradeability provides flexibility but requires careful governance
 */