// scripts/deploy-crowdsale-updated.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TokenCrowdSale with the account:", deployer.address);

    let totalGas = 0n;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const stableCoinAddress = process.env.STABLE_COIN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const treasuryAddress = process.env.TREASURY_ADDRESS || deployer.address;
    const tierManagerAddress = process.env.TIER_MANAGER_ADDRESS;
    const emergencyManagerAddress = process.env.EMERGENCY_MANAGER_ADDRESS;

    if (!teachTokenAddress || !stableCoinAddress) {
        console.error("Please set TOKEN_ADDRESS and STABLE_COIN_ADDRESS in your .env file");
        return;
    }

    // Deploy the TokenCrowdSale contract
    const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
    const crowdsale = await upgrades.deployProxy(TokenCrowdSale, [
        stableCoinAddress,
        treasuryAddress
    ], { initializer: 'initialize' });

    await crowdsale.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(crowdsale.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const crowdsaleAddress = await crowdsale.getAddress();
    console.log("TokenCrowdSale deployed to:", crowdsaleAddress);
    console.log("TokenCrowdSale initialized");

    // Set the sale token
    console.log("Setting TEACH token as sale token...");
    const setTokenTx = await crowdsale.setSaleToken(teachTokenAddress);
    const setTokenReceipt = await setTokenTx.wait();
    totalGas += setTokenReceipt.gasUsed;
    console.log("Sale token set successfully");

    // Set TierManager if available
    if (tierManagerAddress) {
        console.log("Setting TierManager for TokenCrowdSale...");
        const setTierManagerTx = await crowdsale.setTierManager(tierManagerAddress);
        const setTierManagerReceipt = await setTierManagerTx.wait();
        totalGas += setTierManagerReceipt.gasUsed;
        console.log("TierManager set successfully");

        // Set Crowdsale in TierManager
        const TierManager = await ethers.getContractFactory("TierManager");
        const tierManager = TierManager.attach(tierManagerAddress);
        await tierManager.setCrowdsale(crowdsaleAddress);
        console.log("Crowdsale set in TierManager");
    }

    // Set EmergencyManager if available
    if (emergencyManagerAddress) {
        console.log("Setting EmergencyManager for TokenCrowdSale...");
        const setEmergencyManagerTx = await crowdsale.setEmergencyManager(emergencyManagerAddress);
        const setEmergencyManagerReceipt = await setEmergencyManagerTx.wait();
        totalGas += setEmergencyManagerReceipt.gasUsed;
        console.log("EmergencyManager set successfully");

        // Set Crowdsale in EmergencyManager
        const EmergencyManager = await ethers.getContractFactory("EmergencyManager");
        const emergencyManager = EmergencyManager.attach(emergencyManagerAddress);
        await emergencyManager.setCrowdsale(crowdsaleAddress);
        console.log("Crowdsale set in EmergencyManager");
    }

    // Set presale times (example: start in 1 day, end in 30 days)
    const now = Math.floor(Date.now() / 1000);
    const startTime = now + (24 * 60 * 60); // 1 day from now
    const endTime = now + (30 * 24 * 60 * 60); // 30 days from now

    console.log("Setting presale times...");
    const setTimesTx = await crowdsale.setPresaleTimes(startTime, endTime);
    const setTimesReceipt = await setTimesTx.wait();
    totalGas += setTimesReceipt.gasUsed;
    console.log("Presale times set successfully");

    // Activate first tier if TierManager is set
    if (tierManagerAddress) {
        console.log("Activating first tier...");
        const TierManager = await ethers.getContractFactory("TierManager");
        const tierManager = TierManager.attach(tierManagerAddress);
        const activateTierTx = await tierManager.setTierStatus(0, true);
        const activateTierReceipt = await activateTierTx.wait();
        totalGas += activateTierReceipt.gasUsed;
        console.log("First tier activated");
    }

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for TokenCrowdSale...");
        const setRegistryTx = await crowdsale.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for TokenCrowdSale");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const CROWDSALE_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_CROWDSALE"));

        console.log("Registering TokenCrowdSale in Registry...");
        const registerTx = await registry.registerContract(CROWDSALE_NAME, crowdsaleAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("TokenCrowdSale registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TOKEN_CROWDSALE_ADDRESS=${crowdsaleAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });