# Token Vault V2

<br>

---

<br>

## Project Structure

```
token-vault-v2/
├── contracts/
│   ├── core/
│   │   ├── TokenVault.sol           # Main vault logic (simplified)
│   │   └── VaultStorage.sol         # Storage layout (upgradeability)
│   ├── access/
│   │   ├── VaultAccessControl.sol   # Role-based access control
│   │   └── Roles.sol                # Role definitions
│   ├── features/
│   │   ├── FeeManager.sol           # Fee calculation & management
│   │   ├── WhitelistManager.sol     # Token whitelist logic
│   │   └── EmergencyPause.sol       # Circuit breaker pattern
│   ├── interfaces/
│   │   ├── ITokenVault.sol          # Main vault interface
│   │   ├── IFeeManager.sol          # Fee manager interface
│   │   └── IERC20.sol               # Standard ERC20 interface
│   ├── libraries/
│   │   ├── FeeCalculations.sol      # Pure fee math functions
│   │   └── SafeTransfer.sol         # Safe ERC20 operations
│   └── mocks/
│       └── MockToken.sol            # Testing token
├── test/
│   ├── unit/
│   │   ├── TokenVault.test.js
│   │   ├── FeeManager.test.js
│   │   ├── WhitelistManager.test.js
│   │   └── AccessControl.test.js
│   ├── integration/
│   │   └── FullFlow.test.js
│   └── helpers/
│       ├── fixtures.js
│       └── utils.js
├── scripts/
│   ├── deploy.js
│   ├── upgrade.js
│   └── setup.js
├── hardhat.config.js
├── package.json
└── README.md
```

<br>
<br>
<br>
<br>

## Key Architectural Changes

**Separation of Concerns**

* Core Logic: Deposit/withdraw in TokenVault.sol
* Access Control: Isolated in VaultAccessControl.sol
* Fee Management: Extracted to FeeManager.sol
* Whitelist: Moved to WhitelistManager.sol

<br>

## Modular Design

Each module has:

* Clear single responsibility
* Well-defined interfaces
* Independent testing
* Easy to upgrade/replace

<br>

## Security Patterns

* ReentrancyGuard
* Pausable
* Access Control
* Checks-Effects-Interactions

<br>

## Gas Optimization

* Storage layout optimization
* Batch operations
* Efficient data structures
* Library usage for common operations

<br>
<br>

## Setup Development Environment

```bash
# Initialize new project
mkdir token-vault-pro
cd token-vault-pro
npm init -y

# Install dependencies
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @openzeppelin/contracts

# Initialize Hardhat
npx hardhat --init
```