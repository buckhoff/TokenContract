const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Part 3: Token Withdrawal and Emergency Functions", function () {
  let crowdSale;
  let token;
  let stablecoin;
  let mockRegistry;
  let mockTierManager;
  let mockTokenVesting;
  let mockEmergencyManager;
  let mockPriceFeed;
  
  let owner, admin, treasury, user1, user2;
  
  // Constants
  const PRICE_DECIMALS = 1000000; // 6 decimals for USD prices
  const tierId = 0; // First tier
  
  beforeEach(async function () {
    // Get signers
    [owner, admin, treasury, user1, user2] = await ethers.getSigners();
    
    // Deploy mock token and stablecoin
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));
    stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseEther("10000000"));
    
    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    
    // Register token in registry
    const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
    await mockRegistry.setContractAddress(TOKEN_NAME, token.address, true);
    
    // Deploy mock components
    const MockTierManager = await ethers.getContractFactory("MockTierManager");
    mockTierManager = await MockTierManager.deploy();
    
    const MockTokenVesting = await ethers.getContractFactory("MockTokenVesting");
    mockTokenVesting = await MockTokenVesting.deploy();
    
    const MockEmergencyManager = await ethers.getContractFactory("MockEmergencyManager");
    mockEmergencyManager = await MockEmergencyManager.deploy();
    
    const MockPriceFeed = await ethers.getContractFactory("MockPriceFeed");
    mockPriceFeed = await MockPriceFeed.deploy(stablecoin.address);
    
    // Deploy TokenCrowdSale
    const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
    crowdSale = await upgrades.deployProxy(TokenCrowdSale, [treasury.address], {
      initializer: "initialize",
    });
    
    // Set token and components
    await crowdSale.setSaleToken(token.address);
    await crowdSale.setRegistry(mockRegistry.address);
    await crowdSale.setTierManager(mockTierManager.address);
    await crowdSale.setVestingContract(mockTokenVesting.address);
    await crowdSale.setEmergencyManager(mockEmergencyManager.address);
    await crowdSale.setPriceFeed(mockPriceFeed.address);
    
    // Set presale times (start now, end in 30 days)
    const startTime = Math.floor(Date.now() / 1000);
    const endTime = startTime + (30 * 24 * 60 * 60);
    await crowdSale.setPresaleTimes(startTime, endTime);
    
    // Send token to the vesting contract for distributions
    await token.transfer(mockTokenVesting.address, ethers.parseEther("1000000"));
    
    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(user1.address, ethers.parseEther("100000"));
    
    // Perform a purchase so user has tokens to withdraw
    await stablecoin.connect(user1).approve(crowdSale.address, ethers.parseEther("1000"));
    await stablecoin.connect(user1).approve(treasury.address, ethers.parseEther("1000"));
    await crowdSale.connect(user1).purchase(tierId, 1000 * PRICE_DECIMALS);
    
    // Complete TGE (fast forward to after presale)
    await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]); // 31 days
    await ethers.provider.send("evm_mine");
    await crowdSale.completeTGE();
  });

  describe("Token Withdrawal", function () {
    it("should allow withdrawing tokens after TGE", async function () {
      // Configure mock vesting to have claimable tokens
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(user1.address);
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseEther("1000");
      
      // Set claimable amount in mock vesting
      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);
      
      // Withdraw tokens
      await crowdSale.connect(user1).withdrawTokens();
      
      // Verify withdrawal was recorded
      expect(await mockTokenVesting.lastClaimedAmount()).to.equal(claimableAmount);
      
      // Verify claim history was updated
      const claimCount = await crowdSale.getClaimCount(user1.address);
      expect(claimCount).to.equal(1);
      
      // Get claim details
      const claimHistory = await crowdSale.getClaimHistory(user1.address);
      expect(claimHistory[0].amount).to.equal(claimableAmount);
    });
    
    it("should not allow withdrawing tokens before TGE", async function () {
      // Revert TGE completion for this test
      await crowdSale.setTGECompleted(false);
      
      // Attempt to withdraw tokens
      await expect(
        crowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWith("TGENotCompleted");
    });
    
    it("should not allow withdrawing when no tokens are claimable", async function () {
      // Set claimable amount to 0 in mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(user1.address);
      const scheduleId = schedules[0];
      await mockTokenVesting.setClaimableAmount(scheduleId, 0);
      
      // Attempt to withdraw tokens
      await expect(
        crowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWith("NoTokensToWithdraw");
    });
    
    it("should not allow withdrawal if user has not purchased tokens", async function () {
      // Attempt to withdraw as user who has not purchased
      await expect(
        crowdSale.connect(user2).withdrawTokens()
      ).to.be.revertedWith("NoTokensToWithdraw");
    });
  });

  describe("Emergency Operations", function () {
    beforeEach(async function () {
      // Set emergency state to critical
      await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY = 2
    });
    
    it("should allow emergency withdrawal in critical state", async function () {
      // Record user's purchase in USDC for emergency withdrawal
      const userUsdAmount = 1000 * PRICE_DECIMALS;
      
      // Transfer stablecoin to treasury to simulate refund
      await stablecoin.transfer(treasury.address, ethers.parseEther("1000"));
      
      // Approve treasury to send tokens back (simulating treasury's approval)
      await stablecoin.connect(treasury).approve(crowdSale.address, ethers.parseEther("1000"));
      
      // Initial balances
      const initialUserBalance = await stablecoin.balanceOf(user1.address);
      
      // Perform emergency withdrawal
      await crowdSale.connect(user1).emergencyWithdraw();
      
      // Verify emergency manager processed withdrawal
      expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(user1.address)).to.be.true;
      expect(await mockEmergencyManager.withdrawalAmounts(user1.address)).to.equal(userUsdAmount);
      
      // Verify user received refund
      const finalUserBalance = await stablecoin.balanceOf(user1.address);
      expect(finalUserBalance.sub(initialUserBalance)).to.equal(ethers.parseEther("1000"));
    });
    
    it("should not allow emergency withdrawal in normal state", async function () {
      // Set emergency state back to normal
      await mockEmergencyManager.setEmergencyState(0); // NORMAL = 0
      
      // Attempt emergency withdrawal
      await expect(
        crowdSale.connect(user1).emergencyWithdraw()
      ).to.be.revertedWith("Not in critical emergency");
    });
    
    it("should prevent double emergency withdrawals", async function () {
      // Transfer stablecoin to treasury to simulate refund
      await stablecoin.transfer(treasury.address, ethers.parseEther("1000"));
      
      // Approve treasury to send tokens back
      await stablecoin.connect(treasury).approve(crowdSale.address, ethers.parseEther("1000"));
      
      // First withdrawal succeeds
      await crowdSale.connect(user1).emergencyWithdraw();
      
      // Mark user as already processed in mock emergency manager
      await mockEmergencyManager.processEmergencyWithdrawal(user1.address, 1000 * PRICE_DECIMALS);
      
      // Second attempt should fail
      await expect(
        crowdSale.connect(user1).emergencyWithdraw()
      ).to.be.revertedWith("Already processed");
    });
  });

  describe("Token Recovery", function () {
    it("should allow admin to recover tokens sent by mistake", async function () {
      // Deploy a token that's not part of the crowdsale
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseEther("1000"));
      
      // Send tokens to crowdsale by mistake
      const amount = ethers.parseEther("100");
      await wrongToken.transfer(crowdSale.address, amount);
      
      // Admin recovers tokens
      const initialBalance = await wrongToken.balanceOf(owner.address);
      await crowdSale.recoverTokens(wrongToken.address);
      
      // Verify tokens recovered
      const finalBalance = await wrongToken.balanceOf(owner.address);
      expect(finalBalance.sub(initialBalance)).to.equal(amount);
    });
    
    it("should not allow recovering the crowdsale token", async function () {
      // Attempt to recover the actual token
      await expect(
        crowdSale.recoverTokens(token.address)
      ).to.be.revertedWith("Cannot recover tokens");
    });
    
    it("should not allow non-admin to recover tokens", async function () {
      // Deploy a token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseEther("1000"));
      
      // Send tokens to crowdsale
      await wrongToken.transfer(crowdSale.address, ethers.parseEther("100"));
      
      // Attempt recovery as non-admin
      await expect(
        crowdSale.connect(user1).recoverTokens(wrongToken.address)
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Contract References", function () {
    it("should update token address from registry", async function () {
      // Deploy a new token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20.deploy("New Token", "NTK", ethers.parseEther("1000000"));
      
      // Update registry
      const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
      await mockRegistry.setContractAddress(TOKEN_NAME, newToken.address, true);
      
      // Update contract references
      await crowdSale.updateContractReferences();
      
      // Verify token address updated
      expect(await crowdSale.token()).to.equal(newToken.address);
    });
  });

  describe("TGE Completion", function () {
    it("should properly track TGE completion state", async function () {
      expect(await crowdSale.tgeCompleted()).to.be.true;
      
      // Test the function that will be used by child tests
      await crowdSale.setTGECompleted(false);
      expect(await crowdSale.tgeCompleted()).to.be.false;
      
      await crowdSale.setTGECompleted(true);
      expect(await crowdSale.tgeCompleted()).to.be.true;
    });
  });
});
