# Token Vault

<br>

---

<br>

This is a token vault contract, user can deposit and withdraw token by it.

## Important:

### What Does indexed Mean?

```sol
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

```sol
Log Entry = {
    topics: [],  // Up to 4 indexed items (searchable/filterable)
    data: ""     // Non-indexed items (just stored, not searchable)
}
```

<br>

**Indexed vs Non-Indexed**

```sol
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