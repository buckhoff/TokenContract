// test/TeachTokenEcosystem.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TeachToken Ecosystem", function () {
    let registry;
    let teachToken;
    let stabilityFund;
    let owner;
    let user1;

    beforeEach(async function () {
        [owner, user1] = await ethers.getSigners();

        // Deploy the registry
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        registry = await ContractRegistry.deploy();
        await registry.waitForDeployment();
        await registry.initialize();

        // Deploy the token
        const TeachToken = await ethers.getContractFactory("TeachToken");
        teachToken = await TeachToken.deploy();
        await teachToken.waitForDeployment();
        await teachToken.initialize();

        // Deploy stability fund
        const StabilityFund = await ethers.getContractFactory("PlatformStabilityFund");
        stabilityFund = await StabilityFund.deploy();
        await stabilityFund.waitForDeployment();

        // Deploy a test stablecoin
        const TestStableCoin = await ethers.getContractFactory("ERC20Upgradeable");
        const stableCoin = await TestStableCoin.deploy();
        await stableCoin.waitForDeployment();
        await stableCoin.initialize("Test USDC", "tUSDC");

        // Set up stability fund
        await stabilityFund.initialize(
            await teachToken.getAddress(),
            await stableCoin.getAddress(),
            owner.address, // oracle
            ethers.parseEther("0.10"), // initial price
            5000, // 50% reserve ratio
            2000, // 20% min reserve ratio
            300, // 3% platform fee
            150, // 1.5% low value fee
            1000 // 10% threshold
        );

        // Register contracts
        const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));
        const STABILITY_FUND_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_STABILITY_FUND"));

        await registry.registerContract(TOKEN_NAME, await teachToken.getAddress(), "0x00000000");
        await registry.registerContract(STABILITY_FUND_NAME, await stabilityFund.getAddress(), "0x00000000");

        // Set registry in contracts
        await teachToken.setRegistry(await registry.getAddress());
        await stabilityFund.setRegistry(await registry.getAddress());
    });

    describe("Cross-Contract Functionality", function () {
        it("Should allow registry lookups from contracts", async function () {
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

            // Check if stability fund can find token through registry
            await stabilityFund.updateContractReferences();

            // This test would need specific function calls based on your implementation
        });
    });

    // Additional integration tests...
});