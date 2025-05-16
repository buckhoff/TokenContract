// scripts/deploy-dex-registry.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying DexRegistry with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    // Deploy the DexRegistry
    console.log("Deploying DexRegistry...");
    const DexRegistry = await ethers.getContractFactory("DexRegistry");
    const dexRegistry = await upgrades.deployProxy(DexRegistry, [], { initializer: 'initialize' });

    await dexRegistry.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(dexRegistry.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const dexRegistryAddress = await dexRegistry.getAddress();
    console.log("DexRegistry deployed to:", dexRegistryAddress);

    // Set main registry if available
    if (registryAddress) {
        console.log("Setting Registry for DexRegistry...");
        const setRegistryTx = await dexRegistry.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for DexRegistry");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const DEX_REGISTRY_NAME = ethers.keccak256(ethers.toUtf8Bytes("DEX_REGISTRY"));

        console.log("Registering DexRegistry in Registry...");
        const registerTx = await registry.registerContract(DEX_REGISTRY_NAME, dexRegistryAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("DexRegistry registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`DEX_REGISTRY_ADDRESS=${dexRegistryAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });