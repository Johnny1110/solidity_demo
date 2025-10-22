# Proxy Pattern: UUPS


<br>

---

<br>


## 學習目標

完成這個訓練後，你將能夠：

* 從零開始實現 UUPS proxy 系統
* 安全地升級合約而不丟失數據
* 處理真實世界的升級場景
* 避免常見的 storage collision 陷阱
* 理解為什麼大型 DeFi 協議選擇 UUPS

<br>
<br>


## 介紹

### 為什麼需要 Proxy？

智能合約一旦部署就無法修改，但業務需求會改變。Proxy 模式透過分離「儲存」和「邏輯」解決這個問題：


```
用戶 → Proxy合約（保存狀態） → delegatecall → Implementation合約（業務邏輯）
         ↓
      Storage（數據永久保存在這裡）
```

<br>
<br>

### UUPS 優缺點

優點：

* Gas 效率最高 - 每次調用節省約 1000 gas
* 被頂級協議採用 - Aave V3、Compound V3、OpenZeppelin 都使用 UUPS
* 安全性更明確 - 升級邏輯在實作合約中，控制權更清晰

缺點：

* 必須確保每個新版本都包含升級函數


<br>
<br>

### delegatecall 的核心機制


* 普通 call：在被調用合約的 context 中執行
* delegatecall：在調用者的 context 中執行

```
// delegatecall 保留三個關鍵要素：
// 1. msg.sender（保持不變）
// 2. msg.value（保持不變）  
// 3. Storage（使用 Proxy 的 storage，不是 Implementation 的）
```

<br>
<br>

### UUPS 的關鍵實作細節

1. Storage Slot 機制

為避免儲存碰撞，Proxy 變數使用特定的 slot：

```solidity
// EIP-1967 標準 slot
bytes32 constant IMPLEMENTATION_SLOT = 
    bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
// 結果：0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

為什麼用 keccak256 hash？

* 避免與邏輯合約的順序儲存（slot 0, 1, 2...）碰撞
* Hash 產生的隨機 slot 位置幾乎不可能重複

<br>
<br>

2. 初始化模式（不用 constructor）

```solidity
// ❌ 錯誤：使用 constructor
constructor(address _owner) {
    owner = _owner; // 這只會設置 Implementation 的 storage！
}

// ✅ 正確：使用 initialize 函數
function initialize(address _owner) external {
    require(!initialized, "Already initialized");
    owner = _owner; // 透過 delegatecall 設置 Proxy 的 storage
    initialized = true;
}
```

原因：constructor 在部署 Implementation 時執行，但那時的 storage 不是 Proxy 的！


<br>
<br>


3. Storage Gap 模式（預防升級問題）

```solidity
contract VaultV1 {
    mapping(address => uint256) public deposits;
    uint256[49] private __gap; // 預留 49 個 slot
}

contract VaultV2 is VaultV1 {
    mapping(address => bool) public newFeature; // 使用 1 個 gap slot
    uint256[48] private __gap; // 剩餘 48 個
}
```

理論基礎：EVM storage 是連續的 32 bytes slots。新增變數會使用下一個 slot，如果不預留空間，會覆蓋原有數據。


<br>
<br>
<br>
<br>


## 什麼是 Storage Slot？

<br>

### 基礎概念：EVM 的儲存機制

想像以太坊的儲存像是一個巨大的「抽屜櫃」，每個抽屜就是一個 storage slot：

```
┌─────────────────────┐
│   Slot 0 (32 bytes) │ ← 第一個抽屜
├─────────────────────┤
│   Slot 1 (32 bytes) │ ← 第二個抽屜
├─────────────────────┤
│   Slot 2 (32 bytes) │ ← 第三個抽屜
├─────────────────────┤
│        ...          │
└─────────────────────┘
```

* 每個 slot = 32 bytes（256 bits）
* Slot 編號從 0 開始，連續遞增
* 每個 slot 可以存一個變數（或多個小變數）

實際例子：變數如何分配到 Slot

```solidity
contract SimpleStorage {
    uint256 public balance;      // Slot 0（256 bits，剛好填滿）
    address public owner;         // Slot 1（160 bits，還剩 96 bits）
    uint256 public totalSupply;   // Slot 2（256 bits，剛好填滿）
}
```

視覺化：
```
Slot 0: [balance - 256 bits 全部使用]
Slot 1: [owner - 160 bits][空 - 96 bits]
Slot 2: [totalSupply - 256 bits 全部使用]
```

<br>

**為什麼 Slot 很重要？**

Gas 成本差異巨大：

* 讀取一個 slot：2,100 gas
* 寫入新 slot（第一次）：20,000 gas
* 更新已有 slot：5,000 gas

所以如果你的變數分散在多個 slot，成本會很高！

<br>
<br>

### Proxy 模式中的 Storage 碰撞問題


**核心問題：Proxy 和 Implementation 共用儲存空間**

當使用 delegatecall 時，Implementation 的程式碼在 Proxy 的儲存空間中執行：


```solidity
// ❌ 災難性的錯誤例子
contract ProxyV1 {
    address implementation;  // Slot 0
}

