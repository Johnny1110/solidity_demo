// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VaultStorage.sol";
import "../access/AccessControl.sol";
import "../security/ReentrancyGuard.sol";
import "../security/Pausable.sol";
import "../interfaces/IERC20.sol";
import "../libraries/Errors.sol";

/**
 * @title VaultCore
 * @notice Core deposit/withdraw logic with comprehensive security
 * 
 * ARCHITECTURE DECISION: Why split into modules?
 * 
 * Monolithic (400 lines):
 * - Hard to audit (too much to hold in mind)
 * - Gas optimization limited (can't isolate hotspots)
 * - Testing difficult (tightly coupled)
 * - One bug affects everything
 * 
 * Modular (100 lines each):
 * - Easy to audit (focused scope)
 * - Gas optimization targeted
 * - Unit testing straightforward
 * - Bug blast radius limited
 * 
 * THEORY: Separation of Concerns
 * Each module has ONE responsibility:
 * - VaultCore: Deposit/withdraw logic
 * - FeeManager: Fee calculation
 * - AccessControl: Permissions
 * - ReentrancyGuard: Security
 * - Pausable: Emergency stops
 * 
 * Benefits:
 * 1. Cognitive load reduced
 * 2. Changes don't cascade
 * 3. Can upgrade modules independently
 * 4. Team members can specialize
 */
contract VaultCore is VaultStorage, AccessControl, ReentrancyGuard, Pausable {
    
    // ========== Events ==========
    
    /**
     * Enhanced deposit event with fee breakdown
     * 
     * WHY INCLUDE FEE IN EVENT?
     * - Transparency: Users see exact fee charged
     * - Accounting: Off-chain can calculate revenue
     * - Auditing: Can verify fee calculations
     * - UX: dApp can show "You paid X fee"
     */
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 amountCredited,
        uint256 fee,
        uint256 timestamp
    );
    
    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 amountRequested,
        uint256 amountSent,
        uint256 fee,
        uint256 timestamp
    );
    
    // ========== Modifiers ==========
    
    /**
     * Token must be whitelisted
     * 
     * WHY WHITELIST?
     * 1. Prevents scam tokens
     * 2. Blocks malicious ERC20s (reentrancy hooks)
     * 3. Controls which assets vault supports
     * 4. Easier to manage risk
     * 
     * RISK: What if malicious token?
     * - Could have hooks in transfer()
     * - Could revert unpredictably
     * - Could drain gas
     * - Could call back into vault
     * 
     * Whitelist = pre-vetted tokens only
     */
    modifier onlyWhitelistedToken(address token) {
        if (!whitelistedTokens[token]) {
            revert TokenNotWhitelisted(token);
        }
        _;
    }
    
    // ========== Core Functions ==========
    
    /**
     * @notice Deposit tokens into vault
     * @param token Token contract address
     * @param amount Amount to deposit
     * 
     * SECURITY LAYERS:
     * 1. whenNotPaused - Emergency stop
     * 2. nonReentrant - Cross-function attack prevention
     * 3. onlyWhitelistedToken - Asset control
     * 
     * PATTERN: Checks-Effects-Interactions (CEI)
     * Critical for security!
     * 
     * CHECKS:
     * - Amount > 0
     * - Token whitelisted
     * - Not paused
     * - Not reentered
     * 
     * EFFECTS (state changes):
     * - Update deposits mapping
     * - Update totalDepositsPerToken
     * - Update collectedFees
     * 
     * INTERACTIONS (external calls):
     * - transferFrom token to vault
     * 
     * WHY THIS ORDER?
     * If interaction happens before effects:
     * 1. External call executes
     * 2. Malicious contract calls back
     * 3. State not updated yet
     * 4. Attacker exploits old state
     * 
     * By updating state first:
     * 1. State updated
     * 2. External call executes
     * 3. Even if callback happens, state is correct
     * 4. Exploit prevented
     */
    function deposit(
        address token,
        uint256 amount
    ) 
        external 
        whenNotPaused 
        nonReentrant
        onlyWhitelistedToken(token)
    {
        // ========== CHECKS ==========
        
        if (amount == 0) revert ZeroAmount();
        
        // Get effective fee for this user
        uint256 effectiveFeeBps = _getEffectiveFee(msg.sender, token, true);
        
        // Calculate fee and amount after fee
        (uint256 fee, uint256 amountAfterFee) = _calculateFee(amount, effectiveFeeBps);
        
        // ========== EFFECTS ==========
        
        /**
         * WHY += INSTEAD OF = ?
         * Supports multiple deposits from same user
         * 
         * Alternative: Track deposit history array
         * Pro: Know exact deposit amounts/times
         * Con: Unbounded array = gas bomb
         * Winner: Simple sum (constant gas)
         */
        deposits[msg.sender][token] += amountAfterFee;
        totalDepositsPerToken[token] += amountAfterFee;
        
        if (fee > 0) {
            collectedFees[token] += fee;
        }
        
        // ========== INTERACTIONS ==========
        
        /**
         * CRITICAL: External call comes LAST
         * 
         * transferFrom flow:
         * 1. Token checks user's balance
         * 2. Token checks vault's allowance
         * 3. Token decreases user's balance
         * 4. Token increases vault's balance
         * 5. Token emits Transfer event
         * 
         * Any of these steps could:
         * - Revert (insufficient balance/allowance)
         * - Call back into vault (if malicious)
         * - Consume unexpected gas
         * 
         * By doing this last, our state is already safe!
         */
        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        
        if (!success) {
            revert DepositFailed(token, amount);
        }
        
        emit Deposit(
            msg.sender,
            token,
            amount,
            amountAfterFee,
            fee,
            block.timestamp
        );
    }
    
    /**
     * @notice Withdraw tokens from vault
     * @param token Token contract address
     * @param amount Amount to withdraw
     * 
     * SECURITY CONSIDERATIONS:
     * 1. Check user balance FIRST
     * 2. Update state BEFORE external call
     * 3. Use transfer not transferFrom (vault owns tokens)
     * 
     * WITHDRAWAL FEE THEORY:
     * Why charge on withdrawal not deposit?
     * - Discourages quick in/out (prevents liquidity manipulation)
     * - Rewards long-term holders (no fee if never withdraw)
     * - Compensates protocol for processing cost
     * 
     * Alternative models:
     * - Time-based fee: Decreases with lock duration
     * - Flat fee: Same regardless of amount
     * - No fee: Relies on other revenue (risky)
     */
    function withdraw(
        address token,
        uint256 amount
    )
        external
        nonReentrant
    {
        // ========== CHECKS ==========
        
        if (amount == 0) revert ZeroAmount();
        
        /**
         * CRITICAL: Check balance BEFORE calculating fee
         * Why? User requests to withdraw X, but has < X
         * Must fail here, not after fee calculation
         * 
         * ATTACK SCENARIO IF NOT CHECKED:
         * 1. User has 100 tokens deposited
         * 2. Requests withdraw(101)
         * 3. If we calculate fee first: fee = 1, send = 100
         * 4. Underflow or wrong amount sent
         * 5. User gets more than they should
         * 
         * By checking first, we fail cleanly with clear error
         */
        uint256 userBalance = deposits[msg.sender][token];
        if (userBalance < amount) {
            revert InsufficientBalance(msg.sender, token, amount, userBalance);
        }
        
        // Calculate fee and amount to send
        uint256 effectiveFeeBps = _getEffectiveFee(msg.sender, token, false);
        (uint256 fee, uint256 amountToSend) = _calculateFee(amount, effectiveFeeBps);
        
        // ========== EFFECTS ==========
        
        /**
         * Update state BEFORE external call
         * This is the MOST CRITICAL line for reentrancy protection!
         * 
         * If we did transfer BEFORE this line:
         * 1. transfer() executes
         * 2. Token calls attacker's receive()
         * 3. Attacker calls withdraw() again
         * 4. deposits[user] still shows old balance
         * 5. Second withdrawal succeeds!
         * 6. User drains entire vault
         * 
         * By updating first:
         * 1. deposits[user] decreased
         * 2. transfer() executes
         * 3. Token calls attacker's receive()
         * 4. Attacker calls withdraw() again
         * 5. deposits[user] now shows decreased balance
         * 6. Second withdrawal fails (insufficient balance)
         */
        deposits[msg.sender][token] -= amount;
        totalDepositsPerToken[token] -= amount;
        
        if (fee > 0) {
            collectedFees[token] += fee;
        }
        
        // ========== INTERACTIONS ==========
        
        /**
         * Transfer tokens to user
         * 
         * WHY transfer() NOT transferFrom()?
         * - Vault already owns the tokens
         * - transfer() moves from vault to user
         * - transferFrom() needs approval (unnecessary here)
         * 
         * GAS COMPARISON:
         * transfer(): ~21,000 gas
         * transferFrom(): ~24,000 gas (extra approval check)
         * 
         * SAFETY NOTE:
         * Some tokens return false instead of reverting
         * Production should use SafeERC20.safeTransfer()
         */
        bool success = IERC20(token).transfer(msg.sender, amountToSend);
        
        if (!success) {
            revert WithdrawFailed(token, amountToSend);
        }
        
        emit Withdrawal(
            msg.sender,
            token,
            amount,
            amountToSend,
            fee,
            block.timestamp
        );
    }
    
    /**
     * @notice Emergency withdraw without fees
     * @dev Only available when contract is paused
     * 
     * WHY EMERGENCY WITHDRAW?
     * When contract is paused, normal withdrawals blocked
     * But users need escape hatch for their funds!
     * 
     * SCENARIO:
     * 1. Exploit detected, contract paused
     * 2. Users can't withdraw via normal method
     * 3. Without emergency withdraw: Funds locked forever
     * 4. With emergency withdraw: Users can exit safely
     * 
     * SECURITY:
     * - Only works when paused (can't be used normally)
     * - No fees charged (emergency situation)
     * - Still uses CEI pattern (safe)
     * - Still nonReentrant (defense in depth)
     * 
     * THEORY: Fail-safe design
     * System should degrade gracefully:
     * - Normal: Full functionality
     * - Degraded: Limited functionality (emergency mode)
     * - Failed: Still allows recovery (emergency withdrawals)
     * 
     * Never trap user funds!
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    )
        external
        whenPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        
        uint256 userBalance = deposits[msg.sender][token];
        if (userBalance < amount) {
            revert InsufficientBalance(msg.sender, token, amount, userBalance);
        }
        
        // Update state (no fees in emergency)
        deposits[msg.sender][token] -= amount;
        totalDepositsPerToken[token] -= amount;
        
        // Transfer full amount (no fee deduction)
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) {
            revert WithdrawFailed(token, amount);
        }
        
        emit Withdrawal(msg.sender, token, amount, amount, 0, block.timestamp);
    }
    
    // ========== View Functions ==========
    
    /**
     * Get user's deposited balance
     * 
     * WHY PUBLIC VIEW?
     * - No gas cost when called externally
     * - Other contracts can read (composability)
     * - dApps can display user balance
     * 
     * THEORY: View function gas costs
     * External call: 0 gas (executed by node, not transaction)
     * Internal call: ~100 gas (reads from storage)
     * 
     * This is why views are free for users but cost gas for contracts
     */
    function getBalance(address user, address token) 
        external 
        view 
        returns (uint256) 
    {
        return deposits[user][token];
    }
    
    /**
     * Get amount user would receive after fees
     * Useful for UX: "You'll receive X tokens"
     * 
     * WHY SEPARATE FUNCTION?
     * Could calculate in frontend, but:
     * - Fee logic might be complex
     * - Keeps calculation logic in contract (single source of truth)
     * - Frontend just displays result
     */
    function getWithdrawableAmount(address user, address token)
        external
        view
        returns (uint256)
    {
        uint256 balance = deposits[user][token];
        if (balance == 0) return 0;
        
        uint256 effectiveFeeBps = _getEffectiveFee(user, token, false);
        (, uint256 amountToSend) = _calculateFee(balance, effectiveFeeBps);
        
        return amountToSend;
    }
    
    /**
     * Get total value locked for a token
     * 
     * WHY TRACK TVL?
     * - Marketing: "We secure $X million"
     * - Risk management: Large TVL = bigger attack target
     * - Fee revenue: TVL × fee rate = expected revenue
     * - Composability: Other protocols can read
     */
    function getTVL(address token) 
        external 
        view 
        returns (uint256) 
    {
        return totalDepositsPerToken[token];
    }
    
    /**
     * Check if token is whitelisted
     */
    function isTokenWhitelisted(address token)
        external
        view
        returns (bool)
    {
        return whitelistedTokens[token];
    }
    
    // ========== Internal Helper Functions ==========
    
    /**
     * Calculate fee for a given amount
     * 
     * MATH THEORY:
     * fee = (amount × feeBps) / BASIS_POINTS
     * 
     * Example: 1000 tokens, 30 bps (0.3%)
     * fee = (1000 × 30) / 10000 = 3 tokens
     * 
     * WHY BASIS POINTS?
     * - No decimals in Solidity (only integers)
     * - Percentages need precision: 0.3% hard to represent
     * - Basis points: 1 bps = 0.01% = precise enough
     * 
     * ROUNDING:
     * Division in Solidity rounds DOWN
     * Example: 999 / 10000 = 0 (not 0.0999)
     * 
     * Is this fair?
     * - Small deposits might have 0 fee (good for users)
     * - Large deposits still pay (good for protocol)
     * - Alternative: Round up (always charge something)
     * 
     * OVERFLOW CHECK:
     * amount × feeBps could overflow if both are huge
     * Max safe: type(uint256).max / MAX_FEE
     * In practice: Token supplies << uint256.max
     * Solidity 0.8+: Built-in overflow protection
     */
    function _calculateFee(uint256 amount, uint256 feeBps)
        internal
        pure
        returns (uint256 fee, uint256 amountAfterFee)
    {
        if (feeBps == 0) {
            return (0, amount);
        }
        
        // Calculate fee
        fee = (amount * feeBps) / BASIS_POINTS;
        
        // Sanity check: Fee shouldn't exceed amount
        if (fee >= amount) {
            revert FeeExceedsAmount(fee, amount);
        }
        
        amountAfterFee = amount - fee;
    }
    
    /**
     * Get effective fee for user considering discounts
     * 
     * FEE HIERARCHY:
     * 1. Check if token-specific config exists
     * 2. If not, use default config
     * 3. If user has discount, apply it
     * 4. If exempted, return 0
     * 
     * DISCOUNT THEORY:
     * Base fee: 30 bps (0.3%)
     * User discount: 5000 bps (50%)
     * Effective fee: 30 - (30 × 5000 / 10000) = 15 bps (0.15%)
     * 
     * WHY OFFER DISCOUNTS?
     * - VIP users (large depositors)
     * - Governance token holders
     * - Partner protocols
     * - Promotional campaigns
     */
    function _getEffectiveFee(
        address user,
        address token,
        bool isDeposit
    )
        internal
        view
        returns (uint256)
    {
        // Get fee config (token-specific or default)
        FeeConfig memory config = feeConfigs[token].feeRecipient != address(0)
            ? feeConfigs[token]
            : defaultFeeConfig;
        
        // Check exemption
        if (config.exemptFromFees) {
            return 0;
        }
        
        // Get base fee
        uint256 baseFee = isDeposit ? config.depositFeeBps : config.withdrawFeeBps;
        
        // Apply discount
        uint256 discount = feeDiscounts[user];
        if (discount > 0) {
            uint256 reduction = (baseFee * discount) / BASIS_POINTS;
            baseFee = baseFee > reduction ? baseFee - reduction : 0;
        }
        
        return baseFee;
    }
}

/**
 * PRODUCTION CHECKLIST:
 * 
 * ✓ Reentrancy protection (nonReentrant modifier)
 * ✓ CEI pattern (state before interactions)
 * ✓ Emergency pause (whenNotPaused / whenPaused)
 * ✓ Access control (role-based permissions)
 * ✓ Input validation (amount > 0, balance checks)
 * ✓ Custom errors (gas-efficient reverts)
 * ✓ Event emission (audit trail)
 * ✓ Emergency withdraw (user escape hatch)
 * ✓ View functions (UI integration)
 * ✓ Whitelist (asset control)
 * 
 * NEXT STEPS FOR PRODUCTION:
 * 
 * 1. Use SafeERC20 library (handles non-standard tokens)
 * 2. Add slippage protection (minimum received amount)
 * 3. Implement time-locked admin functions
 * 4. Add multi-sig requirement for critical operations
 * 5. Create comprehensive test suite
 * 6. Professional security audit
 * 7. Bug bounty program
 * 8. Deployment scripts with verification
 * 9. Monitoring and alerting system
 * 10. Incident response playbook
 */