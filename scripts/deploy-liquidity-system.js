// scripts/deploy-liquidity-system.js
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying Liquidity System with the account:", deployer.address);

    let totalGas = 0n;
    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const stableCoinAddress = process.env.STABLE_COIN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress || !stableCoinAddress) {
        console.error("Please set TOKEN_ADDRESS and STABLE_COIN_ADDRESS in your .env file");
        return;
    }

    // Step 1: Deploy DexRegistry
    console.log("Deploying DexRegistry...");
    const DexRegistry = await ethers.getContractFactory("DexRegistry");
    const dexRegistry = await upgrades.deployProxy(DexRegistry, [], { initializer: 'initialize' });

    await dexRegistry.waitForDeployment();
    const dexRegDeploymentTx = await ethers.provider.getTransactionReceipt(dexRegistry.deploymentTransaction().hash);
    totalGas += dexRegDeploymentTx.gasUsed;
    const dexRegistryAddress = await dexRegistry.getAddress();
    console.log("DexRegistry deployed to:", dexRegistryAddress);

    // Step 2: Deploy TokenPriceFeed
    console.log("Deploying TokenPriceFeed...");
    const TokenPriceFeed = await ethers.getContractFactory("TokenPriceFeed");
    const tokenPriceFeed = await upgrades.deployProxy(TokenPriceFeed, [
        dexRegistryAddress, // dexRegistry
        deployer.address    // externalPriceOracle - set to deployer for now
    ], { initializer: 'initialize' });

    await tokenPriceFeed.waitForDeployment();
    const priceFeedDeploymentTx = await ethers.provider.getTransactionReceipt(tokenPriceFeed.deploymentTransaction().hash);
    totalGas += priceFeedDeploymentTx.gasUsed;
    const tokenPriceFeedAddress = await tokenPriceFeed.getAddress();
    console.log("TokenPriceFeed deployed to:", tokenPriceFeedAddress);

    // Step 3: Deploy LiquidityProvisioner
    console.log("Deploying LiquidityProvisioner...");
    const LiquidityProvisioner = await ethers.getContractFactory("LiquidityProvisioner");
    const liquidityProvisioner = await upgrades.deployProxy(LiquidityProvisioner, [
        teachTokenAddress,
        stableCoinAddress,
        dexRegistryAddress,
        ethers.parseUnits("0.12", 6) // Initial target price $0.12
    ], { initializer: 'initialize' });

    await liquidityProvisioner.waitForDeployment();
    const provisionerDeploymentTx = await ethers.provider.getTransactionReceipt(liquidityProvisioner.deploymentTransaction().hash);
    totalGas += provisionerDeploymentTx.gasUsed;
    const liquidityProvisionerAddress = await liquidityProvisioner.getAddress();
    console.log("LiquidityProvisioner deployed to:", liquidityProvisionerAddress);

    // Step 4: Deploy LiquidityRebalancer
    console.log("Deploying LiquidityRebalancer...");
    const LiquidityRebalancer = await ethers.getContractFactory("LiquidityRebalancer");
    const liquidityRebalancer = await upgrades.deployProxy(LiquidityRebalancer, [
        dexRegistryAddress,
        liquidityProvisionerAddress
    ], { initializer: 'initialize' });

    await liquidityRebalancer.waitForDeployment();
    const rebalancerDeploymentTx = await ethers.provider.getTransactionReceipt(liquidityRebalancer.deploymentTransaction().hash);
    totalGas += rebalancerDeploymentTx.gasUsed;
    const liquidityRebalancerAddress = await liquidityRebalancer.getAddress();
    console.log("LiquidityRebalancer deployed to:", liquidityRebalancerAddress);

    // Step 5: Deploy LiquidityManager as the main coordinator
    console.log("Deploying LiquidityManager...");
    const LiquidityManager = await ethers.getContractFactory("LiquidityManager");
    const liquidityManager = await upgrades.deployProxy(LiquidityManager, [
        teachTokenAddress,
        stableCoinAddress,
        ethers.parseUnits("0.12", 6) // Initial target price $0.12
    ], { initializer: 'initialize' });

    await liquidityManager.waitForDeployment();
    const managerDeploymentTx = await ethers.provider.getTransactionReceipt(liquidityManager.deploymentTransaction().hash);
    totalGas += managerDeploymentTx.gasUsed;
    const liquidityManagerAddress = await liquidityManager.getAddress();
    console.log("LiquidityManager deployed to:", liquidityManagerAddress);

    // Step 6: Configure cross-component references
    console.log("Setting component references...");

    // Set DexRegistry in LiquidityManager
    const setDexRegistryTx = await liquidityManager.setDexRegistry(dexRegistryAddress);
    const setDexRegistryReceipt = await setDexRegistryTx.wait();
    totalGas += setDexRegistryReceipt.gasUsed;

    // Set LiquidityProvisioner in LiquidityManager
    const setProvisionerTx = await liquidityManager.setLiquidityProvisioner(liquidityProvisionerAddress);
    const setProvisionerReceipt = await setProvisionerTx.wait();
    totalGas += setProvisionerReceipt.gasUsed;

    // Set LiquidityRebalancer in LiquidityManager
    const setRebalancerTx = await liquidityManager.setLiquidityRebalancer(liquidityRebalancerAddress);
    const setRebalancerReceipt = await setRebalancerTx.wait();
    totalGas += setRebalancerReceipt.gasUsed;

    // Set TokenPriceFeed in LiquidityManager
    const setPriceFeedTx = await liquidityManager.setTokenPriceFeed(tokenPriceFeedAddress);
    const setPriceFeedReceipt = await setPriceFeedTx.wait();
    totalGas += setPriceFeedReceipt.gasUsed;

    // Set LiquidityManager as the manager in DexRegistry
    const setManagerTx = await dexRegistry.setLiquidityManager(liquidityManagerAddress);
    const setManagerReceipt = await setManagerTx.wait();
    totalGas += setManagerReceipt.gasUsed;

    // Step 7: Register all components in the main registry if available
    if (registryAddress) {
        console.log("Registering components in main platform registry...");
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        // Register DexRegistry
        const DEX_REGISTRY_NAME = ethers.keccak256(ethers.toUtf8Bytes("DEX_REGISTRY"));
        await (await registry.registerContract(DEX_REGISTRY_NAME, dexRegistryAddress, "0x00000000")).wait();

        // Register TokenPriceFeed
        const TOKEN_PRICE_FEED_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_PRICE_FEED"));
        await (await registry.registerContract(TOKEN_PRICE_FEED_NAME, tokenPriceFeedAddress, "0x00000000")).wait();

        // Register LiquidityProvisioner
        const LIQUIDITY_PROVISIONER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_PROVISIONER"));
        await (await registry.registerContract(LIQUIDITY_PROVISIONER_NAME, liquidityProvisionerAddress, "0x00000000")).wait();

        // Register LiquidityRebalancer
        const LIQUIDITY_REBALANCER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_REBALANCER"));
        await (await registry.registerContract(LIQUIDITY_REBALANCER_NAME, liquidityRebalancerAddress, "0x00000000")).wait();

        // Register LiquidityManager
        const LIQUIDITY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("LIQUIDITY_MANAGER"));
        await (await registry.registerContract(LIQUIDITY_MANAGER_NAME, liquidityManagerAddress, "0x00000000")).wait();

        // Connect components to main registry
        await (await dexRegistry.setRegistry(registryAddress)).wait();
        await (await tokenPriceFeed.setRegistry(registryAddress)).wait();
        await (await liquidityProvisioner.setRegistry(registryAddress)).wait();
        await (await liquidityRebalancer.setRegistry(registryAddress)).wait();
        await (await liquidityManager.setRegistry(registryAddress)).wait();

        console.log("All liquidity components registered in main registry");
    }

    console.log("Gas used:", totalGas.toString());
    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`DEX_REGISTRY_ADDRESS=${dexRegistryAddress}`);
    console.log(`TOKEN_PRICE_FEED_ADDRESS=${tokenPriceFeedAddress}`);
    console.log(`LIQUIDITY_PROVISIONER_ADDRESS=${liquidityProvisionerAddress}`);
    console.log(`LIQUIDITY_REBALANCER_ADDRESS=${liquidityRebalancerAddress}`);
    console.log(`LIQUIDITY_MANAGER_ADDRESS=${liquidityManagerAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });