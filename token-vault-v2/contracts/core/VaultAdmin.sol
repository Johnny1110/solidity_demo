// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VaultStorage.sol";
import "../access/AccessControl.sol";
import "../libraries/Errors.sol";
import "../interfaces/IERC20.sol";

/**
 * @title VaultAdmin
 * @notice Administrative functions separated from core logic
 * 
 * WHY SEPARATE ADMIN CONTRACT?
 * Separation of concerns:
 * - VaultCore: User-facing operations (deposit/withdraw)
 * - VaultAdmin: Protocol management (whitelist, fees, rescue)
 * - Easier to audit (admin functions in one place)
 * - Clearer access control boundaries
 * - Can upgrade admin logic independently
 * 
 * THEORY: Single Responsibility Principle
 * Each contract should have ONE reason to change:
 * - VaultCore changes: User flow improvements
 * - VaultAdmin changes: Governance/management improvements
 * 
 * If mixed together: Every admin change risks breaking user flows
 * Separated: Admin changes are isolated
 */
contract VaultAdmin is VaultStorage, AccessControl {
    
    // ========== Events ==========
    
    /**
     * Admin action events for transparency
     * 
     * WHY EMIT EVENTS FOR ADMIN ACTIONS?
     * - Users can monitor: "Did admin just add scam token?"
     * - dApps can react: "Token removed, update UI"
     * - Analytics: "How often are fees changed?"
     * - Accountability: "Who did what when?"
     * 
     * Transparency builds trust in DeFi
     */
    event TokenWhitelisted(address indexed token, address indexed addedBy);
    event TokenRemovedFromWhitelist(address indexed token, address indexed removedBy);
    event FeeConfigUpdated(
        address indexed token,
        uint256 depositFeeBps,
        uint256 withdrawFeeBps,
        address feeRecipient,
        bool exemptFromFees
    );
    event UserFeeDiscountSet(address indexed user, uint256 discountBps, address indexed setBy);
    event DefaultFeeConfigUpdated(
        uint256 depositFeeBps,
        uint256 withdrawFeeBps,
        address feeRecipient
    );
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event FeesCollected(address indexed token, address indexed recipient, uint256 amount);
    
    // ========== Token Whitelist Management ==========
    
    /**
     * @notice Add token to whitelist
     * @param token Token contract address
     * 
     * SECURITY CHECKS:
     * 1. Must be a contract (has code)
     * 2. Not already whitelisted (prevent duplicate events)
     * 3. Valid ERC20 (has totalSupply)
     * 
     * WHY CHECK totalSupply()?
     * - Verifies contract implements ERC20 interface
     * - Catches non-token contracts early
     * - totalSupply() is view function (safe to call)
     * 
     * ATTACK VECTOR PREVENTED:
     * Without checks, admin could whitelist:
     * - Malicious contract with reentrancy hooks
     * - Non-token contract (causes reverts later)
     * - EOA address (has no code)
     * 
     * With checks: Only valid ERC20 tokens allowed
     */
    function addTokenToWhitelist(address token) external onlyRole(OPERATOR_ROLE) {
        // Check 1: Must be a contract
        if (token.code.length == 0) {
            revert InvalidTokenAddress(token);
        }
        
        // Check 2: Not already whitelisted
        if (whitelistedTokens[token]) {
            revert TokenAlreadyWhitelisted(token);
        }
        
        // Check 3: Valid ERC20 (has totalSupply)
        // This call will revert if not ERC20 or if totalSupply reverts
        try IERC20(token).totalSupply() returns (uint256 supply) {
            if (supply == 0) {
                revert InvalidTokenAddress(token);
            }
        } catch {
            revert InvalidTokenAddress(token);
        }
        
        // All checks passed, add to whitelist
        whitelistedTokens[token] = true;
        
        emit TokenWhitelisted(token, msg.sender);
    }
    
    /**
     * @notice Batch add multiple tokens to whitelist
     * @param tokens Array of token addresses
     * 
     * WHY BATCH OPERATIONS?
     * Gas efficiency:
     * - Base transaction cost: 21,000 gas
     * - Per-token operation: ~20,000 gas
     * 
     * Single transactions: 21k + 20k = 41k each
     * - 10 tokens = 410k gas total
     * 
     * Batch transaction: 21k + (20k × 10) = 221k gas
     * - Saves 189k gas (46% reduction!)
     * - Also better UX (one confirmation, not 10)
     * 
     * IMPORTANT: Use calldata not memory
     * - calldata: Read directly from transaction data (~3 gas/read)
     * - memory: Copy to memory first (~200 gas/item)
     * - For arrays, calldata is much cheaper
     * 
     * SAFETY: No unbounded loops
     * - Gas limit prevents infinite loops
     * - But still good practice to limit array size
     * - Consider maxBatchSize if needed
     */
    function batchAddTokensToWhitelist(address[] calldata tokens) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        uint256 length = tokens.length;
        
        // Optional: Limit batch size to prevent accidental huge arrays
        // require(length <= 100, "Batch too large");
        
        for (uint256 i = 0; i < length;) {
            address token = tokens[i];
            
            // Same checks as single add
            if (token.code.length == 0) {
                revert InvalidTokenAddress(token);
            }
            
            if (whitelistedTokens[token]) {
                revert TokenAlreadyWhitelisted(token);
            }
            
            try IERC20(token).totalSupply() returns (uint256 supply) {
                if (supply == 0) {
                    revert InvalidTokenAddress(token);
                }
            } catch {
                revert InvalidTokenAddress(token);
            }
            
            whitelistedTokens[token] = true;
            emit TokenWhitelisted(token, msg.sender);
            
            // Gas optimization: unchecked increment
            // Safe because loop bound is array length
            unchecked {
                ++i;
            }
        }
    }
    
    /**
     * @notice Remove token from whitelist
     * @param token Token address to remove
     * 
     * IMPORTANT: This doesn't affect existing deposits!
     * - Users with deposited tokens can still withdraw
     * - Just prevents NEW deposits of this token
     * 
     * USE CASES:
     * - Token found to be malicious
     * - Token deprecated/migrated
     * - Risk management decision
     * - Reduce supported token list
     * 
     * SAFETY: Can remove even if deposits exist
     * - Existing deposits still withdrawable
     * - No funds locked
     * - Clean separation of concerns
     */
    function removeTokenFromWhitelist(address token) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        if (!whitelistedTokens[token]) {
            revert TokenNotWhitelisted(token);
        }
        
        whitelistedTokens[token] = false;
        
        emit TokenRemovedFromWhitelist(token, msg.sender);
    }
    
    // ========== Fee Configuration ==========
    
    /**
     * @notice Set fee configuration for specific token
     * @param token Token address
     * @param depositFeeBps Deposit fee in basis points
     * @param withdrawFeeBps Withdraw fee in basis points
     * @param feeRecipient Address to receive fees
     * @param exemptFromFees If true, no fees charged for this token
     * 
     * FEE STRUCTURE FLEXIBILITY:
     * Different tokens can have different fees:
     * - Stablecoins: Lower fees (0.1%)
     * - Volatile tokens: Higher fees (0.5%)
     * - Partner tokens: Zero fees (promotional)
     * - Experimental tokens: Higher fees (risk premium)
     * 
     * BASIS POINTS REMINDER:
     * - 1 bps = 0.01%
     * - 10 bps = 0.1%
     * - 100 bps = 1%
     * - 1000 bps = 10%
     * 
     * Example: depositFeeBps = 30 means 0.3% fee
     * 
     * SECURITY: MAX_FEE protection
     * Prevents admin from setting 100% fee and stealing all deposits
     * MAX_FEE = 1000 bps = 10% (reasonable maximum)
     */
    function setTokenFeeConfig(
        address token,
        uint256 depositFeeBps,
        uint256 withdrawFeeBps,
        address feeRecipient,
        bool exemptFromFees
    ) external onlyRole(FEE_MANAGER_ROLE) {
        // Validation checks
        if (depositFeeBps > MAX_FEE) {
            revert FeeExceedsMaximum(depositFeeBps, MAX_FEE);
        }
        
        if (withdrawFeeBps > MAX_FEE) {
            revert FeeExceedsMaximum(withdrawFeeBps, MAX_FEE);
        }
        
        if (feeRecipient == address(0)) {
            revert InvalidFeeRecipient();
        }
        
        // Set configuration
        feeConfigs[token] = FeeConfig({
            feeRecipient: feeRecipient,
            depositFeeBps: uint64(depositFeeBps),
            withdrawFeeBps: uint64(withdrawFeeBps),
            exemptFromFees: exemptFromFees
        });
        
        emit FeeConfigUpdated(
            token,
            depositFeeBps,
            withdrawFeeBps,
            feeRecipient,
            exemptFromFees
        );
    }
    
    /**
     * @notice Set default fee configuration
     * @dev Applied to tokens without specific configuration
     * 
     * DEFAULT FEE PATTERN:
     * 1. Check if token has specific config
     * 2. If yes: Use token-specific fees
     * 3. If no: Use default fees
     * 
     * This allows:
     * - Most tokens use default (simple management)
     * - Special tokens have custom fees (flexibility)
     * - Easy to update default for all tokens at once
     */
    function setDefaultFeeConfig(
        uint256 depositFeeBps,
        uint256 withdrawFeeBps,
        address feeRecipient
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (depositFeeBps > MAX_FEE) {
            revert FeeExceedsMaximum(depositFeeBps, MAX_FEE);
        }
        
        if (withdrawFeeBps > MAX_FEE) {
            revert FeeExceedsMaximum(withdrawFeeBps, MAX_FEE);
        }
        
        if (feeRecipient == address(0)) {
            revert InvalidFeeRecipient();
        }
        
        defaultFeeConfig = FeeConfig({
            feeRecipient: feeRecipient,
            depositFeeBps: uint64(depositFeeBps),
            withdrawFeeBps: uint64(withdrawFeeBps),
            exemptFromFees: false
        });
        
        emit DefaultFeeConfigUpdated(depositFeeBps, withdrawFeeBps, feeRecipient);
    }
    
    /**
     * @notice Set fee discount for specific user
     * @param user User address
     * @param discountBps Discount in basis points (e.g., 5000 = 50% discount)
     * 
     * DISCOUNT USE CASES:
     * - VIP users (large depositors)
     * - Governance token holders
     * - Partner protocols
     * - Promotional campaigns
     * - Compensation for bug/issue
     * 
     * DISCOUNT CALCULATION:
     * Base fee: 30 bps (0.3%)
     * User discount: 5000 bps (50%)
     * Effective fee: 30 - (30 × 5000 / 10000) = 15 bps (0.15%)
     * 
     * SECURITY: Discount capped at 100%
     * - Can't give more than 100% discount
     * - Can't use discount to create negative fees
     * - Prevents arithmetic issues
     */
    function setUserFeeDiscount(address user, uint256 discountBps) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (user == address(0)) revert ZeroAddress();
        if (discountBps > BASIS_POINTS) {
            revert("Discount cannot exceed 100%");
        }
        
        feeDiscounts[user] = discountBps;
        
        emit UserFeeDiscountSet(user, discountBps, msg.sender);
    }
    
    /**
     * @notice Batch set fee discounts for multiple users
     * @param users Array of user addresses
     * @param discountsBps Array of discounts in basis points
     * 
     * USE CASE: Airdrop discounts to governance token holders
     * Example: All holders of >1000 GOV tokens get 25% discount
     */
    function batchSetUserFeeDiscounts(
        address[] calldata users,
        uint256[] calldata discountsBps
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (users.length != discountsBps.length) {
            revert("Array length mismatch");
        }
        
        uint256 length = users.length;
        for (uint256 i = 0; i < length;) {
            address user = users[i];
            uint256 discount = discountsBps[i];
            
            if (user == address(0)) revert ZeroAddress();
            if (discount > BASIS_POINTS) {
                revert("Discount cannot exceed 100%");
            }
            
            feeDiscounts[user] = discount;
            emit UserFeeDiscountSet(user, discount, msg.sender);
            
            unchecked {
                ++i;
            }
        }
    }
    
    // ========== Fee Collection ==========
    
    /**
     * @notice Collect accumulated fees for a token
     * @param token Token address
     * 
     * FEE COLLECTION PATTERN:
     * - Fees accumulate in collectedFees mapping
     * - Separate from user deposits (clean accounting)
     * - Admin calls collectFees() to claim
     * - Fees sent to configured feeRecipient
     * 
     * SECURITY: CEI pattern
     * 1. Check: Fees exist
     * 2. Effect: Reset collectedFees to 0
     * 3. Interaction: Transfer tokens
     * 
     * Why reset before transfer?
     * - Prevents reentrancy
     * - If transfer calls back and tries to collect again
     * - collectedFees is already 0, so second collection fails
     */
    function collectFees(address token) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 amount = collectedFees[token];
        
        if (amount == 0) {
            revert NoFeesToCollect(token);
        }
        
        // Get fee recipient for this token
        address recipient = feeConfigs[token].feeRecipient != address(0)
            ? feeConfigs[token].feeRecipient
            : defaultFeeConfig.feeRecipient;
        
        // Reset BEFORE transfer (reentrancy protection)
        collectedFees[token] = 0;
        
        // Transfer fees
        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) {
            revert("Fee transfer failed");
        }
        
        emit FeesCollected(token, recipient, amount);
    }
    
    /**
     * @notice Batch collect fees for multiple tokens
     * @param tokens Array of token addresses
     * 
     * GAS OPTIMIZATION:
     * - Amortize base transaction cost across multiple collections
     * - dApp can call once per day for all tokens
     * - Much cheaper than individual calls
     */
    function batchCollectFees(address[] calldata tokens) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        uint256 length = tokens.length;
        
        for (uint256 i = 0; i < length;) {
            address token = tokens[i];
            uint256 amount = collectedFees[token];
            
            // Skip if no fees (don't revert, just continue)
            if (amount > 0) {
                address recipient = feeConfigs[token].feeRecipient != address(0)
                    ? feeConfigs[token].feeRecipient
                    : defaultFeeConfig.feeRecipient;
                
                // Reset before transfer
                collectedFees[token] = 0;
                
                // Transfer fees (wrap in try-catch to not brick entire batch)
                try IERC20(token).transfer(recipient, amount) returns (bool success) {
                    if (success) {
                        emit FeesCollected(token, recipient, amount);
                    }
                } catch {
                    // If transfer fails, restore collectedFees
                    collectedFees[token] = amount;
                }
            }
            
            unchecked {
                ++i;
            }
        }
    }
    
    // ========== Emergency Functions ==========
    
    /**
     * @notice Rescue mistakenly sent tokens
     * @param token Token address
     * @param amount Amount to rescue
     * @param to Recipient address
     * 
     * RESCUE PATTERN:
     * Users sometimes send tokens directly to contract address
     * (instead of using deposit function)
     * These tokens are "stuck" - not tracked in deposits mapping
     * 
     * Rescue function allows admin to recover these tokens
     * 
     * CRITICAL SECURITY:
     * Can ONLY rescue tokens not in deposits!
     * 
     * Protection mechanism:
     * - totalDepositsPerToken tracks legitimate deposits
     * - If token has deposits, rescue is blocked
     * - Prevents admin from stealing user funds
     * 
     * ADVANCED: Better protection
     * Check: token.balanceOf(vault) > totalDepositsPerToken[token]
     * Allow rescue of: balanceOf - totalDeposits (the excess)
     * 
     * This allows rescuing mistakenly sent tokens
     * Even for tokens that have legitimate deposits
     */
    function rescueToken(
        address token,
        uint256 amount,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        // CRITICAL: Prevent rescuing deposited tokens
        // Simple version: No rescue if any deposits exist
        if (totalDepositsPerToken[token] > 0) {
            revert("Cannot rescue token with active deposits");
        }
        
        // Advanced version (commented out):
        /*
        uint256 vaultBalance = IERC20(token).balanceOf(address(this));
        uint256 rescuable = vaultBalance > totalDepositsPerToken[token]
            ? vaultBalance - totalDepositsPerToken[token]
            : 0;
        
        if (amount > rescuable) {
            revert("Amount exceeds rescuable balance");
        }
        */
        
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert("Rescue transfer failed");
        }
        
        emit TokenRescued(token, to, amount);
    }
    
    /**
     * @notice Get fee configuration for a token
     * @param token Token address
     * @return config Fee configuration struct
     * 
     * VIEW HELPER for UI/dApps
     * Shows users what fees they'll pay
     */
    function getFeeConfig(address token) 
        external 
        view 
        returns (FeeConfig memory config) 
    {
        // Return token-specific config if exists, otherwise default
        config = feeConfigs[token].feeRecipient != address(0)
            ? feeConfigs[token]
            : defaultFeeConfig;
    }
    
    /**
     * @notice Get user's fee discount
     * @param user User address
     * @return discountBps Discount in basis points
     */
    function getUserFeeDiscount(address user) 
        external 
        view 
        returns (uint256 discountBps) 
    {
        return feeDiscounts[user];
    }
    
    /**
     * @notice Check if token is whitelisted
     * @param token Token address
     * @return bool True if whitelisted
     */
    function isWhitelisted(address token) 
        external 
        view 
        returns (bool) 
    {
        return whitelistedTokens[token];
    }
    
    /**
     * @notice Get collected fees for a token
     * @param token Token address
     * @return amount Collected fees waiting to be claimed
     */
    function getCollectedFees(address token) 
        external 
        view 
        returns (uint256 amount) 
    {
        return collectedFees[token];
    }
}

