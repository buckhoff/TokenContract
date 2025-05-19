// scripts/deploy-liquidity-manager.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying LiquidityManager with the account:", deployer.address);

    let totalGas = 0n;
    const registryAddress = process.env.REGISTRY_ADDRESS;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const stableCoinAddress = process.env.STABLE_COIN_ADDRESS;
    const dexRegistryAddress = process.env.DEX_REGISTRY_ADDRESS;
    const tokenPriceFeedAddress = process.env.TOKEN_PRICE_FEED_ADDRESS;
    const liquidityProvisionerAddress = process.env.LIQUIDITY_PROVISIONER_ADDRESS;
    const liquidityRebalancerAddress = process.env.LIQUIDITY_REBALANCER_ADDRESS;

    if (!teachTokenAddress || !stableCoinAddress) {
        console.error("Please set TOKEN_ADDRESS and STABLE_COIN_ADDRESS in your .env file");
        return;
    }

    // Initial target price for token ($0.12)
    const initialTargetPrice = ethers.parseUnits("0.12", 6);

    // Deploy the LiquidityManager
    console.log("Deploying LiquidityManager...");
    const LiquidityManager = await ethers.getContractFactory("LiquidityManager");
    const liquidityManager = await upgrades.deployProxy(LiquidityManager, [
        teachTokenAddress,
        stableCoinAddress,
        initialTargetPrice
    ], { initializer: 'initialize' });

    await liquidityManager.waitForDeployment();
    const deploymentTx = await ethers.provider.getTransactionReceipt(liquidityManager.deploymentTransaction().hash);
    totalGas += deploymentTx.gasUsed;
    const liquidityManagerAddress = await liquidityManager.getAddress();
    console.log("LiquidityManager deployed to:", liquidityManagerAddress);

    // Configure component references if available
    if (dexRegistryAddress) {
        console.log("Setting DexRegistry for LiquidityManager...");
        const setDexRegistryTx = await liquidityManager.setDexRegistry(dexRegistryAddress);
        const setDexRegistryReceipt = await setDexRegistryTx.wait();
        totalGas += setDexRegistryReceipt.gasUsed;
        console.log("DexRegistry set for LiquidityManager");

        // Update DexRegistry to point to LiquidityManager
        const DexRegistry = await ethers.getContractFactory("DexRegistry");
        const dexRegistry = DexRegistry.attach(dexRegistryAddress);
        await dexRegistry.setLiquidityManager(liquidityManagerAddress);
        console.log("LiquidityManager set in DexRegistry");
    }

    if (tokenPriceFeedAddress) {
        console.log("Setting TokenPriceFeed for LiquidityManager...");
        const setPriceFeedTx = await liquidityManager.setTokenPriceFeed(tokenPriceFeedAddress);
        const setPriceFeedReceipt = await setPriceFeedTx.wait();
        totalGas += setPriceFeedReceipt.gasUsed;
        console.log("TokenPriceFeed set for LiquidityManager");
    }

    if (liquidityProvisionerAddress) {
        console.log("Setting LiquidityProvisioner for LiquidityManager...");
        const setProvisionerTx = await liquidityManager.setLiquidityProvisioner(liquidityProvisionerAddress);
        const setProvisionerReceipt = await setProvisionerTx.wait();
        totalGas += setProvisionerReceipt.gasUsed;
        console.log("LiquidityProvisioner set for LiquidityManager");
    }

    if (liquidityRebalancerAddress) {
        console.log("Setting LiquidityRebalancer for LiquidityManager...");
        const setRebalancerTx = await liquidityManager.setLiquidityRebalancer(liquidityRebalancerAddress);
        const setRebalancerReceipt = await setRebalancerTx.wait();
        totalGas += setRebalancerReceipt.gasUsed;
        console.log("LiquidityRebalancer set for LiquidityManager");
    }

    // Set main registry if available
    if (registryAddress) {
        console.log("Setting Registry for LiquidityManager...");
        const setRegistryTx = await liquidityManager.setRegistry(registryAddress);
        const setRegistryReceipt = await setRegistryTx.wait();
        totalGas += setRegistryReceipt.gasUsed;
        console.log("Registry set for LiquidityManager");

        // Register in registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const LIQUIDITY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_MANAGER"));

        console.log("Registering LiquidityManager in Registry...");
        const registerTx = await registry.registerContract(LIQUIDITY_MANAGER_NAME, liquidityManagerAddress, "0x00000000");
        const registerReceipt = await registerTx.wait();
        totalGas += registerReceipt.gasUsed;
        console.log("LiquidityManager registered in Registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`LIQUIDITY_MANAGER_ADDRESS=${liquidityManagerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });