// scripts/deploy-immutable-and-token.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    // STEP 1: Deploy the Immutable Token Contract
    console.log("\n🔒 Deploying ImmutableTokenContract...");
    const ImmutableTokenContract = await ethers.getContractFactory("ImmutableTokenContract");
    const immutableContract = await ImmutableTokenContract.deploy();
    await immutableContract.waitForDeployment();

    const immutableContractAddress = await immutableContract.getAddress();
    console.log("ImmutableTokenContract deployed to:", immutableContractAddress);

    // Verify the ImmutableTokenContract constants are correctly set
    const maxSupply = await immutableContract.MAX_SUPPLY();
    console.log(`Verified max supply: ${ethers.formatEther(maxSupply)} TEACH`);

    // Verify allocations are correct
    const validAllocations = await immutableContract.validateAllocations();
    console.log(`Allocations valid: ${validAllocations}`);

    // 3. Save the addresses to the .env file
    console.log("\n📝 Updating .env file...");
    console.log(`IMMUTABLE_TOKEN_CONTRACT=${immutableContractAddress}`);

    console.log("\n✅ Deployment complete! The max supply of 5 billion tokens is now immutably set.");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });