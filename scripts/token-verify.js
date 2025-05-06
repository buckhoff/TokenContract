// scripts/verify-teachtoken.js
const hre = require("hardhat");
require("dotenv").config();

async function main() {
  const contractAddress = process.env.TOKEN_ADDRESS;

  if (!contractAddress) {
    console.error("Please set TOKEN_ADDRESS in your .env file");
    return;
  }

  console.log("Verifying TeachToken on Etherscan:", contractAddress);

  try {
    // Wait for 60 seconds to ensure the contract is properly propagated on the blockchain
    console.log("Waiting 60 seconds before verification...");
    await new Promise(resolve => setTimeout(resolve, 60000));

    // Verify the contract on Etherscan
    await hre.run("verify:verify", {
      address: contractAddress,
      constructorArguments: [],
      contract: "contracts/TeachToken.sol:TeachToken"
    });

    console.log("TeachToken verified successfully on Etherscan!");
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