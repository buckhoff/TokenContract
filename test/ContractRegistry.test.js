const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ContractRegistry Contract", function () {
    let ContractRegistry;
    let registry;
    let MockContract;
    let mockContract1;
    let mockContract2;
    let owner;
    let addr1;
    let addr2;

    beforeEach(async function () {
        // Get contract factory
        ContractRegistry = await ethers.getContractFactory("ContractRegistry");

        // Deploy a mock contract for testing
        MockContract = await ethers.getContractFactory("TeachToken");

        // Get signers
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy registry using upgrades plugin
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
        });
        await registry.deployed();

        // Deploy mock contracts
        mockContract1 = await upgrades.deployProxy(MockContract, [], {
            initializer: "initialize",
        });
        await mockContract1.deployed();

        mockContract2 = await upgrades.deployProxy(MockContract, [], {
            initializer: "initialize",
        });
        await mockContract2.deployed();
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            // Owner should have admin role
            const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero;
            expect(await registry.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true);
        });

        it("Should set system paused to false", async function () {
            expect(await registry.systemPaused()).to.equal(false);
        });

        it("Should have admin, upgrader, and emergency roles set", async function () {
            // Get role hashes
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
            const UPGRADER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UPGRADER_ROLE"));
            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));

            expect(await registry.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await registry.hasRole(UPGRADER_ROLE, owner.address)).to.equal(true);
            expect(await registry.hasRole(EMERGENCY_ROLE, owner.address)).to.equal(true);
        });
    });

    describe("Contract Registration", function () {
        it("Should register a new contract", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));
            const INTERFACE_ID = "0x12345678";

            await registry.registerContract(CONTRACT_NAME, mockContract1.address, INTERFACE_ID);

            // Check contract is registered
            expect(await registry.getContractAddress(CONTRACT_NAME)).to.equal(mockContract1.address);
            expect(await registry.getContractVersion(CONTRACT_NAME)).to.equal(1);
            expect(await registry.isContractActive(CONTRACT_NAME)).to.equal(true);
            expect(await registry.getContractInterface(CONTRACT_NAME)).to.equal(INTERFACE_ID);
        });

        it("Should not register a zero address", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            await expect(
                registry.registerContract(CONTRACT_NAME, ethers.constants.AddressZero, "0x00000000")
            ).to.be.revertedWith("ContractRegistry: zero address");
        });

        it("Should not register the same contract twice", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            await registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");

            await expect(
                registry.registerContract(CONTRACT_NAME, mockContract2.address, "0x00000000")
            ).to.be.revertedWith("ContractRegistry: already registered");
        });

        it("Should update a registered contract", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));
            const INTERFACE_ID = "0x12345678";
            const NEW_INTERFACE_ID = "0x87654321";

            // Register initial contract
            await registry.registerContract(CONTRACT_NAME, mockContract1.address, INTERFACE_ID);

            // Update contract
            await registry.updateContract(CONTRACT_NAME, mockContract2.address, NEW_INTERFACE_ID);

            // Check contract is updated
            expect(await registry.getContractAddress(CONTRACT_NAME)).to.equal(mockContract2.address);
            expect(await registry.getContractVersion(CONTRACT_NAME)).to.equal(2);
            expect(await registry.getContractInterface(CONTRACT_NAME)).to.equal(NEW_INTERFACE_ID);
        });

        it("Should not update to the same address", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Register initial contract
            await registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");

            // Try to update to same address
            await expect(
                registry.updateContract(CONTRACT_NAME, mockContract1.address, "0x00000000")
            ).to.be.revertedWith("ContractRegistry: same address");
        });

        it("Should not update a non-existent contract", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Try to update non-existent contract
            await expect(
                registry.updateContract(CONTRACT_NAME, mockContract1.address, "0x00000000")
            ).to.be.revertedWith("ContractRegistry: not registered");
        });

        it("Should keep implementation history", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Register initial contract
            await registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");

            // Update contract
            await registry.updateContract(CONTRACT_NAME, mockContract2.address, "0x00000000");

            // Get implementation history
            const history = await registry.getImplementationHistory(CONTRACT_NAME);

            expect(history.length).to.equal(2);
            expect(history[0]).to.equal(mockContract1.address);
            expect(history[1]).to.equal(mockContract2.address);
        });
    });

    describe("Contract Status", function () {
        it("Should set contract status", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Register contract
            await registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");

            // Initially active
            expect(await registry.isContractActive(CONTRACT_NAME)).to.equal(true);

            // Deactivate
            await registry.setContractStatus(CONTRACT_NAME, false);
            expect(await registry.isContractActive(CONTRACT_NAME)).to.equal(false);

            // Reactivate
            await registry.setContractStatus(CONTRACT_NAME, true);
            expect(await registry.isContractActive(CONTRACT_NAME)).to.equal(true);
        });

        it("Should not set status for non-existent contract", async function () {
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Try to set status for non-existent contract
            await expect(
                registry.setContractStatus(CONTRACT_NAME, false)
            ).to.be.revertedWith("ContractRegistry: not registered");
        });
    });

    describe("System Pause", function () {
        it("Should pause the system", async function () {
            expect(await registry.systemPaused()).to.equal(false);

            await registry.pauseSystem();

            expect(await registry.systemPaused()).to.equal(true);
        });

        it("Should resume the system", async function () {
            // First pause
            await registry.pauseSystem();
            expect(await registry.systemPaused()).to.equal(true);

            // Then resume
            await registry.resumeSystem();
            expect(await registry.systemPaused()).to.equal(false);
        });

        it("Should require admin role to pause", async function () {
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));

            // Remove roles from owner for this test
            await registry.revokeRole(ADMIN_ROLE, owner.address);
            await registry.revokeRole(EMERGENCY_ROLE, owner.address);

            // Grant only ADMIN_ROLE to addr1
            await registry.grantRole(ADMIN_ROLE, addr1.address);

            // Only addr1 should be able to pause system
            await expect(registry.pauseSystem()).to.be.reverted;
            await registry.connect(addr1).pauseSystem();
            expect(await registry.systemPaused()).to.equal(true);
        });
    });

    describe("Emergency Recovery", function () {
        it("Should initiate emergency recovery", async function () {
            // Pause system first
            await registry.pauseSystem();

            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));

            // Initiate emergency recovery
            await registry.initiateEmergencyRecovery();

            expect(await registry.inEmergencyRecovery()).to.equal(true);
            expect(await registry.recoveryInitiatedTimestamp()).to.not.equal(0);
        });

        it("Should approve recovery", async function () {
            // Setup recovery mode
            await registry.pauseSystem();
            await registry.initiateEmergencyRecovery();

            // Approve recovery
            await registry.approveRecovery();

            // Check if admin has approved
            const approved = await registry.emergencyRecoveryApprovals(owner.address);
            expect(approved).to.equal(true);

            // With default config, a single admin approval should complete recovery
            // System should be unpaused
            expect(await registry.systemPaused()).to.equal(false);
        });

        it("Should set required recovery approvals", async function () {
            // Change required approvals
            await registry.setRequiredRecoveryApprovals(3);

            expect(await registry.requiredRecoveryApprovals()).to.equal(3);
        });

        it("Should set recovery timeout", async function () {
            // Set recovery timeout to 2 hours
            const twoHours = 2 * 60 * 60;
            await registry.setRecoveryTimeout(twoHours);

            expect(await registry.recoveryTimeout()).to.equal(twoHours);
        });
    });

    describe("Utility Functions", function () {
        it("Should convert string to bytes32", async function () {
            const testString = "TEST_CONTRACT";
            const expectedBytes32 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(testString));

            const result = await registry.stringToBytes32(testString);

            expect(result).to.equal(expectedBytes32);
        });

        it("Should get all contract names", async function () {
            // Register contracts
            const CONTRACT_NAME_1 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT_1"));
            const CONTRACT_NAME_2 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT_2"));

            await registry.registerContract(CONTRACT_NAME_1, mockContract1.address, "0x00000000");
            await registry.registerContract(CONTRACT_NAME_2, mockContract2.address, "0x00000000");

            // Get all contract names
            const names = await registry.getAllContractNames();

            expect(names.length).to.equal(2);
            expect(names[0]).to.equal(CONTRACT_NAME_1);
            expect(names[1]).to.equal(CONTRACT_NAME_2);
        });
    });

    describe("Role-Based Access Control", function () {
        it("Should restrict registerContract to admin role", async function () {
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Remove role from owner for this test
            await registry.revokeRole(ADMIN_ROLE, owner.address);

            // Try to register without role
            await expect(
                registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000")
            ).to.be.reverted;

            // Grant role to addr1
            await registry.grantRole(ADMIN_ROLE, addr1.address);

            // Should succeed with role
            await registry.connect(addr1).registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");
        });

        it("Should restrict updateContract to upgrader role", async function () {
            const UPGRADER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UPGRADER_ROLE"));
            const CONTRACT_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_CONTRACT"));

            // Register contract first
            await registry.registerContract(CONTRACT_NAME, mockContract1.address, "0x00000000");

            // Remove role from owner for this test
            await registry.revokeRole(UPGRADER_ROLE, owner.address);

            // Try to update without role
            await expect(
                registry.updateContract(CONTRACT_NAME, mockContract2.address, "0x00000000")
            ).to.be.reverted;

            // Grant role to addr1
            await registry.grantRole(UPGRADER_ROLE, addr1.address);

            // Should succeed with role
            await registry.connect(addr1).updateContract(CONTRACT_NAME, mockContract2.address, "0x00000000");
        });
    });

    describe("System Emergency", function () {
        it("Should trigger system-wide emergency", async function () {
            // This test is more complex as it requires mocking multiple contracts
            // We'll focus on basic functionality

            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));

            // Trigger emergency
            await registry.triggerSystemEmergency("Test emergency");

            // System should be paused
            expect(await registry.systemPaused()).to.equal(true);
        });
    });
});