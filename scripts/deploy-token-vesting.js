// scripts/deploy-token-staking.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TokenVesting with the account:", deployer.address);

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
    const vestingAddress = await vesting.getAddress();
    console.log("TokenStaking deployed to:", vestingAddress);
    
    console.log("TokenStaking initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for TokenVesting...");
        const setRegistryTx = await vesting.setRegistry(registryAddress);
        await setRegistryTx.wait();
        console.log("Registry set for TokenVesting");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));

        console.log("Registering TokenVesting in Registry...");
        const registerTx = await registry.registerContract(VESTING_NAME, stakingAddress, "0x00000000");
        await registerTx.wait();
        console.log("TokenVesting registered in Registry");
    }

    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TOKEN_VESTING_ADDRESS=${vestingAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });