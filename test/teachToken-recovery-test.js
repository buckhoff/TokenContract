const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TeachToken - Part 3: Recovery and Emergency Functions", function () {
  let teachToken;
  let mockImmutableContract;
  let mockToken; // ERC20 token for recovery testing
  let mockRegistry;
  let mockEmergencyManager;
  let owner, admin, minter, burner, treasury, emergency, user3, user2, user1;

  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

  // Registry contract names
  const TEACH_TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
  const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));

  beforeEach(async function () {
    // Get 9 signers as requested
    [owner, admin, minter, burner, treasury, emergency, user3, user2, user1] = await ethers.getSigners();

    // Deploy mock immutable contract
    const MockImmutableTokenContract = await ethers.getContractFactory("MockImmutableTokenContract");
    mockImmutableContract = await MockImmutableTokenContract.deploy();
    await mockImmutableContract.waitForDeployment();

    // Deploy mock token for recovery testing
    const MockToken = await ethers.getContractFactory("MockERC20");
    mockToken = await MockToken.deploy("Mock Token", "MCK", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();

    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    await mockRegistry.waitForDeployment();

    // Deploy mock emergency manager
    const MockEmergencyManager = await ethers.getContractFactory("MockEmergencyManager");
    mockEmergencyManager = await MockEmergencyManager.deploy();
    await mockEmergencyManager.waitForDeployment();

    // Deploy TeachToken
    const TeachToken = await ethers.getContractFactory("TeachToken");
    teachToken = await upgrades.deployProxy(TeachToken, [await mockImmutableContract.getAddress()], {
      initializer: "initialize",
    });
    await teachToken.waitForDeployment();

    // Set up roles
    await teachToken.grantRole(ADMIN_ROLE, await admin.getAddress());
    await teachToken.grantRole(MINTER_ROLE, await minter.getAddress());
    await teachToken.grantRole(BURNER_ROLE, await burner.getAddress());
    await teachToken.grantRole(EMERGENCY_ROLE, await emergency.getAddress());

    // Configure registry with both TeachToken and EmergencyManager
    await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await teachToken.getAddress(), true);
    await mockRegistry.setContractAddress(EMERGENCY_MANAGER_NAME, await mockEmergencyManager.getAddress(), true);

    // Set registry on TeachToken
    await teachToken.setRegistry(await mockRegistry.getAddress());

    // Perform initial distribution
    await teachToken.performInitialDistribution(
        await treasury.getAddress(), // platformEcosystem
        await user1.getAddress(),    // communityIncentives
        await user2.getAddress(),    // initialLiquidity
        await owner.getAddress(),    // publicPresale
        await admin.getAddress(),    // teamAndDev
        await minter.getAddress(),   // educationalPartners
        await burner.getAddress()    // reserve
    );

    // Send some mock tokens to the contract for recovery testing
    await mockToken.transfer(await teachToken.getAddress(), ethers.parseEther("1000"));
  });

  describe("Token Recovery", function () {
    it("should not allow recovery of non-allowed tokens", async function () {
      // Attempt to recover tokens that haven't been allowed
      await expect(
          teachToken.recoverERC20(await mockToken.getAddress(), ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Token recovery not allowed");
    });

    it("should allow recovery after setting recovery allowance", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(await mockToken.getAddress(), true);

      const recoveryAmount = ethers.parseEther("100");
      const initialBalance = await mockToken.balanceOf(await owner.getAddress());

      // Recover tokens
      await teachToken.recoverERC20(await mockToken.getAddress(), recoveryAmount);

      // Check balance after recovery
      expect(await mockToken.balanceOf(await owner.getAddress())).to.equal(initialBalance + recoveryAmount);
      expect(await mockToken.balanceOf(await teachToken.getAddress())).to.equal(ethers.parseEther("900")); // 1000 - 100
    });

    it("should prevent recovery of the TEACH token itself", async function () {
      // Attempt to recover TEACH tokens
      await expect(
          teachToken.recoverERC20(await teachToken.getAddress(), ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Cannot recover TEACH tokens");
    });

    it("should revert when trying to recover more tokens than available", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(await mockToken.getAddress(), true);

      // Attempt to recover more tokens than available
      await expect(
          teachToken.recoverERC20(await mockToken.getAddress(), ethers.parseEther("2000"))
      ).to.be.revertedWith("TeachToken: Insufficient balance");
    });

    it("should not allow non-admins to recover tokens", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(await mockToken.getAddress(), true);

      // Attempt to recover tokens as a non-admin
      await expect(
          teachToken.connect(user1).recoverERC20(await mockToken.getAddress(), ethers.parseEther("100"))
      ).to.be.reverted; // Will revert due to role check
    });

    it("should not allow non-admins to set recovery allowance", async function () {
      // Attempt to set recovery allowance as non-admin
      await expect(
          teachToken.connect(user1).setRecoveryAllowedToken(await mockToken.getAddress(), true)
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Pause and Unpause", function () {
    it("should allow admins to pause the contract", async function () {
      // Pause the contract
      await teachToken.pause();

      // Try to transfer tokens (should fail)
      await expect(
          teachToken.transfer(await user1.getAddress(), ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Paused");
    });

    it("should allow admins to unpause the contract", async function () {
      // Pause the contract
      await teachToken.pause();

      // Unpause the contract
      await teachToken.unpause();

      // Try to transfer tokens (should succeed)
      const transferAmount = ethers.parseEther("100");
      await teachToken.transfer(await user1.getAddress(), transferAmount);

      expect(await teachToken.balanceOf(await user1.getAddress())).to.equal(transferAmount);
    });

    it("should not allow non-admins to pause or unpause", async function () {
      // Attempt to pause as non-admin
      await expect(
          teachToken.connect(user1).pause()
      ).to.be.reverted; // Will revert due to role check

      // Pause the contract as admin
      await teachToken.pause();

      // Attempt to unpause as non-admin
      await expect(
          teachToken.connect(user1).unpause()
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Emergency Recovery via EmergencyManager", function () {
    beforeEach(async function () {
      // Set required approvals to 2 for testing using the emergency manager
      await mockEmergencyManager.setRequiredRecoveryApprovals(2);

      // Pause the contract first (required for emergency recovery)
      await teachToken.pause();
    });

    it("should allow setting required recovery approvals", async function () {
      // Set required approvals
      await mockEmergencyManager.setRequiredRecoveryApprovals(3);

      // Verify the setting
      expect(await mockEmergencyManager.requiredRecoveryApprovals()).to.equal(3);
    });

    it("should not allow setting invalid approval count", async function () {
      // Attempt to set invalid approval count (0)
      await expect(
          mockEmergencyManager.setRequiredRecoveryApprovals(0)
      ).to.be.revertedWith("MockEmergencyManager: invalid approval count");
    });

    it("should allow initiating emergency recovery", async function () {
      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // Verify we're in recovery mode
      expect(await mockEmergencyManager.isInEmergencyRecovery()).to.be.true;
    });

    it("should track recovery initiation timestamp", async function () {
      // Get timestamp before initiation
      const blockBefore = await ethers.provider.getBlock('latest');
      const timestampBefore = blockBefore.timestamp;

      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // Check that timestamp was set
      const recoveryTimestamp = await mockEmergencyManager.recoveryInitiatedTimestamp();
      expect(recoveryTimestamp).to.be.greaterThan(timestampBefore);
    });

    it("should allow approving recovery", async function () {
      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // Check initial approval state
      expect(await mockEmergencyManager.hasApprovedRecovery(await owner.getAddress())).to.be.false;

      // Approve recovery
      await mockEmergencyManager.connect(owner).approveRecovery();

      // Check approval state
      expect(await mockEmergencyManager.hasApprovedRecovery(await owner.getAddress())).to.be.true;
    });

    it("should not allow double approvals from same address", async function () {
      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // First approval succeeds
      await mockEmergencyManager.connect(owner).approveRecovery();

      // Second approval from same address should fail
      await expect(
          mockEmergencyManager.connect(owner).approveRecovery()
      ).to.be.revertedWith("MockEmergencyManager: already approved");
    });

    it("should complete recovery after sufficient approvals", async function () {
      // Set required approvals to 2
      await mockEmergencyManager.setRequiredRecoveryApprovals(2);

      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // First approval
      await mockEmergencyManager.connect(owner).approveRecovery();
      expect(await mockEmergencyManager.isInEmergencyRecovery()).to.be.true;

      // Second approval should complete the recovery
      await mockEmergencyManager.connect(admin).approveRecovery();
      expect(await mockEmergencyManager.isInEmergencyRecovery()).to.be.false;
    });

    it("should not allow approval when not in recovery mode", async function () {
      // Attempt to approve without initiating recovery
      await expect(
          mockEmergencyManager.connect(owner).approveRecovery()
      ).to.be.revertedWith("MockEmergencyManager: not in recovery mode");
    });

    it("should allow multiple users to approve recovery", async function () {
      // Set required approvals to 3
      await mockEmergencyManager.setRequiredRecoveryApprovals(3);

      // Initiate emergency recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();

      // Multiple approvals from different users
      await mockEmergencyManager.connect(owner).approveRecovery();
      expect(await mockEmergencyManager.hasApprovedRecovery(await owner.getAddress())).to.be.true;

      await mockEmergencyManager.connect(admin).approveRecovery();
      expect(await mockEmergencyManager.hasApprovedRecovery(await admin.getAddress())).to.be.true;

      await mockEmergencyManager.connect(minter).approveRecovery();
      expect(await mockEmergencyManager.hasApprovedRecovery(await minter.getAddress())).to.be.true;

      // Recovery should be completed after 3 approvals
      expect(await mockEmergencyManager.isInEmergencyRecovery()).to.be.false;
    });

    it("should allow setting and getting recovery timeout", async function () {
      // Set recovery timeout to 12 hours
      const newTimeout = 12 * 60 * 60; // 12 hours in seconds
      await mockEmergencyManager.setRecoveryTimeout(newTimeout);

      // Verify the setting
      expect(await mockEmergencyManager.recoveryTimeout()).to.equal(newTimeout);
    });

    it("should not allow setting invalid recovery timeout", async function () {
      // Attempt to set timeout too short (less than 1 hour)
      await expect(
          mockEmergencyManager.setRecoveryTimeout(30 * 60) // 30 minutes
      ).to.be.revertedWith("MockEmergencyManager: timeout too short");

      // Attempt to set timeout too long (more than 7 days)
      await expect(
          mockEmergencyManager.setRecoveryTimeout(8 * 24 * 60 * 60) // 8 days
      ).to.be.revertedWith("MockEmergencyManager: timeout too long");
    });

    it("should emit events for recovery operations", async function () {
      // Test EmergencyRecoveryInitiated event
      await expect(
          mockEmergencyManager.connect(emergency).initiateEmergencyRecovery()
      ).to.emit(mockEmergencyManager, "EmergencyRecoveryInitiated")
          .withArgs(await emergency.getAddress(), anyValue);

      // Test RecoveryApprovalsUpdated event
      await expect(
          mockEmergencyManager.setRequiredRecoveryApprovals(5)
      ).to.emit(mockEmergencyManager, "RecoveryApprovalsUpdated")
          .withArgs(5);
    });

    it("should reset recovery state correctly", async function () {
      // Initiate recovery
      await mockEmergencyManager.connect(emergency).initiateEmergencyRecovery();
      await mockEmergencyManager.connect(owner).approveRecovery();

      // Reset recovery state
      await mockEmergencyManager.resetRecoveryState();

      // Verify state is reset
      expect(await mockEmergencyManager.isInEmergencyRecovery()).to.be.false;
      expect(await mockEmergencyManager.recoveryInitiatedTimestamp()).to.equal(0);
      expect(await mockEmergencyManager.hasApprovedRecovery(await owner.getAddress())).to.be.false;
    });
  });

  describe("Emergency States", function () {
    it("should allow setting emergency state", async function () {
      // Set to minor emergency
      await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY
      expect(await mockEmergencyManager.getEmergencyState()).to.equal(1);

      // Set to critical emergency
      await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY
      expect(await mockEmergencyManager.getEmergencyState()).to.equal(2);

      // Set back to normal
      await mockEmergencyManager.setEmergencyState(0); // NORMAL
      expect(await mockEmergencyManager.getEmergencyState()).to.equal(0);
    });

    it("should track emergency withdrawal processing", async function () {
      // Check initial state
      expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.false;

      // Process emergency withdrawal
      const withdrawalAmount = ethers.parseEther("1000");
      await mockEmergencyManager.processEmergencyWithdrawal(await user1.getAddress(), withdrawalAmount);

      // Verify processing
      expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.true;
      expect(await mockEmergencyManager.withdrawalAmounts(await user1.getAddress())).to.equal(withdrawalAmount);
    });
  });
});

// Helper for event testing with any value
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");