contract ImplementationV1 {
    uint256 userBalance;     // 也是 Slot 0！
}
```

**發生什麼事？**
```
用戶存款 100 ETH
→ userBalance = 100
→ 寫入 Slot 0
→ 覆蓋了 implementation 地址！
→ Proxy 現在指向地址 0x64（100 的 hex）
→ 合約完全壞掉！
```


<br>

解決方案 1：使用隨機 Slot

```solidity
contract SafeProxy {
    // 使用 keccak256 產生隨機位置
    bytes32 constant IMPLEMENTATION_SLOT = 
        keccak256("eip1967.proxy.implementation");
    // = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    
    function _setImplementation(address impl) internal {
        assembly {
            // 存到這個超大數字的 slot，不會撞到正常變數
            sstore(IMPLEMENTATION_SLOT, impl)
        }
    }
}
```

為什麼安全？

* 正常變數從 Slot 0, 1, 2... 開始
* 這個 Slot 是 0x360894a13ba1a...（超級大的數字）
* 幾乎不可能碰撞


<br>
<br>
<br>
<br>

## 什麼是 Storage Gap？

問題：升級時新增變數會破壞佈局


```solidity
// ❌ 錯誤的升級方式
contract VaultV1 {
    mapping(address => uint256) public deposits;  // Slot 0
    address public owner;                         // Slot 1
}

contract VaultV2 {
    uint256 public newFeature;                    // Slot 0 ← 問題！
    mapping(address => uint256) public deposits;  // Slot 1 ← 位移了！
    address public owner;                         // Slot 2 ← 位移了！
}
```

**災難發生：**
```
V1 佈局：
Slot 0: deposits[用戶A] = 1000 ETH
Slot 1: owner = 0xAAA...

升級到 V2 後：
Slot 0: newFeature（讀到 1000，以為是 newFeature 的值）
Slot 1: deposits[用戶A]（讀到 0xAAA，完全錯誤）

結果：所有用戶餘額都不見了！
```

<br>
<br>

解決方案：Storage Gap（儲存間隙）

```solidity
// ✅ 正確的方式
contract VaultV1 {
    mapping(address => uint256) public deposits;  // Slot 0
    address public owner;                         // Slot 1
    uint256[48] private __gap;                    // Slot 2-49（預留空間）
}

contract VaultV2 {
    mapping(address => uint256) public deposits;  // Slot 0 ← 不變
    address public owner;                         // Slot 1 ← 不變
    uint256 public newFeature;                    // Slot 2 ← 使用 gap 空間
    uint256[47] private __gap;                    // Slot 3-49（gap 減 1）
}
```

**視覺化理解：**
```
V1 記憶體佈局：
[deposits][owner][空][空][空]...[空] ← 50 個 slots

V2 記憶體佈局：
[deposits][owner][newFeature][空][空]...[空] ← 還是 50 個 slots
                  ↑
                  使用了一個預留空間
```

為什麼通常用 50 個 Slots？

* 足夠的擴展空間：50 個 slots 可以加入約 50 個新變數
* 不會太浪費：空 slot 不消耗 gas（只有在寫入時才消耗）
* 業界標準：OpenZeppelin 等主流庫都用 50


<br>

### 實際操作範例

安全的升級流程

```solidity
// 第一版
contract TokenVaultV1 {
    // === 核心儲存 ===
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => uint256) public totalDeposits;
    address public admin;
    
    // === 預留空間 ===
    uint256[47] private __gap;  // 用了 3 個 slot，留 47 個
}

// 第二版：新增手續費功能
contract TokenVaultV2 {
    // === 保持原有變數位置 ===
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => uint256) public totalDeposits;
    address public admin;
    
    // === 新增功能（使用 gap 空間）===
    uint256 public feePercentage;      // 使用 gap[0]
    address public feeRecipient;       // 使用 gap[1]
    
    // === 更新 gap ===
    uint256[45] private __gap;  // 減少 2 個
}
```


<br>

### Mapping 的特殊性

**Mapping 比較特別，它不是直接存在指定的 slot：**

```solidity
mapping(address => uint256) public balances;  // 宣告在 Slot 0

// 實際儲存位置計算：
// balances[userAddress] 存在：
// keccak256(userAddress . 0) 的位置
// 不是 Slot 0！
```

為什麼？

* Mapping 可能有無限個 key
* 不可能預先分配連續空間
* 使用 hash 分散到整個儲存空間

### 關鍵規則總結

**永遠不能做的事：**

* ❌ 永不重新排序變數
* ❌ 永不改變變數類型
* ❌ 永不刪除變數
* ❌ 永不在中間插入變數

**只能做的事：**

* ✅ 只在末尾新增變數（使用 gap）
* ✅ 可以修改變數的值
* ✅ 可以改變函數邏輯


<br>

---

因為 Storage 是永久的。一旦寫入，slot 的位置就固定了。如果你改變佈局，程式會從錯誤的位置讀取資料，導致：

* 用戶資金遺失
* 合約邏輯錯誤
* 無法修復（區塊鏈不可變）

<br>

這就是為什麼專業的可升級合約都要使用 Storage Gap 模式，並且要極其小心地管理儲存佈局

<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>

## 需求實戰 - 迷你銀行系統

開發一個去中心化的儲蓄系統，需要：

1. 可升級性：業務會不斷擴展
2. Gas 效率：用戶對手續費敏感
3. 安全性：處理真實資金


<br>

### 階段一：MVP 版本 (V1)

業務需求：

* 用戶可以存入 ETH
* 用戶可以提取自己的 ETH
* 顯示用戶餘額
* 只有管理員能暫停系統

技術需求：

* 使用 UUPS proxy 模式
* 包含基礎的存提款功能
* 簡單的 access control

<br>

### 階段二：升級需求 (V2)

新業務需求：

* 新增利息功能（年利率 5%）
* VIP 用戶系統（存款 > 10 ETH 自動成為 VIP）
* VIP 用戶享有 7% 年利率
* 新增提款手續費（普通用戶 0.1%，VIP 免費）

升級挑戰：

* 保持所有 V1 用戶的存款數據
* 不能改變原有 storage 佈局
* 平滑升級，用戶無感

<br>

### 階段三：緊急修復 (V2.1)

突發狀況：

* 發現利息計算有 bug
* 需要緊急修復並升級
* 測試 emergency pause 機制

<br>
<br>

### 項目架構

```
minibank-protocol/
├── contracts/
│   ├── v1/
│   │   ├── MiniBankV1.sol         # 實現合約 V1
│   │   └── MiniBankProxy.sol      # UUPS Proxy（不變）
│   ├── v2/
│   │   └── MiniBankV2.sol         # 實現合約 V2
│   └── interfaces/
│       └── IMiniBank.sol           # 介面定義
├── scripts/
│   ├── 1_deploy_v1.js
│   ├── 2_test_v1.js
│   ├── 3_deploy_v2.js
│   └── 4_upgrade_to_v2.js
└── tests/
    └── upgrade_test.js
```

<br>

### 關鍵 Pattern 實踐

**1. Proxy 不變性**

* Proxy 合約永遠不升級
* 只有 Implementation 會改變

<br>

**2. Initialize 模式**

```solidity
function initialize(address admin) external initializer {
       _admin = admin;
       _paused = false;
   }
```

<br>

**升級安全檢查**

```solidity
function upgradeTo(address newImpl) external onlyAdmin {
       require(newImpl.code.length > 0, "Not a contract");
       _upgradeToAndCall(newImpl, "", false);
   }
```

