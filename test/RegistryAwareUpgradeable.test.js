const { expect } = require("chai");
const { ethers } = require("hardhat");

// Create a mock contract that inherits from RegistryAwareUpgradeable for testing
describe("RegistryAwareUpgradeable", function () {
    let mockRegistryAware;
    let registry;
    let mockToken;
    let owner;
    let addr1;
    let addr2;

    beforeEach(async function () {
        // Get the contract factories
        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const TeachToken = await ethers.getContractFactory("TeachToken");

        // Get signers
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy mock token for TokenStaking
        mockToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
            kind: "uups"
        });

        // Deploy mock registry-aware contract (TokenStaking as it inherits from RegistryAwareUpgradeable)
        mockRegistryAware = await upgrades.deployProxy(TokenStaking, [
            await mockToken.getAddress(),
            owner.address // platformRewardsManager
        ], {
            initializer: "initialize",
            kind: "uups"
        });

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
            kind: "uups"
        });
    });

    describe("Registry Setup", function () {
        it("Should set registry correctly", async function () {
            const STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));

            await mockRegistryAware.setRegistry(await registry.getAddress());

            expect(await mockRegistryAware.registry()).to.equal(await registry.getAddress());
            expect(await mockRegistryAware.contractName()).to.equal(STAKING_NAME);
        });

        it("Should not set registry to zero address", async function () {
            await expect(
                mockRegistryAware.setRegistry(ethers.ZeroAddress)
            ).to.be.revertedWith("RegistryAware: zero registry address");
        });
    });

    describe("Fallback Address Management", function () {
        it("Should set fallback address", async function () {
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

            // Set fallback address
            await mockRegistryAware.setFallbackAddress(TOKEN_NAME, await mockToken.getAddress());

            // Check event emission
            await expect(mockRegistryAware.setFallbackAddress(TOKEN_NAME, await mockToken.getAddress()))
                .to.emit(mockRegistryAware, "FallbackAddressSet")
                .withArgs(TOKEN_NAME, await mockToken.getAddress());
        });

        it("Should require admin role to set fallback address", async function () {
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

            // Revoke admin role from owner
            await mockRegistryAware.revokeRole(ADMIN_ROLE, owner.address);

            // Try to set fallback address without role
            await expect(
                mockRegistryAware.setFallbackAddress(TOKEN_NAME, await mockToken.getAddress())
            ).to.be.reverted;

            // Grant role to addr1
            await mockRegistryAware.grantRole(ADMIN_ROLE, addr1.address);

            // Should succeed with role
            await mockRegistryAware.connect(addr1).setFallbackAddress(TOKEN_NAME, await mockToken.getAddress());
        });
    });

    describe("Registry Offline Mode", function () {
        it("Should enable offline mode", async function () {
            expect(await mockRegistryAware.registryOfflineMode()).to.equal(false);

            await mockRegistryAware.enableRegistryOfflineMode();

            expect(await mockRegistryAware.registryOfflineMode()).to.equal(true);
        });

        it("Should disable offline mode when registry is accessible", async function () {
            // Enable offline mode
            await mockRegistryAware.enableRegistryOfflineMode();
            expect(await mockRegistryAware.registryOfflineMode()).to.equal(true);

            // Set registry
            await mockRegistryAware.setRegistry(await registry.getAddress());

            // Disable offline mode
            await mockRegistryAware.disableRegistryOfflineMode();

            expect(await mockRegistryAware.registryOfflineMode()).to.equal(false);
        });

        it("Should not disable offline mode when registry is not set", async function () {
            // Enable offline mode
            await mockRegistryAware.enableRegistryOfflineMode();

            // Try to disable offline mode without setting registry
            await expect(
                mockRegistryAware.disableRegistryOfflineMode()
            ).to.be.revertedWith("RegistryAware: registry not set");
        });

        it("Should require admin role to manage offline mode", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

            // Revoke admin role from owner
            await mockRegistryAware.revokeRole(ADMIN_ROLE, owner.address);

            // Try to enable offline mode without role
            await expect(
                mockRegistryAware.enableRegistryOfflineMode()
            ).to.be.reverted;

            // Grant role to addr1
            await mockRegistryAware.grantRole(ADMIN_ROLE, addr1.address);

            // Should succeed with role
            await mockRegistryAware.connect(addr1).enableRegistryOfflineMode();
        });
    });

    describe("Integration with Registry", function () {
        beforeEach(async function () {
            // Set up registry with our contracts
            const STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

            await registry.registerContract(STAKING_NAME, await mockRegistryAware.getAddress(), "0x00000000");
            await registry.registerContract(TOKEN_NAME, await mockToken.getAddress(), "0x00000000");

            // Set registry in our registry-aware contract
            await mockRegistryAware.setRegistry(await registry.getAddress());
        });

        it("Should interact with registry for contract status", async function () {
            // Start with system not paused
            expect(await registry.isSystemPaused()).to.equal(false);

            // Pause the system
            await registry.pauseSystem();
            expect(await registry.isSystemPaused()).to.equal(true);

            // Now operations in TokenStaking should respect system pause
            // This would typically be tested through functions with the whenContractNotPaused modifier
        });

        it("Should detect deactivated contracts", async function () {
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

            // Deactivate token contract
            await registry.setContractStatus(TOKEN_NAME, false);

            // Verify contract is inactive
            expect(await registry.isContractActive(TOKEN_NAME)).to.equal(false);
        });

        it("Should update contract references", async function () {
            // Deploy a new mock token
            const newToken = await upgrades.deployProxy(
                await ethers.getContractFactory("TeachToken"),
                [],
                { initializer: "initialize", kind: "uups" }
            );

            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));

            // Update token in registry
            await registry.updateContract(TOKEN_NAME, await newToken.getAddress(), "0x00000000");

            // This would typically update internal state in TokenStaking
            // We can verify the emitted event
            await expect(mockRegistryAware.updateContractReferences())
                .to.emit(mockRegistryAware, "ContractReferenceUpdated");
        });
    });
});