// scripts/deploy-token-staking.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TokenStaking with the account:", deployer.address);

    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress) {
        console.error("Please set TOKEN_ADDRESS in your .env file");
        return;
    }

    // Deploy the TokenStaking contract
    const TokenStaking = await ethers.getContractFactory("TokenStaking");
    const staking = await upgrades.deployProxy(TokenStaking,[teachTokenAddress, deployer.address],{initializer: 'initialize' });

    await staking.waitForDeployment();
    const stakingAddress = await staking.getAddress();
    console.log("TokenStaking deployed to:", stakingAddress);

    // Initialize the staking contract
    //console.log("Initializing TokenStaking...");
    //const initTx = await staking.initialize(
    //    teachTokenAddress,
    //    deployer.address // Platform rewards manager (for now)
    //);
   // await initTx.wait();
    console.log("TokenStaking initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for TokenStaking...");
        const setRegistryTx = await staking.setRegistry(registryAddress);
        await setRegistryTx.wait();
        console.log("Registry set for TokenStaking");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));

        console.log("Registering TokenStaking in Registry...");
        const registerTx = await registry.registerContract(STAKING_NAME, stakingAddress, "0x00000000");
        await registerTx.wait();
        console.log("TokenStaking registered in Registry");
    }

    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TOKEN_STAKING_ADDRESS=${stakingAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });