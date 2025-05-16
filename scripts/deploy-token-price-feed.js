// scripts/deploy-token-price-feed.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TokenPriceFeed with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const dexRegistryAddress = process.env.DEX_REGISTRY_ADDRESS;

    if (!dexRegistryAddress) {
        console.error("Please set DEX_REGISTRY_ADDRESS in your .env file");
        return;
    }

    // Deploy the TokenPriceFeed
    console.log("Deploying TokenPriceFeed...");
    const TokenPriceFeed = await ethers.getContractFactory("TokenPriceFeed");
    const tokenPriceFeed = await upgrades.deployProxy(TokenPriceFeed, [
        dexRegistryAddress,
        deployer.address // External price oracle - set to deployer for now
    ], { initializer: 'initialize' });

    await tokenPriceFeed.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(tokenPriceFeed.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const tokenPriceFeedAddress = await tokenPriceFeed.getAddress();
    console.log("TokenPriceFeed deployed to:", tokenPriceFeedAddress);

    // Set main registry if available
    if (registryAddress) {
        console.log("Setting Registry for TokenPriceFeed...");
        const setRegistryTx = await tokenPriceFeed.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for TokenPriceFeed");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const TOKEN_PRICE_FEED_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_PRICE_FEED"));

        console.log("Registering TokenPriceFeed in Registry...");
        const registerTx = await registry.registerContract(TOKEN_PRICE_FEED_NAME, tokenPriceFeedAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("TokenPriceFeed registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TOKEN_PRICE_FEED_ADDRESS=${tokenPriceFeedAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });