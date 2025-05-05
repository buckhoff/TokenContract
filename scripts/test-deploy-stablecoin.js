// scripts/deploy-test-stablecoin.js
const { ethers } = require("hardhat");

async function main() {
    console.log("Deploying TestStablecoin...");
    
    // Mint some tokens to the deployer
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);
    
    // Create a simple ERC20 for testing
    const TestStablecoin = await ethers.getContractFactory("TestUSDC");
    const stablecoin = await TestStablecoin.deploy();

    await stablecoin.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(stablecoin.deploymentTransaction().hash);
    console.log("Gas used:", deploymentTx.gasUsed.toString());
    const stablecoinAddress = await stablecoin.getAddress();
    console.log("TestStablecoin deployed to:", stablecoinAddress);

    // Log total supply and deployer balance
    const totalSupply = await stablecoin.totalSupply();
    console.log("Total supply:", ethers.formatEther(totalSupply, 6), "tUSDC");

    const deployerBalance = await stablecoin.balanceOf(deployer.address);
    console.log("Deployer balance:", ethers.formatEther(deployerBalance, 6), "tUSDC");
    
    console.log("TestStablecoin initialized and minted to deployer");
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`STABLE_COIN_ADDRESS=${stablecoinAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });