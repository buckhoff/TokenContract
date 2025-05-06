// scripts/deploy-governance.js
const { ethers, upgrades} = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying PlatformGovernance with the account:", deployer.address);

    let totalGas = 0n;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress) {
        console.error("Please set TOKEN_ADDRESS in your .env file");
        return;
    }
    // Initialize the governance contract with parameters
    const proposalThreshold = ethers.parseEther("100000"); // 100k tokens to create proposal
    const minVotingPeriod = 3 * 24 * 60 * 60; // 3 days in seconds
    const maxVotingPeriod = 7 * 24 * 60 * 60; // 7 days in seconds
    const quorumThreshold = 400; // 4% of total supply
    const executionDelay = 2 * 24 * 60 * 60; // 2 days in seconds
    const executionPeriod = 3 * 24 * 60 * 60; // 3 days in seconds
    
    // Deploy the PlatformGovernance contract
    const PlatformGovernance = await ethers.getContractFactory("PlatformGovernance");
    const governance = await upgrades.deployProxy(PlatformGovernance,[teachTokenAddress, proposalThreshold, minVotingPeriod, maxVotingPeriod, quorumThreshold, executionDelay, executionPeriod], { initializer: 'initialize' });

    await governance.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(governance.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const governanceAddress = await governance.getAddress();
    console.log("PlatformGovernance deployed to:", governanceAddress);



   // console.log("Initializing PlatformGovernance...");
    //const initTx = await governance.initialize(
    //    teachTokenAddress,
    //    proposalThreshold,
   //     minVotingPeriod,
   //     maxVotingPeriod,
   //     quorumThreshold,
   //     executionDelay,
   //     executionPeriod
   // );
   // await initTx.wait();
    console.log("PlatformGovernance initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for PlatformGovernance...");
        const setRegistryTx = await governance.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for PlatformGovernance");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const GOVERNANCE_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_GOVERNANCE"));

        console.log("Registering PlatformGovernance in Registry...");
        const registerTx = await registry.registerContract(GOVERNANCE_NAME, governanceAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("PlatformGovernance registered in Registry");
    }

    console.log("Gas used:",totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`PLATFORM_GOVERNANCE_ADDRESS=${governanceAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });