// scripts/deploy-emergency-manager.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying EmergencyManager with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const crowdsaleAddress = process.env.TOKEN_CROWDSALE_ADDRESS;

    // Deploy the EmergencyManager
    console.log("Deploying EmergencyManager...");
    const EmergencyManager = await ethers.getContractFactory("EmergencyManager");
    const emergencyManager = await upgrades.deployProxy(EmergencyManager, [], { initializer: 'initialize' });

    await emergencyManager.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(emergencyManager.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const emergencyManagerAddress = await emergencyManager.getAddress();
    console.log("EmergencyManager deployed to:", emergencyManagerAddress);

    // Set crowdsale address if available
    if (crowdsaleAddress) {
        console.log("Setting Crowdsale for EmergencyManager...");
        const setCrowdsaleTx = await emergencyManager.setCrowdsale(crowdsaleAddress);
        const setCrowdsaleReceipt = await setCrowdsaleTx.wait();
        totalGas += setCrowdsaleReceipt.gasUsed;
        console.log("Crowdsale set for EmergencyManager");

        // Set EmergencyManager in Crowdsale if needed
        try {
            const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
            const crowdsale = TokenCrowdSale.attach(crowdsaleAddress);
            await crowdsale.setEmergencyManager(emergencyManagerAddress);
            console.log("EmergencyManager set in TokenCrowdSale");
        } catch (error) {
            console.warn("Could not set EmergencyManager in Crowdsale:", error.message);
        }
    }

    // Set main registry if available
    if (registryAddress) {
        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));

        console.log("Registering EmergencyManager in Registry...");
        const registerTx = await registry.registerContract(EMERGENCY_MANAGER_NAME, emergencyManagerAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("EmergencyManager registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`EMERGENCY_MANAGER_ADDRESS=${emergencyManagerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });