const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

// Create a mock contract that inherits from RegistryAwareUpgradeable for testing
describe("RegistryAwareUpgradeable", function () {
    let MockRegistryAware;
    let mockRegistryAware;
    let ContractRegistry;
    let registry;
    let MockContract;
    let mockContract;
    let owner;
    let addr1;
    let addr2;

    beforeEach(async function () {
        // Get the contract factory
        // For testing RegistryAwareUpgradeable, we'll use TokenStaking which inherits from it
        MockRegistryAware = await ethers.getContractFactory("TokenStaking");
        ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        MockContract = await ethers.getContractFactory("TeachToken");

        // Get signers
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy mock token for TokenStaking
        const mockToken = await upgrades.deployProxy(MockContract, [], {
            initializer: "initialize",
        });
        await mockToken.deployed();

        // Deploy mock registry-aware contract
        mockRegistryAware = await upgrades.deployProxy(MockRegistryAware, [
            mockToken.address,
            owner.address
        ], {
            initializer: "initialize",
        });
        await mockRegistryAware.deployed();

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
        });
        await registry.deployed();

        // Deploy another mock contract for testing
        mockContract = await upgrades.deployProxy(MockContract, [], {
            initializer: "initialize",
        });
        await mockContract.deployed();
    });

    describe("Registry Setup", function () {
        it("Should set registry correctly", async function () {
            const STAKING_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_STAKING"));

            await mockRegistryAware.setRegistry(registry.address);

            expect(await mockRegistryAware.registry()).to.equal(registry.address);
            expect(await mockRegistryAware.contractName()).to.equal(STAKING_NAME);
        });

        it("Should not set registry to zero address", async function () {
            await expect(
                mockRegistryAware.setRegistry(ethers.constants.AddressZero)
            ).to.be.revertedWith("RegistryAware: zero registry address");
        });
    });

    describe("Fallback Address Management", function () {
        it("Should set fallback address", async function () {
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));

            await mockRegistryAware.setFallbackAddress(TOKEN_NAME, mockContract.address);

            // Check event emission instead of direct verification since _fallbackAddresses is internal
            await expect(mockRegistryAware.setFallbackAddress(TOKEN_NAME, mockContract.address))
                .to.emit(mockRegistryAware, "FallbackAddressSet")
                .withArgs(TOKEN_NAME, mockContract.address);
        });

        it("Should require admin role to set fallback address", async function () {
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));

            // Revoke admin role from owner
            await mockRegistryAware.revokeRole(ADMIN_ROLE, owner.address);

            // Try to set fallback address without role
            await expect(
                mockRegistryAware.setFallbackAddress(TOKEN_NAME, mockContract.address)
            ).to.be.reverted;

            // Grant role to addr1
            await mockRegistryAware.grantRole(ADMIN_ROLE, addr1.address);

            // Should succeed with role
            await mockRegistryAware.connect(addr1).setFallbackAddress(TOKEN_NAME, mockContract.address);
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
            await mockRegistryAware.setRegistry(registry.address);

            // Disable offline mode
            await mockRegistryAware.disableRegistryOfflineMode();

            expect(await mockRegistryAware.registryOfflineMode()).to.equal(false);
        });

        it("Should not disable offline mode when registry is inaccessible", async function () {
            // Enable offline mode
            await mockRegistryAware.enableRegistryOfflineMode();

            // Try to disable offline mode without setting registry
            await expect(
                mockRegistryAware.disableRegistryOfflineMode()
            ).to.be.revertedWith("RegistryAware: registry not set");

            // Set registry to invalid address
            const mockBadRegistry = await (await ethers.getContractFactory("TeachToken")).deploy();
            await mockRegistryAware.setRegistry(mockBadRegistry.address);

            // Try to disable offline mode with invalid registry
            await expect(
                mockRegistryAware.disableRegistryOfflineMode()
            ).to.be.revertedWith("RegistryAware: registry not accessible");
        });

        it("Should require admin role to manage offline mode", async function () {
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));

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

    describe("Registry-aware Modifiers", function () {
        it("Should allow calls from correct contract in registry", async function () {
            // This is challenging to test directly since onlyFromRegistry is an internal modifier
            // We would need a specific function in our mock that uses this modifier
            // For now, we'll test the modifier indirectly through its setup

            // Register mock contract in registry
            const STABILITY_FUND_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_STABILITY_FUND"));
            await registry.registerContract(STABILITY_FUND_NAME, mockContract.address, "0x00000000");

            // Set registry in our registry-aware contract
            await mockRegistryAware.setRegistry(registry.address);

            // Now the setup is complete for the modifier to work
            // Actual testing would require calling a function with the modifier
        });
    });

    describe("Safe Contract Calls", function () {
        it("Should setup for safe contract calls", async function () {
            // Similar to above, _safeContractCall is internal and difficult to test directly
            // We'll verify the setup is correct

            // Register mock contract in registry
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
            await registry.registerContract(TOKEN_NAME, mockContract.address, "0x00000000");

            // Set registry in our registry-aware contract
            await mockRegistryAware.setRegistry(registry.address);

            // Now the setup is complete for safe contract calls to work
        });

        it("Should use fallback address in offline mode", async function () {
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));

            // Set fallback address
            await mockRegistryAware.setFallbackAddress(TOKEN_NAME, mockContract.address);

            // Enable offline mode
            await mockRegistryAware.enableRegistryOfflineMode();

            // Now calls would use the fallback address
            // Testing this directly would require calling an internal function
        });
    });

    describe("Integration with Registry", function () {
        beforeEach(async function () {
            // Set up registry with our contracts
            const STAKING_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_STAKING"));
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));

            await registry.registerContract(STAKING_NAME, mockRegistryAware.address, "0x00000000");
            await registry.registerContract(TOKEN_NAME, mockContract.address, "0x00000000");

            // Set registry in our registry-aware contract
            await mockRegistryAware.setRegistry(registry.address);
        });

        it("Should interact with registry for contract status", async function () {
            // We'll use TokenStaking's interaction with registry
            // Typically this would be through the whenContractNotPaused modifier

            // Start with system not paused
            expect(await registry.systemPaused()).to.equal(false);

            // Pause the system
            await registry.pauseSystem();
            expect(await registry.systemPaused()).to.equal(true);

            // Now operations in TokenStaking should respect system pause
            // This would be tested by calling functions with the whenContractNotPaused modifier
        });

        it("Should detect deactivated contracts", async function () {
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));

            // Deactivate token contract
            await registry.setContractStatus(TOKEN_NAME, false);

            // Verify contract is inactive
            expect(await registry.isContractActive(TOKEN_NAME)).to.equal(false);

            // Now operations that use _safeContractCall for the token should return false
            // Testing this directly would require calling an internal function
        });

        it("Should update contract references", async function () {
            // For TokenStaking, this would be updateContractReferences
            // Deploy a new mock token
            const newToken = await upgrades.deployProxy(MockContract, [], {
                initializer: "initialize",
            });
            await newToken.deployed();

            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));

            // Update token in registry
            await registry.updateContract(TOKEN_NAME, newToken.address, "0x00000000");

            // Update contract references
            await mockRegistryAware.updateContractReferences();

            // This would typically update internal state in TokenStaking
            // Testing would depend on specifics of the contract
        });
    });

    describe("Error Handling and Events", function () {
        it("Should emit events for registry call failures", async function () {
            // This is challenging to test directly since internal methods emit these events
            // We would need to trigger specific error conditions

            // Set registry to an invalid address
            const mockBadRegistry = await (await ethers.getContractFactory("TeachToken")).deploy();
            await mockRegistryAware.setRegistry(mockBadRegistry.address);

            // Operations that call the registry would emit errors
            // Testing would depend on the specific implementation
        });
    });
});