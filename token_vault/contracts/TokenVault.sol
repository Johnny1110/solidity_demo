// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IERC20.sol";

/**
 * @title TokenVault
 * @dev A vault for depositing and withdrawing ERC20 tokens
 * 
 * Theory: Why do we need vaults?
 * - Centralize token management (useful for staking, lending, etc.)
 * - Add extra functionality (time locks, yield generation, etc.)
 * - Separate concerns (tokens stay in vault, not in complex business logic)
 */
contract TokenVault {

    // ========== Constants ==========

    /**
     * BASIS POINTS explanation:
     * 1 basis point = 0.01%
     * 100 basis points = 1%
     * 10000 basis points = 100%
     * 
     * Why basis points instead of percentage?
     * - No decimals in Solidity (uint only)
     * - More precise than whole percentages
     * - Industry standard in finance
     */
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_FEE = 1000; // 10% maximum fee (protection)

    
    // ========== State Variables ==========

    /**
     * 
     * Why mapping(address => mapping(address => uint256))?
     * - First address: depositor's address
     * - Second address: token contract address
     * - uint256: amount deposited
     * 
     * This uses 2 keccak256 hashes to find the storage slot:
     * slot = keccak256(token_address || keccak256(user_address || slot_number))
     * 
     * Gas cost: ~5000 for first access, ~2100 for subsequent (warm access)
     */
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => uint256) public totalDepositsPerToken; // total of all users for a token


    /**
     * WHITELIST MAPPING
     * Gas: 20,000 to add new token, 5,000 to update
     */
    mapping(address => bool) public whitelistedTokens;

    /**
     * OWNER PATTERN
     * Why immutable? Once deployed, owner can't be changed accidentally
     * Alternative: Use Ownable from OpenZeppelin for transferable ownership
     */

    address public immutable owner;

    /**
     * Fee configuration per token
     * Why per-token fees?
     * - Stablecoins might have lower fees
     * - Volatile tokens might have higher fees
     * - New tokens might have promotional 0% fees
     */
    struct FeeConfig {
        uint256 depositFeeBps; // Basis pointer for deposit
        uint256 withdrawFeeBps; // Basis pointer for withdrawal
        address feeRecipient; // Where fees are sent
        bool exemptFromFees; // If true, no fees applied
    } 

    mapping(address => FeeConfig) public feeConfigs;
    mapping(address => uint256) public feeDiscounts; // NFT ownership => discount in basis points


    /**
     * Default fee configuration
     * Applied to tokens without specific configuration
     */
    FeeConfig public defaultFeeConfig;

    /**
     * Track collected fees separately
     * Why separate tracking?
     * - Clear accounting
     * - Can't accidentally withdraw user deposits
     * - Easy fee distribution
     */
    mapping(address => uint256) public collectedFees;
    
    /**
     * EVENTS
     * 
     * Why indexed parameters?
     * - Indexed params become topics (searchable/filterable)
     * - Max 3 indexed params (4 topics total, first is event signature)
     * - Non-indexed go into data (cheaper but not searchable)
     * 
     * Gas cost: 375 base + 375 per topic + 8 per byte of data
     */
    event Deposit(
        address indexed depositor,
        address indexed token,
        uint256 amountIn,
        uint256 amountAfterFee,
        uint256 fee
    );
    
    event Withdrawal(
        address indexed withdrawer,
        address indexed token,
        uint256 amountRequested,
        uint256 amountSent,
        uint256 fee
    );

    event FeeConfigUpdated(
        address indexed token,
        uint256 depositFeeBps,
        uint256 withdrawFeeBps,
        address feeRecipient
    );

    event FeesCollected(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    
    event FeeDiscountSet(
        address indexed user,
        uint256 discountBps
    );

    /**
     * Why events for admin actions?
     * - Transparency: Users can see when/what owner changes
     * - Accountability: On-chain audit trail
     * - Monitoring: dApps can react to whitelist changes
     */
    event TokenWhitelisted(address indexed token);
    event TokenRemovedFromWhitelist(address indexed token);

    // ========== Modifiers ==========

    /**
     * MODIFIER PATTERN
     * Why use modifiers?
     * - DRY (Don't Repeat Yourself)
     * - Consistent security checks
     * - Readable: "This function is onlyOwner"
     * 
     * Gas: Adds ~100 gas to function call
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only contract owner can call this");
        _;  // This is where the function body gets inserted
    }

    /**
     * Token validation modifier
     * Checks if token is whitelisted before allowing operation
     */
    
    modifier onlyWhitelisted(address token) {
        require(whitelistedTokens[token], "Token not allowed");
        _;
    }
    
    // ========== Constructor ==========
    
    /**
     * Set owner at deployment
     * Why in constructor?
     * - Owner is set atomically with contract creation
     * - No time window where contract is ownerless
     * - Can't forget to set owner (common bug)
     */
    constructor(address _defaultFeeRecipient) {
        owner = msg.sender;

        defaultFeeConfig = FeeConfig({
            depositFeeBps: 0, // 0%
            withdrawFeeBps: 30, // 0.3%
            feeRecipient: _defaultFeeRecipient,
            exemptFromFees: false
        });
    }
    
    // ========== Fee Calculation Helper ==========

    /**
     * Calculate fee for a given amount
     * 
     * CRITICAL: Rounding direction matters!
     * - For deposits: Round fee UP (user gets less)
     * - For withdrawals: Round fee UP (user gets less)
     * - Always favor protocol over user for sustainability
     * 
     * Math explanation:
     * fee = (amount * feeBps) / BASIS_POINTS
     * 
     * Example: 1000 tokens with 30 bps (0.3%) fee
     * fee = (1000 * 30) / 10000 = 3 tokens
     */
    function calculateFee(uint256 amount, uint256 feeBps) public pure returns (uint256 fee, uint256 amountAfterFee) {
        if (feeBps == 0) {
            // zero fee case
            return (0, amount);
        }

        /**
         * SafeMath not needed in 0.8+ but let's be explicit about overflow
         * Maximum: type(uint256).max * MAX_FEE / BASIS_POINTS
         * This can't overflow in practice
         */
         fee = (amount * feeBps) / BASIS_POINTS;

         /**
         * Important: Check for underflow
         * If fee >= amount, something is wrong
         */
         require(fee < amount, "Fee exceeds amount");
         amountAfterFee = amount - fee;
    }


    /**
     * Get effective fee for a user (considering discounts)
     */
    function getEffectiveFee(address user, address token, bool isDeposit) public view returns (uint256) {
        // feeConfigs[token] will never be null, but check if feeRecipient is set.
        FeeConfig memory config = feeConfigs[token].feeRecipient != address(0) ? feeConfigs[token] : defaultFeeConfig;

        if (config.exemptFromFees) {
            return 0;
        }

        uint256 baseFee = isDeposit ? config.depositFeeBps : config.withdrawFeeBps;
        uint256 discount = feeDiscounts[user];

        /**
         * Apply discount
         * If user has 5000 bps (50%) discount on 30 bps fee:
         * effectiveFee = 30 - (30 * 5000 / 10000) = 15 bps
         */
         if (discount > 0) {
            uint256 reduction = (baseFee * discount) / BASIS_POINTS;
            baseFee = baseFee > reduction ? baseFee - reduction : 0;
         }

         return baseFee;
    }


    // ========== Admin Functions ==========

    function addTokenToWhitelist(address token) external onlyOwner {
        require(token.code.length > 0, "Not a valid contract");
        // make sure token is not already whitelisted
        require(!whitelistedTokens[token], "Token already whitelisted");
        // make sure token address is valid (totalSupply > 0)
        require(IERC20(token).totalSupply() > 0, "Invalid token address");

        whitelistedTokens[token] = true;
        emit TokenWhitelisted(token);
    }

    function batchAddTokensToWhitelist(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i].code.length > 0, "Not a valid contract");
            require(!whitelistedTokens[tokens[i]], "Token already whitelisted");
            require(IERC20(tokens[i]).totalSupply() > 0, "Invalid token address");
            whitelistedTokens[tokens[i]] = true;
            emit TokenWhitelisted(tokens[i]);
        }
    }

    function removeTokenFromWhitelist(address token) external onlyOwner {
        require(whitelistedTokens[token], "Token not in whitelist");
        whitelistedTokens[token] = false;
        emit TokenRemovedFromWhitelist(token);
    }

    /**
     * Rescue mistakenly sent tokens
     * Only for tokens NOT in deposits mapping
     */
    function rescueToken(address token, uint256 amount) external onlyOwner {
        // if token is in deposits mapping, disallow rescue
        require(totalDepositsPerToken[token] == 0, "Token is in deposits");
        IERC20(token).transfer(owner, amount);
    }

    function setTokenFeeConfig(
        address token, 
        uint256 depositFeeBps, uint256 withdrawFeeBps, 
        address feeRecipient, bool exemptFromFees) external onlyOwner {
            require(depositFeeBps <= MAX_FEE, "Deposit fee too high");
            require(withdrawFeeBps <= MAX_FEE, "Withdraw fee too high");
            require(feeRecipient != address(0), "Invalid fee recipient");

            feeConfigs[token] = FeeConfig({
                depositFeeBps: depositFeeBps,
                withdrawFeeBps: withdrawFeeBps,
                feeRecipient: feeRecipient,
                exemptFromFees: exemptFromFees
            });

            emit FeeConfigUpdated(token, depositFeeBps, withdrawFeeBps, feeRecipient);
    }

    function setUserFeeDiscount(
        address user,
        uint256 discountBps
    ) external onlyOwner {
        require(discountBps <= BASIS_POINTS, "Discount too high");
        feeDiscounts[user] = discountBps;
        emit FeeDiscountSet(user, discountBps);
    }

    function collectFees(address token) external onlyOwner {
        uint256 amount = collectedFees[token];
        require(amount > 0, "No fees to collect");

        address recipient = feeConfigs[token].feeRecipient != address(0)
            ? feeConfigs[token].feeRecipient
            : defaultFeeConfig.feeRecipient;

        // Reset collected fees before transfer to prevent reentrancy
        collectedFees[token] = 0;

        IERC20(token).transfer(recipient, amount);
        emit FeesCollected(token, recipient, amount);
    }

    function batchCollectFees(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            uint256 amount = collectedFees[tokens[i]];
            if (amount > 0) {
                address recipient = feeConfigs[tokens[i]].feeRecipient != address(0)
                    ? feeConfigs[tokens[i]].feeRecipient
                    : defaultFeeConfig.feeRecipient;

                collectedFees[tokens[i]] = 0;
                IERC20(tokens[i]).transfer(recipient, amount);
                emit FeesCollected(tokens[i], recipient, amount);
            }
        }
    }

    // ========== Core Functions ==========
    
    /**
     * @dev Deposit tokens into the vault
     * 
     * Why external instead of public?
     * - External functions can't be called internally
     * - Saves ~40 gas because arguments can be read directly from calldata
     * - Public copies arguments to memory even for external calls
     */
    function deposit(address token, uint256 amount) external onlyWhitelisted(token) {
        /**
         * Why check amount > 0?
         * - Prevents useless state changes
         * - Saves gas for users making mistakes
         * - Some tokens revert on 0 transfers anyway
         */
        require(amount > 0, "Amount must be greater than 0");

        uint256 effectiveFeeBps = getEffectiveFee(msg.sender, token, true);

        (uint256 fee, uint256 amountAfterFee) = calculateFee(amount, effectiveFeeBps);
        
        /**
         * CRITICAL: Why transferFrom BEFORE updating state?
         * - This seems backwards but it's actually CORRECT here
         * - transferFrom can revert if insufficient balance/allowance
         * - If it reverts, our state never changes (atomic transaction)
         * - This is NOT a reentrancy risk because:
         *   1. We're calling a trusted token (user chose it)
         *   2. We're not depending on our state during the call
         *   3. Even if token is malicious, worst case is DoS, not theft
         */
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        /**
         * Update state AFTER external call succeeds
         * - Uses storage (expensive: 20,000 gas for new slot, 5,000 for update)
         * - Why += instead of =? Supports multiple deposits
         */
        deposits[msg.sender][token] += amountAfterFee;
        totalDepositsPerToken[token] += amountAfterFee;

        if (fee > 0) {
            collectedFees[token] += fee;
        }
        
        /**
         * Emit event for off-chain tracking
         * - Much cheaper than storing everything
         * - dApps can rebuild entire vault state from events
         */
        emit Deposit(msg.sender, token, amount, amountAfterFee, fee);
    }
    
    /**
     * @dev Withdraw tokens from the vault
     */
    function withdraw(address token, uint256 amount) external {
        /**
         * Why check balance FIRST?
         * - This is the "checks" in checks-effects-interactions
         * - Prevents underflow (though Solidity 0.8+ has built-in protection)
         * - Clear error message for users
         */
        require(deposits[msg.sender][token] >= amount, "Insufficient balance");

        uint256 effectiveFeeBps = getEffectiveFee(msg.sender, token, false);
        (uint256 fee, uint256 amountToSend) = calculateFee(amount, effectiveFeeBps);
        
        /**
         * CRITICAL: Update state BEFORE external call
         * - This is "effects" in checks-effects-interactions
         * - Prevents reentrancy attacks
         * - Even if token.transfer() calls back into withdraw(), 
         *   deposits is already reduced, so second withdrawal fails
         * 
         * Classic reentrancy example:
         * 1. User has 100 tokens deposited
         * 2. Calls withdraw(100)
         * 3. If we transferred BEFORE reducing balance:
         *    - Malicious token could call withdraw(100) again
         *    - Balance still shows 100, so it succeeds!
         * 4. By reducing first, second call fails at require()
         */
        deposits[msg.sender][token] -= amount;
        totalDepositsPerToken[token] -= amount;

        if (fee > 0) {
            collectedFees[token] += fee;
        }
        
        /**
         * "Interactions" - external calls go LAST
         * - transfer() is simpler than transferFrom()
         * - Returns bool, but many tokens don't follow this
         * - In production, use SafeERC20 library for compatibility
         */
        IERC20(token).transfer(msg.sender, amountToSend);
        
        emit Withdrawal(msg.sender, token, amount, amountToSend, fee);
    }
    
    /**
     * @dev Get deposited balance for a user and token
     * 
     * Why view?
     * - Doesn't modify state, costs no gas to call
     * - Can be called by other contracts for free
     * - Returns value directly (not transaction receipt)
     */
    function getBalance(address user, address token) external view returns (uint256) {
        return deposits[user][token];
    }

    function getWithdrawableAmount(address user, address token) external view returns (uint256) {
        uint256 balance = deposits[user][token];
        if (balance == 0) {
            return 0;
        }

        uint256 effectiveFeeBps = getEffectiveFee(user, token, false);
        (, uint256 amountToSend) = calculateFee(balance, effectiveFeeBps);
        return amountToSend;
    }
    
    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }


    function getTVL(address token) external view returns (uint256) {
        return totalDepositsPerToken[token];
    }

    /**
     * ADVANCED CONSIDERATIONS (not implemented here):
     * 
     * 1. Emergency Pause:
     *    - What if a token has a critical bug?
     *    - Consider OpenZeppelin's Pausable pattern
     * 
     * 3. Fees:
     *    - Vaults often take fees for maintenance
     *    - Would need owner and fee calculation logic
     * 
     * 4. Yield Generation:
     *    - Deposited tokens could be lent out
     *    - Requires integration with lending protocols
     * 
     * 5. Gas Optimization:
     *    - Pack struct variables if multiple values per user
     *    - Use events more extensively to avoid storage
     */
}