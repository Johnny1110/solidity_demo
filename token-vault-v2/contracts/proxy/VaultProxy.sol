// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VaultProxy (UUPS Pattern)
 * @notice Upgradeable proxy for TokenVault
 * 
 * WHAT IS A PROXY?
 * A proxy is a contract that forwards calls to another contract (implementation).
 * Users interact with proxy, proxy delegates to implementation.
 * 
 * WHY USE PROXIES?
 * Smart contracts are immutable once deployed. Proxies solve this by:
 * - Proxy holds state (storage)
 * - Implementation holds logic (code)
 * - Can swap implementation while keeping same proxy address
 * - Users never need to migrate
 * 
 * THEORY: delegatecall
 * Normal call: ContractA.call(ContractB) → runs in B's context
 * Delegatecall: ContractA.delegatecall(ContractB) → runs in A's context
 * 
 * Context includes:
 * - msg.sender (preserved)
 * - msg.value (preserved)
 * - Storage (uses caller's storage)
 * 
 * Visualization:
 * User → Proxy → delegatecall → Implementation
 *         ↓ (uses proxy's storage)
 *         Storage
 * 
 * PROXY PATTERNS COMPARISON:
 * 
 * 1. Transparent Proxy (older, used by many projects)
 *    - Admin calls go to proxy
 *    - User calls go to implementation
 *    - Upgrade logic in proxy
 *    Pro: Simpler mental model
 *    Con: More expensive (gas overhead on every call)
 *    
 * 2. UUPS (Universal Upgradeable Proxy Standard)
 *    - All calls go to implementation
 *    - Upgrade logic in implementation
 *    - Proxy is minimal (just forwards)
 *    Pro: Cheaper (~1000 gas saved per call)
 *    Con: Must remember to include upgrade logic in implementation
 *    
 * 3. Diamond (EIP-2535)
 *    - Multiple implementations (facets)
 *    - Each facet handles different functions
 *    - Complex but very flexible
 *    Pro: Can upgrade specific modules
 *    Con: Extremely complex, overkill for most cases
 * 
 * WHY UUPS FOR THIS PROJECT?
 * - Gas efficiency matters (users pay per transaction)
 * - Simple upgrade needs (whole implementation, not modules)
 * - Industry standard (OpenZeppelin, Aave, Compound)
 * - Easier to audit (less proxy logic)
 * 
 * CRITICAL STORAGE LAYOUT RULES:
 * 1. Implementation slot MUST be at consistent location
 * 2. Never reorder variables in upgrades
 * 3. Never change variable types
 * 4. Never delete variables
 * 5. Only append new variables
 * 
 * Violation = storage collision = lost funds!
 */
contract VaultProxy {
    
    /**
     * IMPLEMENTATION STORAGE SLOT
     * 
     * Why this specific slot?
     * - EIP-1967 standard: keccak256("eip1967.proxy.implementation") - 1
     * - Random slot prevents collision with logical storage
     * - Minus 1 ensures not zero (gas optimization)
     * 
     * THEORY: Storage collision prevention
     * Normal variables: Sequential slots starting at 0
     * Proxy variables: Random slot (keccak256 hash)
     * 
     * Example collision scenario (if not careful):
     * Proxy: implementation at slot 0
     * Implementation: deposits at slot 0
     * Result: implementation address overwritten with deposit data!
     * 
     * Solution: Use random slot for proxy variables
     */
    bytes32 private constant IMPLEMENTATION_SLOT = 
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    
    /**
     * ADMIN STORAGE SLOT
     * Who can upgrade the proxy
     * 
     * Note: In UUPS, upgrade logic is in implementation
     * But proxy still tracks admin for safety
     */
    bytes32 private constant ADMIN_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    
    // ========== Events ==========
    
    /**
     * EIP-1967 standard events
     * Block explorers watch for these
     * 
     * WHY EMIT FROM PROXY?
     * - Implementation changes are proxy-level events
     * - Should be visible at proxy address
     * - Tools like Etherscan detect these automatically
     */
    event Upgraded(address indexed implementation);
    event AdminChanged(address previousAdmin, address newAdmin);
    
    /**
     * CONSTRUCTOR
     * 
     * Sets initial implementation and admin
     * 
     * IMPORTANT: Constructor runs at proxy deployment
     * But implementation's constructor doesn't affect proxy!
     * This is why we need initialize() pattern
     * 
     * Flow:
     * 1. Deploy Implementation contract
     * 2. Deploy Proxy(implementation address)
     * 3. Call initialize() on proxy address
     * 4. Initialize delegatecalls to implementation's initialize()
     */
    constructor(address implementation, address admin) {
        _setImplementation(implementation);
        _setAdmin(admin);
    }
    
    /**
     * FALLBACK FUNCTION
     * 
     * This is the HEART of the proxy pattern!
     * 
     * When any function called on proxy:
     * 1. Fallback catches the call
     * 2. Loads implementation address
     * 3. Delegates call to implementation
     * 4. Returns implementation's return data
     * 
     * THEORY: How fallback works
     * - Executes when no function matches
     * - In proxy, NO function matches (proxy has minimal interface)
     * - So ALL calls hit fallback
     * - Fallback forwards to implementation
     * 
     * ASSEMBLY EXPLANATION:
     * Why assembly? Need low-level control for delegatecall
     * 
     * calldatacopy(t, f, s):
     *   - Copy calldata from position f
     *   - To memory position t
     *   - Copy s bytes
     * 
     * delegatecall(g, a, in, insize, out, outsize):
     *   - Call address a
     *   - With gas g
     *   - Input from memory at in (size insize)
     *   - Output to memory at out (size outsize)
     *   - Returns 0 on failure, 1 on success
     * 
     * returndatacopy(t, f, s):
     *   - Copy return data from position f
     *   - To memory position t
     *   - Copy s bytes
     * 
     * return(p, s):
     *   - Return data from memory at p (size s)
     * 
     * revert(p, s):
     *   - Revert with data from memory at p (size s)
     */
    fallback() external payable {
        address impl = _implementation();
        
        assembly {
            // Copy calldata to memory
            // calldatasize() = length of msg.data
            // 0x0 = memory position to copy to
            calldatacopy(0, 0, calldatasize())
            
            // Delegatecall to implementation
            // gas() = remaining gas
            // impl = implementation address
            // 0x0 = input data position in memory
            // calldatasize() = input data size
            // 0x0 = output data position
            // 0x0 = output data size (unknown yet)
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            
            // Copy return data to memory
            // returndatasize() = length of return data
            returndatacopy(0, 0, returndatasize())
            
            // Check if call succeeded
            switch result
            // If delegatecall failed (result = 0)
            case 0 {
                // Revert with return data
                revert(0, returndatasize())
            }
            // If delegatecall succeeded (result = 1)
            default {
                // Return with return data
                return(0, returndatasize())
            }
        }
    }
    
    /**
     * Receive function for ETH transfers
     * Some protocols send ETH to vault (though this one doesn't need it)
     */
    receive() external payable {}
    
    /**
     * Get current implementation address
     * Public so anyone can verify which version is active
     */
    function implementation() external view returns (address) {
        return _implementation();
    }
    
    /**
     * Get current admin address
     */
    function admin() external view returns (address) {
        return _admin();
    }
    
    // ========== Internal Functions ==========
    
    /**
     * Load implementation from storage slot
     * 
     * ASSEMBLY: Why not just read state variable?
     * We're using non-standard storage slot
     * Solidity doesn't support this directly
     * Must use assembly to read specific slot
     */
    function _implementation() internal view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            impl := sload(slot)
        }
    }
    
    /**
     * Load admin from storage slot
     */
    function _admin() internal view returns (address adm) {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            adm := sload(slot)
        }
    }
    
    /**
     * Set implementation address
     * 
     * SECURITY: Must verify implementation is contract
     * Why? If set to EOA or non-contract, all calls fail!
     */
    function _setImplementation(address newImplementation) private {
        require(
            newImplementation.code.length > 0,
            "Implementation must be contract"
        );
        
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, newImplementation)
        }
        
        emit Upgraded(newImplementation);
    }
    
    /**
     * Set admin address
     */
    function _setAdmin(address newAdmin) private {
        require(newAdmin != address(0), "Admin cannot be zero");
        
        address previousAdmin = _admin();
        
        bytes32 slot = ADMIN_SLOT;
        assembly {
            sstore(slot, newAdmin)
        }
        
        emit AdminChanged(previousAdmin, newAdmin);
    }
}

/**
 * UPGRADE PROCESS:
 * 
 * 1. Deploy new implementation (V2)
 * 2. Call upgradeToAndCall() on proxy
 * 3. Proxy updates IMPLEMENTATION_SLOT
 * 4. All future calls use V2 logic
 * 5. V2 operates on same storage
 * 
 * STORAGE LAYOUT EXAMPLE:
 * 
 * V1 Storage:
 * Slot 0: deposits[user1][token1]
 * Slot 1: deposits[user1][token2]
 * Slot 2: totalDepositsPerToken[token1]
 * ...
 * Slot 50: __gap[0]
 * Slot 51: __gap[1]
 * ...
 * 
 * V2 Storage (correct):
 * Slot 0: deposits[user1][token1]  ← Same!
 * Slot 1: deposits[user1][token2]  ← Same!
 * Slot 2: totalDepositsPerToken[token1]  ← Same!
 * ...
 * Slot 50: newFeature  ← Uses gap space
 * Slot 51: __gap[0]  ← Gap shifted
 * ...
 * 
 * V2 Storage (WRONG - DON'T DO THIS):
 * Slot 0: newFeature  ← COLLISION!
 * Slot 1: deposits[user1][token1]  ← Shifted!
 * Slot 2: deposits[user1][token2]  ← Shifted!
 * Result: All data corrupted!
 * 
 * TESTING UPGRADES:
 * 1. Deploy V1, make some deposits
 * 2. Deploy V2
 * 3. Upgrade proxy to V2
 * 4. Verify old deposits still readable
 * 5. Test new features work
 * 6. Verify storage layout unchanged
 */