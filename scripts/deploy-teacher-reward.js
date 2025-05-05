// scripts/deploy-teacher-reward.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying TeacherReward with the account:", deployer.address);

    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress) {
        console.error("Please set TOKEN_ADDRESS in your .env file");
        return;
    }
    
    // Initialize the teacher reward contract with parameters
    const baseRewardRate = ethers.parseEther("10"); // 10 tokens per day
    const reputationMultiplier = 100; // 1x multiplier
    const maxDailyReward = ethers.parseEther("100"); // 100 tokens max per day
    const minimumClaimPeriod = 7 * 24 * 60 * 60; // 7 days in seconds
    
    // Deploy the TeacherReward contract
    const TeacherReward = await ethers.getContractFactory("TeacherReward");
    const teacherReward = await upgrades.deployProxy(TeacherReward,[ teachTokenAddress,
        baseRewardRate,
        reputationMultiplier,
        maxDailyReward,
        minimumClaimPeriod],{ initializer: 'initialize' });

    await teacherReward.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(teacherReward.deploymentTransaction().hash);
    console.log("Gas used:", deploymentTx.gasUsed.toString());
    const teacherRewardAddress = await teacherReward.getAddress();
    console.log("TeacherReward deployed to:", teacherRewardAddress);

    //console.log("Initializing TeacherReward...");
    //const initTx = await teacherReward.initialize(
    //    teachTokenAddress,
    //    baseRewardRate,
   //     reputationMultiplier,
    //    maxDailyReward,
  //      minimumClaimPeriod
  //  );
  //  await initTx.wait();
    console.log("TeacherReward initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for TeacherReward...");
        const setRegistryTx = await teacherReward.setRegistry(registryAddress);
        await setRegistryTx.wait();
        console.log("Registry set for TeacherReward");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const TEACHER_REWARD_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACHER_REWARD"));

        console.log("Registering TeacherReward in Registry...");
        const registerTx = await registry.registerContract(TEACHER_REWARD_NAME, teacherRewardAddress, "0x00000000");
        await registerTx.wait();
        console.log("TeacherReward registered in Registry");
    }

    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TEACHER_REWARD_ADDRESS=${teacherRewardAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });