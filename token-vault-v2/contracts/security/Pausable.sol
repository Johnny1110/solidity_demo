// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/VaultStorage.sol";
import "../access/AccessControl.sol";
import "../libraries/Errors.sol";

/**
 * @title Pausable
 * @notice Emergency pause mechanism
 * 
 * WHY PAUSE FUNCTIONALITY?
 * Smart contracts are immutable, but exploits happen. When you detect:
 * - Active exploit in progress
 * - Critical bug in contract logic
 * - Malicious token draining vault
 * - Oracle manipulation attack
 * 
 * You need a CIRCUIT BREAKER to stop the bleeding.
 * 
 * THEORY: Circuit Breaker Pattern
 * Borrowed from electrical engineering:
 * - Normal operation: Circuit closed (current flows)
 * - Overload detected: Circuit opens (stops current)
 * - Problem fixed: Circuit can be closed again
 * 
 * In smart contracts:
 * - Normal: Functions execute
 * - Emergency: Functions blocked
 * - Fixed: Resume operations
 * 
 * REAL WORLD EXAMPLES:
 * 
 * 1. Poly Network (2021): $611M hack
 *    - No pause functionality
 *    - Hacker drained funds for hours
 *    - Team could only watch helplessly
 *    - Eventually hacker returned funds (rare!)
 * 
 * 2. Compound (2021): $80M bug
 *    - Had pause functionality
 *    - Immediately paused contract
 *    - Prevented further losses
 *    - Fixed bug and resumed
 * 
 * 3. Nomad Bridge (2022): $190M stolen
 *    - No pause mechanism
 *    - Bug allowed anyone to withdraw
 *    - Hundreds of people drained bridge
 *    - Complete loss
 * 
 * PAUSE CONSIDERATIONS:
 * 
 * 1. What should be pausable?
 *    ✓ Deposits (prevent more funds at risk)
 *    ✓ Withdrawals (if exploit uses withdrawals)
 *    ✗ Emergency withdrawals (users need escape hatch)
 * 
 * 2. Who can pause?
 *    - Admin: For confirmed exploits
 *    - Pauser role: For suspicious activity (low threshold)
 *    - Automated monitors: For detected patterns
 * 
 * 3. Who can unpause?
 *    - Only admin (requires careful review)
 *    - Not pausers (prevents accidental unpause)
 *    - Possibly governance vote (decentralized)
 * 
 * 4. Should pause be time-limited?
 *    - Some protocols auto-unpause after X hours
 *    - Prevents indefinite freeze
 *    - But might unpause during active exploit!
 */
contract Pausable is VaultStorage, AccessControl {
    
    // ========== Events ==========
    
    /**
     * WHY EMIT EVENTS FOR PAUSE/UNPAUSE?
     * - dApps can detect and show warnings to users
     * - Monitoring services can alert team
     * - Transparent audit trail (who paused when)
     * - Can trigger off-chain incident response
     */
    event Paused(address indexed account, uint256 timestamp);
    event Unpaused(address indexed account, uint256 timestamp);
    
    // ========== Modifiers ==========
    
    /**
     * Prevent function execution when paused
     * 
     * PATTERN: Guard clause
     * Check precondition first, fail fast
     * Saves gas when paused (no further execution)
     */
    modifier whenNotPaused() {
        if (paused) {
            revert ContractPaused();
        }
        _;
    }
    
    /**
     * Only allow function when paused
     * Use case: Unpause function, emergency recovery
     */
    modifier whenPaused() {
        if (!paused) {
            revert ContractNotPaused();
        }
        _;
    }
    
    // ========== Admin Functions ==========
    
    /**
     * Pause all pausable operations
     * 
     * SECURITY: Requires PAUSER_ROLE
     * Why separate from ADMIN?
     * - Lower threshold for pausing (act fast)
     * - Can give to monitoring bots
     * - Limits blast radius if key compromised
     * 
     * THEORY: Fail-safe defaults
     * - Pausing should be easy (prevent damage)
     * - Unpausing should be hard (ensure safety)
     * This asymmetry is intentional!
     */
    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        paused = true;
        emit Paused(msg.sender, block.timestamp);
    }
    
    /**
     * Unpause and resume normal operations
     * 
     * SECURITY: Requires ADMIN_ROLE (higher bar than pausing)
     * Why?
     * - Unpausing might reopen exploit
     * - Need careful review before resuming
     * - Should verify fix is deployed/confirmed
     * 
     * PROCESS:
     * 1. Exploit detected → PAUSER pauses immediately
     * 2. Team investigates root cause
     * 3. Deploy fix (if possible via upgrade)
     * 4. Test fix thoroughly
     * 5. ADMIN unpauses after confirmation
     * 
     * Time between pause/unpause: Hours to days
     */
    function unpause() external onlyAdmin whenPaused {
        paused = false;
        emit Unpaused(msg.sender, block.timestamp);
    }
    
    /**
     * Check if contract is paused
     * Public view for UI/dApps
     */
    function isPaused() external view returns (bool) {
        return paused;
    }
}

/**
 * PAUSE STRATEGY FRAMEWORK:
 * 
 * Level 1: Monitoring (Detection)
 * - Watch for unusual transactions
 * - Monitor token balances vs deposits
 * - Track abnormal gas usage patterns
 * - Alert on large withdrawals
 * 
 * Level 2: Automated Response (Prevention)
 * - Bot with PAUSER_ROLE
 * - Pause if: balance mismatch detected
 * - Pause if: withdrawal > X% of TVL in Y minutes
 * - Pause if: suspected flash loan attack pattern
 * 
 * Level 3: Human Review (Verification)
 * - On-call engineer reviews pause
 * - Determine if false positive
 * - If real: Begin incident response
 * - If false: ADMIN unpauses quickly
 * 
 * Level 4: Recovery (Remediation)
 * - Identify root cause
 * - Deploy fix (if upgradeable)
 * - Test fix on testnet
 * - Announce timeline to community
 * - Unpause after verification
 * 
 * TRADE-OFFS:
 * 
 * Pros of Pausable:
 * ✓ Stops active exploits
 * ✓ Buys time for fix
 * ✓ Limits damage
 * ✓ Restores user confidence
 * 
 * Cons of Pausable:
 * ✗ Centralization risk (admin control)
 * ✗ Could be abused to censor users
 * ✗ False positives block legitimate users
 * ✗ Dependence on monitoring
 * 
 * MITIGATION:
 * - Time-lock pause decisions (24h notice)
 * - Multi-sig for unpause (requires M of N)
 * - Governance vote for extended pause
 * - Always allow emergency withdrawals
 * 
 * ADVANCED: Granular Pausing
 * Instead of all-or-nothing:
 * 
 * pauseDeposits() - Stop new deposits
 * pauseWithdrawals() - Stop withdrawals
 * pauseToken(address token) - Pause specific token
 * 
 * Allows surgical response:
 * - If exploit uses deposits: Pause deposits only
 * - If malicious token: Pause that token only
 * - Users can still withdraw safe tokens
 */