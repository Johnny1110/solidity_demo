# Token Vault

<br>

---

<br>

This is a token vault contract, user can deposit and withdraw token by it.

## About event `indexed`:

### What Does indexed Mean?

```solidity
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
```

<br>

indexed is a critical modifier that changes how event parameters are stored and searchable on the blockchain.

<br>

**The Technical Architecture**

When an event is emitted, it creates a log entry with two components:

```solidity
Log Entry = {
    topics: [],  // Up to 4 indexed items (searchable/filterable)
    data: ""     // Non-indexed items (just stored, not searchable)
}
```

<br>

**Indexed vs Non-Indexed**

```solidity
event Transfer(
    address indexed from,    // → Goes to topics[1]
    address indexed to,      // → Goes to topics[2]
    uint256 value           // → Goes to data
);

// When emitted:
emit Transfer(0xAlice, 0xBob, 1000);

// Creates this log structure:
{
    topics: [
        0xddf2...1340,  // topics[0]: keccak256("Transfer(address,address,uint256)")
        0x0000...Alice, // topics[1]: from (indexed)
        0x0000...Bob    // topics[2]: to (indexed)
    ],
    data: 0x00000...03e8  // value (1000 in hex, non-indexed)
}
```

<br>

**Why This Matters: Bloom Filters**

The key insight: The EVM uses Bloom filters for efficient log searching:

* Indexed parameters → Added to block's Bloom filter
* Non-indexed parameters → NOT in Bloom filter
* Bloom filter = probabilistic data structure for "possibly in set" queries

```
// This is FAST (uses Bloom filter):
filter = {
    address: tokenContract,
    topics: [
        Transfer.signature,
        addressFrom,  // Can filter by sender!
        null         // Don't care about recipient
    ]
}

// This is SLOW (must read every log's data):
// "Find all transfers of exactly 1000 tokens" - CAN'T DO efficiently!
// because 'value' is not indexed
```

<br>

So in Token Vault case: we can search log by this:

```
event Deposit(
    address indexed depositor,  // ✓ Can find "all deposits by Alice"
    address indexed token,      // ✓ Can find "all USDC deposits"
    uint256 amount              // ✗ Can't efficiently find "all deposits > 1000"
);
```

<br>

**How to query Logs?**

Using Web3.js/Ethers.js:

```js
// Web3.js example - filtering by indexed parameters
const filter = {
    address: tokenAddress,
    topics: [
        web3.utils.sha3('Transfer(address,address,uint256)'),
        web3.utils.padLeft(fromAddress, 64),  // Must pad to 32 bytes
        null  // Don't filter by 'to' address
    ],
    fromBlock: 0,
    toBlock: 'latest'
};

const logs = await web3.eth.getPastLogs(filter);

// Ethers.js - more user-friendly
const filter = token.filters.Transfer(fromAddress, null);  // Auto-handles padding!
const logs = await token.queryFilter(filter);
```

<br>
<br>
<br>
<br>

### What does `calldata` means?

```solidity
function batchAddTokensToWhitelist(address[] calldata tokens) external onlyOwner {
    for (uint i = 0; i < tokens.length; i++) {
        require(tokens[i].code.length > 0, "Not a valid contract");
        require(!whitelistedTokens[tokens[i]], "Token already whitelisted");
        require(IERC20(tokens[i]).totalSupply() > 0, "Invalid token address");
        whitelistedTokens[tokens[i]] = true;
        emit TokenWhitelisted(tokens[i]);
    }
}
```

`calldata` is one of the most important concepts for gas optimization in Solidity. 

<br>

### The Four Data Locations in Solidity

```
// 1. STORAGE - Permanent blockchain storage
mapping(address => uint) public balances;  // Always in storage

// 2. MEMORY - Temporary, exists during function execution
function process(uint[] memory data) { }

// 3. CALLDATA - Read-only, exists during external function calls
function process(uint[] calldata data) external { }

// 4. STACK - Local variables (max 16 slots)
function example() {
    uint256 x = 5;  // Stack variable
}
```

Calldata is the actual bytes sent with a transaction. It's:

* Read-only (immutable)
* Non-persistent (exists only during the call)
* The cheapest data location for function parameters
* External functions only (not available for internal/private)


<br>

**When to Use Each Data Location?**

1. Use `calldata` when:

```sol
// Read-only array/string parameters in external functions
function validateTokens(address[] calldata tokens) external view

// Passing data to other functions without modification
function forward(bytes calldata data) external

// Large arrays that you're only reading
function sumLargeArray(uint256[] calldata numbers) external pure
```

<br>

2. Use memory when:

```solidity
// Need to modify the array
function sortArray(uint256[] memory arr) public pure returns (uint256[] memory)

// Building new arrays
function createArray() public pure returns (uint256[] memory) {
    uint256[] memory newArray = new uint256[](10);
    return newArray;
}

// Internal/private functions (can't use calldata)
function internalProcess(uint256[] memory data) internal
```

<br>

3. Use `storage` when:

```solidity
// Permanent state variables
uint256[] public storedArray;

// Passing storage references (saves gas!)
function updateStorageArray(uint256[] storage arr) internal
```