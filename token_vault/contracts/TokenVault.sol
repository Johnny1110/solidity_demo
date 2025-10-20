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
    
    /**
     * STATE VARIABLES
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
        uint256 amount
    );
    
    event Withdrawal(
        address indexed withdrawer,
        address indexed token,
        uint256 amount
    );
    
    /**
     * Why no constructor?
     * - This vault is stateless between different tokens
     * - No owner needed (fully permissionless)
     * - Simpler = fewer bugs
     */
    
    /**
     * @dev Deposit tokens into the vault
     * 
     * Why external instead of public?
     * - External functions can't be called internally
     * - Saves ~40 gas because arguments can be read directly from calldata
     * - Public copies arguments to memory even for external calls
     */
    function deposit(address token, uint256 amount) external {
        /**
         * Why check amount > 0?
         * - Prevents useless state changes
         * - Saves gas for users making mistakes
         * - Some tokens revert on 0 transfers anyway
         */
        require(amount > 0, "Amount must be greater than 0");
        
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
        deposits[msg.sender][token] += amount;
        
        /**
         * Emit event for off-chain tracking
         * - Much cheaper than storing everything
         * - dApps can rebuild entire vault state from events
         */
        emit Deposit(msg.sender, token, amount);
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
        
        /**
         * "Interactions" - external calls go LAST
         * - transfer() is simpler than transferFrom()
         * - Returns bool, but many tokens don't follow this
         * - In production, use SafeERC20 library for compatibility
         */
        IERC20(token).transfer(msg.sender, amount);
        
        emit Withdrawal(msg.sender, token, amount);
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
    
    /**
     * ADVANCED CONSIDERATIONS (not implemented here):
     * 
     * 1. Emergency Pause:
     *    - What if a token has a critical bug?
     *    - Consider OpenZeppelin's Pausable pattern
     * 
     * 2. Token Whitelist:
     *    - What if someone deposits a malicious token?
     *    - Could maintain mapping(address => bool) allowedTokens
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