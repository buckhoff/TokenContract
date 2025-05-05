// scripts/deploy-marketplace.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying PlatformMarketplace with the account:", deployer.address);

    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress) {
        console.error("Please set TOKEN_ADDRESS in your .env file");
        return;
    }

    // Initialize the marketplace contract with parameters
    const feePercent = 300; // 3% platform fee
    
    // Deploy the PlatformMarketplace contract
    const PlatformMarketplace = await ethers.getContractFactory("PlatformMarketplace");
    const marketplace = await upgrades.deployProxy(PlatformMarketplace,[teachTokenAddress,
        feePercent,
        deployer.address], { initializer: 'initialize' });

    await marketplace.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(marketplace.deploymentTransaction().hash);
    console.log("Gas used:", deploymentTx.gasUsed.toString());
    const marketplaceAddress = await marketplace.getAddress();
    console.log("PlatformMarketplace deployed to:", marketplaceAddress);



    //console.log("Initializing PlatformMarketplace...");
    //const initTx = await marketplace.initialize(
    //    teachTokenAddress,
    //    feePercent,
     //   deployer.address // Fee recipient (for now)
    //);
    //await initTx.wait();
    console.log("PlatformMarketplace initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for PlatformMarketplace...");
        const setRegistryTx = await marketplace.setRegistry(registryAddress);
        await setRegistryTx.wait();
        console.log("Registry set for PlatformMarketplace");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const MARKETPLACE_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_MARKETPLACE"));

        console.log("Registering PlatformMarketplace in Registry...");
        const registerTx = await registry.registerContract(MARKETPLACE_NAME, marketplaceAddress, "0x00000000");
        await registerTx.wait();
        console.log("PlatformMarketplace registered in Registry");
    }

    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`PLATFORM_MARKETPLACE_ADDRESS=${marketplaceAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });