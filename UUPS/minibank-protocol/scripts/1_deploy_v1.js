const { ethers, upgrades } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    const adminAddress = deployer.address;

    console.log("Deploying MiniBankV1 with the account:", adminAddress);

    // 1. 部署 MiniBankV1 (Implementation)
    const MiniBankV1 = await ethers.getContractFactory("MiniBankV1");

    // 2. 部署 UUPS Proxy，並調用 initialize 函數
    // 這裡，upgrades.deployProxy 會自動完成：
    // a. 部署 MiniBankV1 實現合約
    // b. 部署 ERC1967Proxy 代理合約
    // c. 在 Proxy 上調用 initialize(adminAddress)
    const proxy = await upgrades.deployProxy(MiniBankV1, [adminAddress], {
        kind: "uups", // 指定使用 UUPS 模式
        initializer: "initialize" // 指定初始化函數名稱
    });

    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();

    console.log("MiniBankV1 Implementation deployed to:", await upgrades.erc1967.getImplementationAddress(proxyAddress));
    console.log("MiniBankV1 Proxy deployed to:", proxyAddress);
    console.log("Admin set to:", adminAddress);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});