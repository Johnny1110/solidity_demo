// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IMiniBank.sol";

// 1. 繼承 UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable
contract MiniBankV1 is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, IMiniBank {
    
    // --- 儲存變數 (Storage Layout) ---
    // 所有的狀態變數都應該在頂層合約定義，並嚴格保持順序
    // 即使 V2 不使用某些變數，也應保留其在 storage 中的位置。
    
    // Slot 0 - 帳戶餘額 (核心數據)
    mapping(address => uint256) private _balances;

    // Slot 1 - 管理員 (繼承自 OwnableUpgradeable)
    // Slot 2 - 暫停狀態 (繼承自 PausableUpgradeable)
    // Slot 3 - 升級授權狀態 (繼承自 UUPSUpgradeable)

    // ---------------------------------

    /// @custom:storage-layout-manual
    /// Type: uint256
    /// Slot: 0
    mapping(address => uint256) public balances; // 這裡我們使用一個公共的名稱來保持慣例，實際數據是 _balances
    
    // ---------------------------------

    // 為了安全，使用 `initialize` 替代 `constructor`
    function initialize(address initialAdmin) public initializer {
        __Ownable_init(initialAdmin);   // 設置管理員
        __Pausable_init();             // 初始化 Pausable
        __UUPSUpgradeable_init();      // 初始化 UUPS
        // 其他 V1 的初始化 (例如：設置預設值，但 V1 沒有)
    }

    // --- UUPS 升級授權 ---
    // 只有管理員可以授權升級
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // UUPS 內建的機制會確保只有通過此函式檢查的呼叫才能觸發升級。
        // 我們卦一個 onlyOwner 檢查就夠了
    }

    // --- 業務邏輯 ---

    // 存入 ETH
    function deposit() external payable whenNotPaused {
        _balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // 提取自己的 ETH
    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(_balances[msg.sender] >= amount, "Insufficient balance");

        _balances[msg.sender] -= amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit Withdraw(msg.sender, amount);
    }

    // 顯示用戶餘額
    function getBalance(address user) external view override returns (uint256) {
        return _balances[user];
    }

    // 系統管理員功能
    
    // 暫停系統 (使用 Pausable 的 internal 函數)
    function pause() external onlyOwner override {
        _pause();
    }

    // 恢復系統 (使用 Pausable 的 internal 函數)
    function unpause() external onlyOwner override {
        _unpause();
    }
    
    // 檢查是否為管理員
    function isAdmin() external view returns (bool) {
        return owner() == msg.sender;
    }

    // 檢查是否暫停
    function isPaused() external view returns (bool) {
        return paused();
    }
    
    // 實現升級功能（Proxy 會調用此函數）
    // 注意：這裡我們使用 UUPSUpgradeable 提供的 `_upgradeToAndCall`，但我們需要一個外部可調用的入口。
    // 在 UUPS 中，升級邏輯通常被封裝在 `UUPSUpgradeable` 內，我們只需實現 `_authorizeUpgrade` 即可。
    // OpenZeppelin 的代理合約會提供一個名為 `upgradeTo(address newImplementation)` 的外部函數。
    // 但是，為了完整性，我們可以在 V1 中定義一個 Proxy 代理層會呼叫的函數 (雖然實際上我們通常直接使用 Proxy 的 `upgradeTo`)
    function upgradeTo(address newImplementation) external override onlyOwner {
        upgradeToAndCall(newImplementation, bytes(""));
    }
}// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IMiniBank.sol";

// 1. 繼承 UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable
contract MiniBankV1 is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, IMiniBank {
    
    // --- 儲存變數 (Storage Layout) ---
    // 所有的狀態變數都應該在頂層合約定義，並嚴格保持順序
    // 即使 V2 不使用某些變數，也應保留其在 storage 中的位置。
    
    // Slot 0 - 帳戶餘額 (核心數據)
    mapping(address => uint256) private _balances;

    // Slot 1 - 管理員 (繼承自 OwnableUpgradeable)
    // Slot 2 - 暫停狀態 (繼承自 PausableUpgradeable)
    // Slot 3 - 升級授權狀態 (繼承自 UUPSUpgradeable)

    // ---------------------------------

    /// @custom:storage-layout-manual
    /// Type: uint256
    /// Slot: 0
    mapping(address => uint256) public balances; // 這裡我們使用一個公共的名稱來保持慣例，實際數據是 _balances
    
    // ---------------------------------

    // 為了安全，使用 `initialize` 替代 `constructor`
    function initialize(address initialAdmin) public initializer {
        __Ownable_init(initialAdmin);   // 設置管理員
        __Pausable_init();             // 初始化 Pausable
        __UUPSUpgradeable_init();      // 初始化 UUPS
        // 其他 V1 的初始化 (例如：設置預設值，但 V1 沒有)
    }

    // --- UUPS 升級授權 ---
    // 只有管理員可以授權升級
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // UUPS 內建的機制會確保只有通過此函式檢查的呼叫才能觸發升級。
        // 我們卦一個 onlyOwner 檢查就夠了
    }

    // --- 業務邏輯 ---

    // 存入 ETH
    function deposit() external payable whenNotPaused {
        _balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // 提取自己的 ETH
    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(_balances[msg.sender] >= amount, "Insufficient balance");

        _balances[msg.sender] -= amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit Withdraw(msg.sender, amount);
    }

    // 顯示用戶餘額
    function getBalance(address user) external view override returns (uint256) {
        return _balances[user];
    }

    // 系統管理員功能
    
    // 暫停系統 (使用 Pausable 的 internal 函數)
    function pause() external onlyOwner override {
        _pause();
    }

    // 恢復系統 (使用 Pausable 的 internal 函數)
    function unpause() external onlyOwner override {
        _unpause();
    }
    
    // 檢查是否為管理員
    function isAdmin() external view returns (bool) {
        return owner() == msg.sender;
    }

    // 檢查是否暫停
    function isPaused() external view returns (bool) {
        return paused();
    }
    
    // 實現升級功能（Proxy 會調用此函數）
    // 注意：這裡我們使用 UUPSUpgradeable 提供的 `_upgradeToAndCall`，但我們需要一個外部可調用的入口。
    // 在 UUPS 中，升級邏輯通常被封裝在 `UUPSUpgradeable` 內，我們只需實現 `_authorizeUpgrade` 即可。
    // OpenZeppelin 的代理合約會提供一個名為 `upgradeTo(address newImplementation)` 的外部函數。
    // 但是，為了完整性，我們可以在 V1 中定義一個 Proxy 代理層會呼叫的函數 (雖然實際上我們通常直接使用 Proxy 的 `upgradeTo`)
    function upgradeTo(address newImplementation) external override onlyOwner {
        upgradeToAndCall(newImplementation, bytes(""));
    }
}