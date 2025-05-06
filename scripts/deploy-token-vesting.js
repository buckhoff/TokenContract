// scripts/deploy-token-staking.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TokenVesting with the account:", deployer.address);

    let totalGas = 0n;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress) {
        console.error("Please set TOKEN_ADDRESS in your .env file");
        return;
    }

    // Deploy the TokenStaking contract
    const TokenVesting = await ethers.getContractFactory("TeachTokenVesting");
    const vesting = await upgrades.deployProxy(TokenVesting,[teachTokenAddress],{initializer: 'initialize' });

    await vesting.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(vesting.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const vestingAddress = await vesting.getAddress();
    console.log("TeachTokenVesting deployed to:", vestingAddress);
    
    console.log("TeachTokenVesting initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for TeachTokenVesting...");
        const setRegistryTx = await vesting.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for TeachTokenVesting");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));

        console.log("Registering TeachTokenVesting in Registry...");
        const registerTx = await registry.registerContract(VESTING_NAME, vestingAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("TeachTokenVesting registered in Registry");
    }

    console.log("Gas used:",totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TOKEN_VESTING_ADDRESS=${vestingAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });