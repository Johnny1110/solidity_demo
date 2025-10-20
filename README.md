# Solidity Demo Prjects

<br>

---

<br>

Demo projects of solidity learning.

<br>
<br>

## 1. Token Vault Contract

This is perfect for understanding the fundamentals while being immediately practical.


**What you'll learn and why:**

* State variables & mappings: How Solidity stores data in contract storage slots
* msg.sender and tx.origin: Understanding the execution context and why msg.sender is crucial for security
* Events: How logs work in the EVM and why they're gas-efficient for off-chain data
* Reentrancy protection: Why the checks-effects-interactions pattern exists

Theory behind it:

When you deposit tokens, you're actually changing the state of two contracts - the token contract (decreasing your balance) and the vault (recording your deposit). This teaches you about external calls, gas costs, and why we need approval patterns in ERC20.

[link](token_vault)

<br>
<br>

## 2. Dutch Auction Contract

More complex state management and time-based logic.

**What you'll learn and why:**

* Block.timestamp: How time works on-chain and why it can be manipulated
* Price curves and algorithms: Implementing mathematical functions in Solidity's integer-only environment
* Storage vs memory vs calldata: Why these distinctions matter for gas optimization
* Function modifiers: How Solidity implements reusable security checks

Theory behind it:

Dutch auctions decrease price over time, teaching you about block timestamps, storage updates, and why certain operations are expensive. You'll understand why we avoid loops and complex calculations on-chain.

<br>

[link](dutch_auction)

<br>
<br>

## 3. Multi-Signature Wallet
   
Enterprise-grade patterns and security.

**What you'll learn and why:**

* Struct packing: How the EVM packs storage and why order matters
* Mapping of mappings: Complex data structures and their gas implications
* Assembly and low-level calls: How call, delegatecall, and staticcall differ
* Signature verification: How ECDSA works and why we need ecrecover

<br>

Theory behind it:

Multi-sigs show you why simple operations (like requiring multiple approvals) become complex on-chain. You'll understand gas optimization, storage patterns, and why we sometimes need off-chain coordination.

[link](multi_sign_wallet)

<br>
<br>

## 4. Minimal DEX with AMM

The pinnacle of DeFi understanding.

**What you'll learn and why:**

* Constant product formula (x*y=k): Why this creates automatic market making
* Liquidity pools: How to handle multiple token balances and LP tokens
* Slippage and front-running protection: Why these attacks exist and how to prevent them
* Flash loan resistance: Understanding synchronous vs asynchronous operations

Theory behind it:
AMMs are beautiful because they replace order books with math. You'll understand why integer division matters, how rounding errors can be exploited, and why we need minimum liquidity.

<br>

[link](amm_dex)

<br>
<br>

---

* Vault teaches you the basics of value transfer and security
* Auction adds time and algorithms
* Multi-sig introduces complex authorization patterns
* DEX combines everything into a production-ready system

<br>

---

<br>
