// This script is for deploying the TEACH token contract using Hardhat
// Install dependencies first: npm install --save-dev hardhat @nomiclabs/hardhat-ethers ethers @nomiclabs/hardhat-waffle hardhat-deploy dotenv

const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());

  // Deploy the TEACH token contract
  console.log("Deploying TeachToken...");
  const TeachToken = await ethers.getContractFactory("TeachToken");
  const teachToken = await TeachToken.deploy();
  
  await teachToken.deployed();
  console.log("TeachToken deployed to:", teachToken.address);
  
  // Get wallet addresses for initial distribution
  // In a production deployment, these should be securely managed multisig wallets
  const platformEcosystemAddress = process.env.PLATFORM_ECOSYSTEM_ADDRESS || deployer.address;
  const communityIncentivesAddress = process.env.COMMUNITY_INCENTIVES_ADDRESS || deployer.address;
  const initialLiquidityAddress = process.env.INITIAL_LIQUIDITY_ADDRESS || deployer.address;
  const publicPresaleAddress = process.env.PUBLIC_PRESALE_ADDRESS || deployer.address;
  const teamAndDevAddress = process.env.TEAM_DEV_ADDRESS || deployer.address;
  const educationalPartnersAddress = process.env.EDUCATIONAL_PARTNERS_ADDRESS || deployer.address;
  const reserveAddress = process.env.RESERVE_ADDRESS || deployer.address;
  
  // Perform initial token distribution
  console.log("Performing initial token distribution...");
  
  // Wait a bit to ensure contract is fully deployed
  await new Promise(resolve => setTimeout(resolve, 3000));
  
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
  await tx.wait();
  console.log("Initial distribution complete!");
  
  // Verify initial distribution
  const totalSupply = await teachToken.totalSupply();
  console.log("Total supply:", ethers.utils.formatEther(totalSupply), "TEACH");
  
  // Log allocation balances
  const platformBalance = await teachToken.balanceOf(platformEcosystemAddress);
  console.log("Platform Ecosystem:", ethers.utils.formatEther(platformBalance), "TEACH (32%)");
  
  const communityBalance = await teachToken.balanceOf(communityIncentivesAddress);
  console.log("Community Incentives:", ethers.utils.formatEther(communityBalance), "TEACH (22%)");
  
  const liquidityBalance = await teachToken.balanceOf(initialLiquidityAddress);
  console.log("Initial Liquidity:", ethers.utils.formatEther(liquidityBalance), "TEACH (14%)");
  
  const presaleBalance = await teachToken.balanceOf(publicPresaleAddress);
  console.log("Public Presale:", ethers.utils.formatEther(presaleBalance), "TEACH (10%)");
  
  const teamBalance = await teachToken.balanceOf(teamAndDevAddress);
  console.log("Team & Development:", ethers.utils.formatEther(teamBalance), "TEACH (10%)");
  
  const partnersBalance = await teachToken.balanceOf(educationalPartnersAddress);
  console.log("Educational Partners:", ethers.utils.formatEther(partnersBalance), "TEACH (8%)");
  
  const reserveBalance = await teachToken.balanceOf(reserveAddress);
  console.log("Reserve:", ethers.utils.formatEther(reserveBalance), "TEACH (4%)");
  
  // Log completion
  console.log("TEACH token deployment and distribution completed successfully!");
  console.log("Contract Address:", teachToken.address);
  console.log("Network:", network.name);
  console.log("Chain ID:", await teachToken.getChainId());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
