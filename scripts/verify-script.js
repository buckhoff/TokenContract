// This script verifies your contract on Polygonscan after deployment
// Run with: npx hardhat run scripts/verify.js --network polygon

const hre = require("hardhat");
require("dotenv").config();

async function main() {
  // Replace with your deployed contract address
  const contractAddress = process.env.CONTRACT_ADDRESS;
  
  if (!contractAddress) {
    console.error("Please set CONTRACT_ADDRESS in your .env file");
    return;
  }

  console.log("Verifying contract on Polygonscan:", contractAddress);
  
  try {
    // Wait for 60 seconds to ensure the contract is properly propagated on the blockchain
    console.log("Waiting 60 seconds before verification...");
    await new Promise(resolve => setTimeout(resolve, 60000));
    
    // Verify the contract on Polygonscan
    await hre.run("verify:verify", {
      address: contractAddress,
      constructorArguments: [],
      contract: "contracts/TeachToken.sol:TeachToken"
    });
    
    console.log("Contract verified successfully on Polygonscan!");
  } catch (error) {
    console.error("Error during verification:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
