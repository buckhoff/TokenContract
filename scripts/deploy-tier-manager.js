// scripts/deploy-tier-manager.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TierManager with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const crowdsaleAddress = process.env.TOKEN_CROWDSALE_ADDRESS;

    // Deploy the TierManager
    console.log("Deploying TierManager...");
    const TierManager = await ethers.getContractFactory("TierManager");
    const tierManager = await upgrades.deployProxy(TierManager, [], { initializer: 'initialize' });

    await tierManager.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(tierManager.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const tierManagerAddress = await tierManager.getAddress();
    console.log("TierManager deployed to:", tierManagerAddress);

    // Set crowdsale address if available
    if (crowdsaleAddress) {
        console.log("Setting Crowdsale for TierManager...");
        const setCrowdsaleTx = await tierManager.setCrowdsale(crowdsaleAddress);
        const setCrowdsaleReceipt = await setCrowdsaleTx.wait();
        totalGas += setCrowdsaleReceipt.gasUsed;
        console.log("Crowdsale set for TierManager");

        // Set TierManager in Crowdsale if needed
        try {
            const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
            const crowdsale = TokenCrowdSale.attach(crowdsaleAddress);
            await crowdsale.setTierManager(tierManagerAddress);
            console.log("TierManager set in TokenCrowdSale");
        } catch (error) {
            console.warn("Could not set TierManager in Crowdsale:", error.message);
        }
    }

    // Set main registry if available
    if (registryAddress) {
        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const TIER_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER"));

        console.log("Registering TierManager in Registry...");
        const registerTx = await registry.registerContract(TIER_MANAGER_NAME, tierManagerAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("TierManager registered in Registry");
    }

    // Configure default presale tiers
    console.log("Tiers initialized with default configuration");

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TIER_MANAGER_ADDRESS=${tierManagerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });