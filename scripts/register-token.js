// scripts/register-token.js
const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;

    let totalGas = 0n;
    
    if (!registryAddress || !teachTokenAddress) {
        console.error("Please set REGISTRY_ADDRESS and TEACH_TOKEN_ADDRESS in your .env file");
        return;
    }

    // Get the ContractRegistry instance
    const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
    const registry = ContractRegistry.attach(registryAddress);

    // Create constants for contract name
    const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

    // Register the TeachToken contract
    console.log("Registering TeachToken in the Registry...");
    const tx = await registry.registerContract(TOKEN_NAME, teachTokenAddress, "0x00000000");
    const setRegistryReceipt = await tx.wait();
    totalGas += setRegistryReceipt.gasUsed;
    console.log("TeachToken registered successfully!");

    // Set registry in TeachToken
    const TeachToken = await ethers.getContractFactory("TeachToken");
    const teachToken = TeachToken.attach(teachTokenAddress);

    console.log("Setting Registry in TeachToken...");
    const setRegistryTx = await teachToken.setRegistry(registryAddress);
    const setRegistryTxReceipt =  await setRegistryTx.wait();
    totalGas += setRegistryTxReceipt.gasUsed;

    console.log("Gas used:",totalGas.toString());
    console.log("Registry set in TeachToken successfully!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });