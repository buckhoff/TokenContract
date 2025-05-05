// scripts/deploy-stability-fund.js
const { ethers,upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying PlatformStabilityFund with the account:", deployer.address);

    const teachTokenAddress = process.env.TOKEN_ADDRESS;
    const stableCoinAddress = process.env.STABLE_COIN_ADDRESS;
    const registryAddress = process.env.REGISTRY_ADDRESS;

    if (!teachTokenAddress || !stableCoinAddress) {
        console.error("Please set TOKEN_ADDRESS and STABLE_COIN_ADDRESS in your .env file");
        return;
    }

    // Initialize the stability fund with parameters
    const initialPrice = ethers.parseUnits("0.12", 18); // Initial token price ($0.12)
    const reserveRatio = 5000; // 50%
    const minReserveRatio = 2000; // 20%
    const platformFeePercent = 300; // 3%
    const lowValueFeePercent = 150; // 1.5%
    const valueThreshold = 1000; // 10% below baseline
    
    // Deploy the PlatformStabilityFund
    const PlatformStabilityFund = await ethers.getContractFactory("PlatformStabilityFund");
    const stabilityFund = await upgrades.deployProxy(PlatformStabilityFund,[teachTokenAddress,
        stableCoinAddress,
        deployer.address, // Set deployer as initial price oracle
        initialPrice,
        reserveRatio,
        minReserveRatio,
        platformFeePercent,
        lowValueFeePercent,
        valueThreshold], {initializer: 'initialize'});

    await stabilityFund.waitForDeployment();
    const stabilityFundAddress = await stabilityFund.getAddress();
    console.log("PlatformStabilityFund deployed to:", stabilityFundAddress);

    

   // console.log("Initializing PlatformStabilityFund...");
    //const initTx = await stabilityFund.initialize(
   //     teachTokenAddress,
   //     stableCoinAddress,
   //     deployer.address, // Set deployer as initial price oracle
   //     initialPrice,
   //     reserveRatio,
  //      minReserveRatio,
   //     platformFeePercent,
  //      lowValueFeePercent,
  //      valueThreshold
   // );
 //   await initTx.wait();
    console.log("PlatformStabilityFund initialized");

    // Set registry
    if (registryAddress) {
        console.log("Setting Registry for StabilityFund...");
        const setRegistryTx = await stabilityFund.setRegistry(registryAddress);
        await setRegistryTx.wait();
        console.log("Registry set for StabilityFund");
    }

    // Register in the registry
    if (registryAddress) {
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const registry = ContractRegistry.attach(registryAddress);

        const STABILITY_FUND_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_STABILITY_FUND"));
        console.log("Registry:" + registry);
        
        console.log("Registering StabilityFund in Registry...");
        const registerTx = await registry.registerContract(STABILITY_FUND_NAME, stabilityFundAddress, "0x00000000");
        console.log("Await");
        await registerTx.wait();
        console.log("StabilityFund registered in Registry");
    }

    console.log("\n--- IMPORTANT: Update your .env file with these values ---");
    console.log(`STABILITY_FUND_ADDRESS=${stabilityFundAddress}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });