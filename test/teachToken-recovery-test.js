const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TeachToken - Part 3: Recovery and Emergency Functions", function () {
  let teachToken;
  let mockImmutableContract;
  let mockToken; // ERC20 token for recovery testing
  let owner, admin, emergency, user1, user2;
  
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
  
  beforeEach(async function () {
    // Get signers
    [owner, admin, emergency, user1, user2] = await ethers.getSigners();
    
    // Deploy mock immutable contract
    const MockImmutableTokenContract = await ethers.getContractFactory("MockImmutableTokenContract");
    mockImmutableContract = await MockImmutableTokenContract.deploy();
    
    // Deploy mock token for recovery testing
    const MockToken = await ethers.getContractFactory("MockERC20");
    mockToken = await MockToken.deploy("Mock Token", "MCK", ethers.parseEther("1000000"));
    
    // Deploy TeachToken
    const TeachToken = await ethers.getContractFactory("TeachToken");
    teachToken = await upgrades.deployProxy(TeachToken, [mockImmutableContract.address], {
      initializer: "initialize",
    });
    
    // Set up roles
    await teachToken.grantRole(ADMIN_ROLE, admin.address);
    await teachToken.grantRole(EMERGENCY_ROLE, emergency.address);
    
    // Perform initial distribution
    const addresses = Array(7).fill(owner.address);
    await teachToken.performInitialDistribution(...addresses);
    
    // Send some mock tokens to the contract
    await mockToken.transfer(teachToken.address, ethers.parseEther("1000"));
  });

  describe("Token Recovery", function () {
    it("should not allow recovery of non-allowed tokens", async function () {
      // Attempt to recover tokens that haven't been allowed
      await expect(
        teachToken.recoverERC20(mockToken.address, ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Token recovery not allowed");
    });
    
    it("should allow recovery after setting recovery allowance", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(mockToken.address, true);
      
      const recoveryAmount = ethers.parseEther("100");
      const initialBalance = await mockToken.balanceOf(owner.address);
      
      // Recover tokens
      await teachToken.recoverERC20(mockToken.address, recoveryAmount);
      
      // Check balance after recovery
      expect(await mockToken.balanceOf(owner.address)).to.equal(initialBalance.add(recoveryAmount));
      expect(await mockToken.balanceOf(teachToken.address)).to.equal(ethers.parseEther("900")); // 1000 - 100
    });
    
    it("should prevent recovery of the TEACH token itself", async function () {
      // Attempt to recover TEACH tokens
      await expect(
        teachToken.recoverERC20(teachToken.address, ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Cannot recover TEACH tokens");
    });
    
    it("should revert when trying to recover more tokens than available", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(mockToken.address, true);
      
      // Attempt to recover more tokens than available
      await expect(
        teachToken.recoverERC20(mockToken.address, ethers.parseEther("2000"))
      ).to.be.revertedWith("TeachToken: Insufficient balance");
    });
    
    it("should not allow non-admins to recover tokens", async function () {
      // Allow token recovery
      await teachToken.setRecoveryAllowedToken(mockToken.address, true);
      
      // Attempt to recover tokens as a non-admin
      await expect(
        teachToken.connect(user1).recoverERC20(mockToken.address, ethers.parseEther("100"))
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Pause and Unpause", function () {
    it("should allow admins to pause the contract", async function () {
      // Pause the contract
      await teachToken.pause();
      
      // Try to transfer tokens (should fail)
      await expect(
        teachToken.transfer(user1.address, ethers.parseEther("100"))
      ).to.be.revertedWith("TeachToken: Paused");
    });
    
    it("should allow admins to unpause the contract", async function () {
      // Pause the contract
      await teachToken.pause();
      
      // Unpause the contract
      await teachToken.unpause();
      
      // Try to transfer tokens (should succeed)
      const transferAmount = ethers.parseEther("100");
      await teachToken.transfer(user1.address, transferAmount);
      
      expect(await teachToken.balanceOf(user1.address)).to.equal(transferAmount);
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

  describe("Emergency Recovery", function () {
    beforeEach(async function () {
      // Set required approvals to 2 for testing
      await teachToken.connect(admin).setRequiredRecoveryApprovals(2);
      
      // Pause the contract first (required for emergency recovery)
      await teachToken.pause();
    });
    
    it("should allow initiating emergency recovery", async function () {
      // Initiate emergency recovery
      await teachToken.initiateEmergencyRecovery();
      
      // Verify we're in recovery mode (indirectly, as the variable might be private)
      const tx = await teachToken.connect(admin).approveRecovery();
      
      // If not in recovery mode, this would revert
      await expect(tx).to.not.be.reverted;
    });
    
    it("should complete recovery after sufficient approvals", async function () {
      // Initiate emergency recovery
      await teachToken.initiateEmergencyRecovery();
      
      // Approve from two admins
      await teachToken.connect(owner).approveRecovery();
      await teachToken.connect(admin).approveRecovery();
      
      // Verify contract is unpaused after successful recovery
      const transferAmount = ethers.parseEther("100");
      await teachToken.transfer(user1.address, transferAmount);
      
      expect(await teachToken.balanceOf(user1.address)).to.equal(transferAmount);
    });
    
    it("should not allow non-admins to approve recovery", async function () {
      // Initiate emergency recovery
      await teachToken.initiateEmergencyRecovery();
      
      // Attempt to approve as non-admin
      await expect(
        teachToken.connect(user1).approveRecovery()
      ).to.be.reverted; // Will revert due to role check
    });
    
    it("should not allow initiating recovery when not paused", async function () {
      // Unpause first
      await teachToken.unpause();
      
      // Attempt to initiate recovery
      await expect(
        teachToken.initiateEmergencyRecovery()
      ).to.be.revertedWith("Token: not paused");
    });
  });
});
