// scripts/deploy-liquidity-provisioner.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying LiquidityProvisioner with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const stableCoinAddress = process.env.STABLE_COIN_ADDRESS;
    const dexRegistryAddress = process.env.DEX_REGISTRY_ADDRESS;

    if (!teachTokenAddress || !stableCoinAddress) {
        console.error("Please set TOKEN_ADDRESS and STABLE_COIN_ADDRESS in your .env file");
        return;
    }

    if (!dexRegistryAddress) {
        console.error("Please set DEX_REGISTRY_ADDRESS in your .env file");
        return;
    }

    // Initial target price for token ($0.12)
    const initialTargetPrice = ethers.parseUnits("0.12", 6);

    // Deploy the LiquidityProvisioner
    console.log("Deploying LiquidityProvisioner...");
    const LiquidityProvisioner = await ethers.getContractFactory("LiquidityProvisioner");
    const liquidityProvisioner = await upgrades.deployProxy(LiquidityProvisioner, [
        teachTokenAddress,
        stableCoinAddress,
        dexRegistryAddress,
        initialTargetPrice
    ], { initializer: 'initialize' });

    await liquidityProvisioner.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(liquidityProvisioner.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const liquidityProvisionerAddress = await liquidityProvisioner.getAddress();
    console.log("LiquidityProvisioner deployed to:", liquidityProvisionerAddress);

    // Set main registry if available
    if (registryAddress) {
        console.log("Setting Registry for LiquidityProvisioner...");
        const setRegistryTx = await liquidityProvisioner.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for LiquidityProvisioner");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const LIQUIDITY_PROVISIONER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_PROVISIONER"));

        console.log("Registering LiquidityProvisioner in Registry...");
        const registerTx = await registry.registerContract(LIQUIDITY_PROVISIONER_NAME, liquidityProvisionerAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("LiquidityProvisioner registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`LIQUIDITY_PROVISIONER_ADDRESS=${liquidityProvisionerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });