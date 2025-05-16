// scripts/deploy-liquidity-rebalancer.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying LiquidityRebalancer with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const dexRegistryAddress = process.env.DEX_REGISTRY_ADDRESS;
    const liquidityProvisionerAddress = process.env.LIQUIDITY_PROVISIONER_ADDRESS;

    if (!dexRegistryAddress || !liquidityProvisionerAddress) {
        console.error("Please set DEX_REGISTRY_ADDRESS and LIQUIDITY_PROVISIONER_ADDRESS in your .env file");
        return;
    }

    // Deploy the LiquidityRebalancer
    console.log("Deploying LiquidityRebalancer...");
    const LiquidityRebalancer = await ethers.getContractFactory("LiquidityRebalancer");
    const liquidityRebalancer = await upgrades.deployProxy(LiquidityRebalancer, [
        dexRegistryAddress,
        liquidityProvisionerAddress
    ], { initializer: 'initialize' });

    await liquidityRebalancer.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(liquidityRebalancer.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const liquidityRebalancerAddress = await liquidityRebalancer.getAddress();
    console.log("LiquidityRebalancer deployed to:", liquidityRebalancerAddress);

    // Set main registry if available
    if (registryAddress) {
        console.log("Setting Registry for LiquidityRebalancer...");
        const setRegistryTx = await liquidityRebalancer.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for LiquidityRebalancer");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const LIQUIDITY_REBALANCER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_REBALANCER"));

        console.log("Registering LiquidityRebalancer in Registry...");
        const registerTx = await registry.registerContract(LIQUIDITY_REBALANCER_NAME, liquidityRebalancerAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("LiquidityRebalancer registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`LIQUIDITY_REBALANCER_ADDRESS=${liquidityRebalancerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });