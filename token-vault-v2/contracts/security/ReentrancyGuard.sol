// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/VaultStorage.sol";
import "../libraries/Errors.sol";

/**
 * @title ReentrancyGuard
 * @notice Prevents reentrancy attacks
 * 
 * WHAT IS REENTRANCY?
 * An attack where a malicious contract calls back into your contract
 * during an external call, before the first call completes.
 * 
 * FAMOUS EXAMPLE: The DAO Hack (2016)
 * - Attacker called withdraw()
 * - Contract sent ETH to attacker
 * - Attacker's fallback called withdraw() AGAIN
 * - Balance wasn't updated yet, so second withdraw succeeded
 * - Attacker drained $60 million
 * - Led to Ethereum hard fork
 * 
 * THEORY: Why can this happen?
 * When contract A calls contract B:
 * 1. A's execution pauses
 * 2. Control transfers to B
 * 3. B can call back into A
 * 4. A resumes from pause point
 * 
 * If A's state isn't updated before calling B, B sees old state!
 * 
 * DEFENSE STRATEGIES:
 * 1. Checks-Effects-Interactions (CEI) pattern
 * 2. Reentrancy guard (mutex lock)
 * 3. Pull over push (user initiates withdrawals)
 * 
 * WHY USE BOTH CEI AND GUARD?
 * - CEI prevents single-function reentrancy
 * - Guard prevents cross-function reentrancy
 * - Defense in depth: Multiple security layers
 * 
 * Example cross-function reentrancy:
 * 1. Attacker calls withdraw()
 * 2. withdraw() sends tokens
 * 3. Token's transfer calls attacker's hook
 * 4. Attacker calls deposit() (different function!)
 * 5. deposit() reads attacker's balance (not yet updated)
 * 6. State inconsistency exploited
 */
contract ReentrancyGuard is VaultStorage {
    
    /**
     * REENTRANCY STATUS VALUES
     * 
     * WHY USE 1 AND 2 INSTEAD OF 0 AND 1?
     * Gas optimization!
     * 
     * THEORY: EVM storage costs
     * - Zero → Non-zero: 20,000 gas (SSTORE initial)
     * - Non-zero → Non-zero: 5,000 gas (SSTORE update)
     * - Non-zero → Zero: 5,000 gas + 15,000 gas refund
     * 
     * Using 0/1 pattern:
     * - First call: 0 → 1 = 20,000 gas
     * - Exit: 1 → 0 = 20,000 gas (with refund)
     * - Second call: 0 → 1 = 20,000 gas again!
     * 
     * Using 1/2 pattern:
     * - First call: 1 → 2 = 5,000 gas
     * - Exit: 2 → 1 = 5,000 gas
     * - Second call: 1 → 2 = 5,000 gas
     * 
     * Saves 15,000 gas per call!
     * 
     * The initialization sets status to 1 (not entered state)
     */
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    
    /**
     * REENTRANCY GUARD MODIFIER
     * 
     * HOW IT WORKS:
     * 1. Check status is NOT_ENTERED
     * 2. Set status to ENTERED
     * 3. Execute function
     * 4. Set status back to NOT_ENTERED
     * 
     * If reentrant call occurs:
     * - Status is ENTERED from first call
     * - Second call checks status
     * - Status == ENTERED, so revert!
     * 
     * VISUALIZATION:
     * 
     * Normal flow:
     * [NOT_ENTERED] → function starts → [ENTERED] → executes → [NOT_ENTERED]
     * 
     * Reentrancy attack:
     * [NOT_ENTERED] → function1 starts → [ENTERED]
     *   ↓ external call
     *   ↓ attacker calls function2
     *   [ENTERED] → REVERT! (status is already ENTERED)
     * 
     * IMPORTANT: Modifier order matters!
     * modifier onlyOwner nonReentrant { ... } ✓ Correct
     * modifier nonReentrant onlyOwner { ... } ✗ Wrong (checks status after auth check)
     * 
     * Why? Modifiers execute in order, and you want:
     * 1. Check authorization first (fail fast, save gas)
     * 2. Then check reentrancy
     * 3. Then execute function
     */
    modifier nonReentrant() {
        // Check: Ensure not already entered
        if (reentrancyStatus == _ENTERED) {
            revert ReentrancyDetected();
        }
        
        // Effect: Mark as entered
        reentrancyStatus = _ENTERED;
        
        // Interaction: Execute function body
        _;
        
        // Effect: Mark as not entered (cleanup)
        reentrancyStatus = _NOT_ENTERED;
    }
    
    /**
     * Initialize reentrancy status
     * Must be called during contract initialization
     * 
     * WHY NEEDED FOR UPGRADEABLE CONTRACTS?
     * - Constructors don't work with proxies
     * - Proxy uses delegatecall, so constructor runs in implementation context
     * - Implementation's storage != Proxy's storage
     * - Must use initialize() function to set initial state in proxy
     */
    function _initReentrancyGuard() internal {
        reentrancyStatus = _NOT_ENTERED;
    }
    
    /**
     * ADVANCED: Read-only reentrancy protection
     * 
     * WHAT IS READ-ONLY REENTRANCY?
     * - Attacker doesn't modify state
     * - But reads inconsistent state during external call
     * - Can exploit view functions that read partially-updated state
     * 
     * Example attack:
     * 1. Vault has tokens worth $1M
     * 2. User withdraws $500K
     * 3. During transfer, token balance updates but deposits mapping doesn't
     * 4. Attacker calls TVL view function
     * 5. TVL reads: tokens = $500K, deposits = $1M
     * 6. Attacker sees "extra" $500K that doesn't exist
     * 7. Uses this in flash loan attack or oracle manipulation
     * 
     * DEFENSE: Protect view functions too
     * Some protocols use this, but adds gas cost to reads
     * Tradeoff: Security vs gas efficiency
     */
    modifier nonReentrantView() {
        if (reentrancyStatus == _ENTERED) {
            revert ReentrancyDetected();
        }
        _;
        // Note: Don't change status (view function should be read-only)
    }
    
    /**
     * Get current reentrancy status (for debugging/monitoring)
     */
    function getReentrancyStatus() external view returns (bool entered) {
        return reentrancyStatus == _ENTERED;
    }
}

/**
 * REAL WORLD REENTRANCY EXAMPLES:
 * 
 * 1. The DAO (2016): $60M stolen
 *    - withdraw() sent ETH before updating balance
 *    - Attacker's fallback called withdraw() again
 *    
 * 2. Cream Finance (2021): $130M stolen
 *    - Flash loan + reentrancy on borrow/repay
 *    - Cross-function reentrancy exploited
 *    
 * 3. Grim Finance (2021): $30M stolen
 *    - Reentrancy during vault deposit
 *    - Inflated shares calculation exploited
 *    
 * 4. Curve Finance (2023): Read-only reentrancy
 *    - Used reentrancy to manipulate price oracle
 *    - No state modified, but read inconsistent state
 * 
 * LESSONS:
 * - CEI pattern alone isn't enough
 * - Need explicit reentrancy guards
 * - Protect both state-changing AND view functions
 * - Test with malicious contracts, not just normal tokens
 * - Audits must include reentrancy scenarios
 * 
 * TESTING REENTRANCY:
 * Create MaliciousToken.sol that:
 * 1. Implements ERC20
 * 2. In transfer(), calls back into vault
 * 3. Attempts to exploit vault functions
 * 
 * If tests pass with MaliciousToken, guard works!
 * 
 * EXAMPLE MALICIOUS TOKEN:
 * 
 * contract MaliciousToken is ERC20 {
 *     IVault public targetVault;
 *     address public attacker;
 *     
 *     function transfer(address to, uint amount) public override returns (bool) {
 *         // Normal transfer
 *         _transfer(msg.sender, to, amount);
 *         
 *         // Malicious reentrancy attempt
 *         if (msg.sender == address(targetVault) && to == attacker) {
 *             // Try to withdraw again!
 *             try targetVault.withdraw(address(this), amount) {
 *                 // If this succeeds, vault is vulnerable!
 *             } catch {
 *                 // If this reverts with ReentrancyDetected, guard works!
 *             }
 *         }
 *         
 *         return true;
 *     }
 * }
 * 
 * COMPREHENSIVE REENTRANCY PROTECTION CHECKLIST:
 * 
 * ✓ Use CEI pattern (Checks-Effects-Interactions)
 * ✓ Apply nonReentrant modifier to all state-changing functions
 * ✓ Consider nonReentrantView for critical view functions
 * ✓ Test with malicious tokens that attempt reentrancy
 * ✓ Test cross-function reentrancy scenarios
 * ✓ Test read-only reentrancy scenarios
 * ✓ Verify modifier order (auth checks before reentrancy)
 * ✓ Use pull over push pattern for payments
 * ✓ Audit all external calls
 * ✓ Consider using ReentrancyGuard from OpenZeppelin
 * 
 * WHEN TO USE EACH PATTERN:
 * 
 * CEI Pattern: Always, everywhere
 * - Fundamental best practice
 * - Zero gas overhead
 * - Prevents most basic reentrancy
 * 
 * ReentrancyGuard: State-changing functions
 * - deposit(), withdraw(), etc.
 * - ~2,100 gas overhead per call
 * - Prevents cross-function reentrancy
 * 
 * nonReentrantView: Critical view functions only
 * - getTVL(), getPrice(), etc. if used in DeFi protocols
 * - Minimal gas overhead (just a check)
 * - Prevents oracle manipulation
 * 
 * Pull over Push: Payment distributions
 * - Fee collection, reward distribution
 * - No gas overhead (user pays their own gas)
 * - Prevents reentrancy in distribution logic
 * 
 * COMBINATION EXAMPLE (BEST PRACTICE):
 * 
 * function withdraw(address token, uint amount) 
 *     external 
 *     whenNotPaused          // 1. Check system state
 *     onlyRole(USER_ROLE)    // 2. Check authorization
 *     nonReentrant           // 3. Check reentrancy
 * {
 *     // CHECKS
 *     require(balance[msg.sender] >= amount, "Insufficient balance");
 *     
 *     // EFFECTS (update state BEFORE external call)
 *     balance[msg.sender] -= amount;
 *     totalBalance -= amount;
 *     
 *     // INTERACTIONS (external call comes LAST)
 *     token.transfer(msg.sender, amount);
 * }
 * 
 * This combines:
 * - Pause protection (system-level safety)
 * - Authorization (access control)
 * - Reentrancy guard (attack prevention)
 * - CEI pattern (best practice)
 * 
 * = Defense in Depth ✓
 */