// scripts/deploy-registry.js
const { ethers,upgrades } = require("hardhat");

async function main() {
    console.log("Deploying ContractRegistry...");

    const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
    console.log("deployProxy exists:", upgrades);
    const registry = await upgrades.deployProxy(ContractRegistry, [], { initializer: 'initialize' });

    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();
    console.log("ContractRegistry deployed to:", registryAddress);

    // Initialize the registry
    //const initTx = await registry.initialize();
    //await initTx.wait();
    //console.log("ContractRegistry initialized");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });