// scripts/deploy-teach-token.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    // Get the deployer account
    const [deployer] = await ethers.getSigners();

    let totalGas = 0n;
    console.log("Deploying contracts with the account:", deployer.address);
    console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

    // Deploy the TEACH token contract
    console.log("Deploying TeachToken...");
    const TeachToken = await ethers.getContractFactory("TeachToken");
    const teachToken = await upgrades.deployProxy(TeachToken,[],{ initializer: 'initialize' });

    await teachToken.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(teachToken.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const teachTokenAddress = await teachToken.getAddress();
    console.log("TeachToken deployed to:", teachTokenAddress);

    // Initialize the token
    //console.log("Initializing TeachToken...");
    //const initTx = await teachToken.initialize();
    //await initTx.wait();
    console.log("TeachToken initialized");

    // Get wallet addresses for initial distribution
    const platformEcosystemAddress = process.env.PLATFORM_ECOSYSTEM_ADDRESS || deployer.address;
    const communityIncentivesAddress = process.env.COMMUNITY_INCENTIVES_ADDRESS || deployer.address;
    const initialLiquidityAddress = process.env.INITIAL_LIQUIDITY_ADDRESS || deployer.address;
    const publicPresaleAddress = process.env.PUBLIC_PRESALE_ADDRESS || deployer.address;
    const teamAndDevAddress = process.env.TEAM_DEV_ADDRESS || deployer.address;
    const educationalPartnersAddress = process.env.EDUCATIONAL_PARTNERS_ADDRESS || deployer.address;
    const reserveAddress = process.env.RESERVE_ADDRESS || deployer.address;

    // Perform initial token distribution
    console.log("Performing initial token distribution...");

    const tx = await teachToken.performInitialDistribution(
        platformEcosystemAddress,
        communityIncentivesAddress,
        initialLiquidityAddress,
        publicPresaleAddress,
        teamAndDevAddress,
        educationalPartnersAddress,
        reserveAddress
    );

    console.log("Initial distribution transaction hash:", tx.hash);
    const receipt = await tx.wait();
    console.log("Initial distribution complete!");
    totalGas += receipt.gasUsed;

    // Verify initial distribution
    const totalSupply = await teachToken.totalSupply();
    console.log("Total supply:", ethers.formatEther(totalSupply), "TEACH");

    console.log("Gas used:",totalGas.toString());
    
    // Save this address for later use
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`TEACH_TOKEN_ADDRESS=${teachTokenAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });