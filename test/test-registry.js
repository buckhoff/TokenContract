// scripts/test-registry.js - A script to get all registered contracts from the registry
const { ethers } = require("hardhat");
require('dotenv').config();

async function main() {
    console.log("Testing Contract Registry...");

    // Get the registry address from .env
    const registryAddress = process.env.REGISTRY_ADDRESS;
    if (!registryAddress) {
        console.error("❌ REGISTRY_ADDRESS not found in .env file!");
        return;
    }

    try {
        // Get the contract registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = await ContractRegistry.attach(registryAddress);

        console.log(`✅ Connected to Registry at ${registryAddress}`);

        // Get all contract names with better error handling
        
        try {
            const contractNamesBytes32 = await registry.getAllContractNames();
            console.log(contractNamesBytes32.length);
            console.log(`✅ Found ${contractNamesBytes32.length} registered contracts`);
        } catch (error) {
            console.log(`❌ Error calling getAllContractNames(): ${error.message}`);
            console.log("Attempting alternative methods to verify registry functionality...");

            // Check if this is the expected registry interface
            try {
                const systemPaused = await registry.isSystemPaused();
                console.log(`✅ Registry responds to isSystemPaused(): ${systemPaused}`);
            } catch (e) {
                console.log(`❌ Error calling isSystemPaused(): ${e.message}`);
                console.log("This might not be a valid ContractRegistry instance at the provided address.");
                return;
            }

            // The registry exists but might be empty
            console.log("✅ Registry contract exists but may not have any registered contracts.");
            return;
        }

        if (contractNamesBytes32.length === 0) {
            console.log("⚠️ No contracts registered in the registry yet.");
            return;
        }

        // Create a table to display the results
        console.log("\n📋 Registered Contracts:");
        console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        console.log("| Contract Name        | Address                                    | Version | Active |");
        console.log("|---------------------|--------------------------------------------|---------|---------");

        // For each contract, get its details
        for (const nameBytes32 of contractNamesBytes32) {
            try {
                // Get contract information
                const address = await registry.getContractAddress(nameBytes32);
                const version = await registry.getContractVersion(nameBytes32);
                const isActive = await registry.isContractActive(nameBytes32);

                // Convert bytes32 to string (attempting to decode if it's a readable string)
                let contractName = nameBytes32;
                try {
                    // Try to convert from bytes32 to string
                    contractName = ethers.utils.parseBytes32String(nameBytes32);
                } catch (e) {
                    // If it fails, use the bytes32 representation
                    contractName = nameBytes32;
                }

                // Truncate long names
                const displayName = contractName.length > 20
                    ? contractName.substring(0, 17) + "..."
                    : contractName.padEnd(20);

                // Print row
                console.log(`| ${displayName} | ${address} | ${version.toString().padStart(7)} | ${isActive ? '  Yes  ' : '  No   '} |`);
            } catch (error) {
                console.log(`| ${nameBytes32} | Error: ${error.message.substring(0, 40)}... |`);
            }
        }

        console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

        // Check if system is paused
        const isPaused = await registry.isSystemPaused();
        console.log(`\n🔐 System Pause Status: ${isPaused ? '⚠️ PAUSED' : '✅ ACTIVE'}`);

        // Try directly checking for specific contracts we expect to exist
        console.log("\n🔍 Testing direct contract lookups:");

        // Common contract name constants (from Constants.sol)
        const contractsToCheck = [
            "TEACH_TOKEN",
            "PLATFORM_STABILITY_FUND",
            "TOKEN_STAKING",
            "PLATFORM_GOVERNANCE",
            "PLATFORM_MARKETPLACE",
            "PLATFORM_REWARD",
            "TOKEN_CROWDSALE",
            "TOKEN_VESTING"
        ];

        // Convert strings to bytes32 for testing
        for (const contractName of contractsToCheck) {
            try {
                // Convert string to bytes32 by hashing (similar to what Constants.sol does)
                const nameBytes32 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(contractName));

                // Check if it exists
                const exists = await registry.isContractActive(nameBytes32);

                if (exists) {
                    const address = await registry.getContractAddress(nameBytes32);
                    const version = await registry.getContractVersion(nameBytes32);
                    console.log(`✅ ${contractName.padEnd(25)} Found at: ${address} (v${version})`);
                } else {
                    console.log(`❌ ${contractName.padEnd(25)} Not found or not active`);
                }
            } catch (error) {
                console.log(`❌ ${contractName.padEnd(25)} Error: ${error.message.substring(0, 75)}...`);
            }
        }
    } catch (error) {
        console.error("❌ Error:", error);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });