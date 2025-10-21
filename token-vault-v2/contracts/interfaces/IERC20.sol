// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 * 
 * Why an interface?
 * - We don't need the full ERC20 implementation, just the function signatures
 * - This allows our vault to work with ANY ERC20 token
 * - Interfaces cost no gas to deploy (they're just ABI definitions)
 */
interface IERC20 {

    /**
     * Why these specific functions?
     * - We need to check balances before/after transfers
     * - We need to move tokens from users to vault and back
     * - We DON'T need mint/burn/approve because the vault doesn't do those
     */

    function totalSupply() external view returns (uint256);
    
    function balanceOf(address account) external view returns (uint256);
    
    function transfer(address recipient, uint256 amount) external returns (bool);
    
    function allowance(address owner, address spender) external view returns (uint256);
    
    function approve(address spender, uint256 amount) external returns (bool);
    
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
    
    /**
     * Events are crucial for off-chain tracking
     * Why? Logs cost 375 gas vs 20,000 gas for storage
     * dApps can reconstruct entire state from events
     */
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}