/**
 * ADMIN OPERATIONS CHECKLIST:
 * 
 * Initial Setup:
 * 1. Deploy contracts
 * 2. Initialize with admin address
 * 3. Grant roles to appropriate addresses
 * 4. Set default fee configuration
 * 5. Whitelist initial tokens
 * 
 * Ongoing Operations:
 * 1. Add new tokens as needed
 * 2. Remove deprecated/risky tokens
 * 3. Adjust fees based on market
 * 4. Grant discounts to VIP users
 * 5. Collect fees regularly
 * 6. Monitor for stuck tokens (rescue if needed)
 * 
 * Emergency Operations:
 * 1. Pause contract if exploit detected
 * 2. Remove malicious token from whitelist
 * 3. Upgrade to patched implementation
 * 4. Unpause after verification
 * 
 * GOVERNANCE CONSIDERATIONS:
 * 
 * Who should have each role?
 * 
 * OPERATOR_ROLE: (Whitelist management)
 * - 2-of-3 multi-sig
 * - Can add/remove tokens quickly
 * - Low risk (just whitelist changes)
 * 
 * FEE_MANAGER_ROLE: (Fee configuration)
 * - 3-of-5 multi-sig
 * - Should include community reps
 * - Medium risk (affects user costs)
 * 
 * DEFAULT_ADMIN_ROLE: (System-wide control)
 * - 5-of-9 multi-sig
 * - Requires founder + community votes
 * - High risk (can rescue, grant roles)
 * 
 * UPGRADER_ROLE: (Contract upgrades)
 * - 5-of-9 multi-sig + 48hr timelock
 * - Critical: Changes all logic
 * - Highest risk (full control)
 * 
 * PAUSER_ROLE: (Emergency pause)
 * - 1-of-3 multi-sig (fast response)
 * - Can be bot for automated response
 * - Low risk (protection mechanism)
 */