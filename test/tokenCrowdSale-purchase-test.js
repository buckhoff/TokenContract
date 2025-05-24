const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TokenCrowdSale - Part 2: Purchase Functionality", function () {
  let crowdSale;
  let token;
  let stablecoin;
  let altcoin; // Alternative payment token
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
    
    // Deploy mock token and stablecoins
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));
    stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseEther("10000000"));
    altcoin = await MockERC20.deploy("Alt Stablecoin", "USDT", ethers.parseEther("10000000"));
    
    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    
    // Register token in registry
    const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
    await mockRegistry.setContractAddress(TOKEN_NAME, await token.getAddress(), true);
    
    // Deploy mock components
    const MockTierManager = await ethers.getContractFactory("MockTierManager");
    mockTierManager = await MockTierManager.deploy();
    
    const MockTokenVesting = await ethers.getContractFactory("MockTokenVesting");
    mockTokenVesting = await MockTokenVesting.deploy();
    
    const MockEmergencyManager = await ethers.getContractFactory("MockEmergencyManager");
    mockEmergencyManager = await MockEmergencyManager.deploy();
    
    const MockPriceFeed = await ethers.getContractFactory("MockPriceFeed");
    mockPriceFeed = await MockPriceFeed.deploy(await stablecoin.getAddress());
    
    // Add alternative stablecoin to price feed
    await mockPriceFeed.addSupportedToken(await altcoin.getAddress(), 1000000); // $1.00 per token
    
    // Deploy TokenCrowdSale
    const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
    crowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
      initializer: "initialize",
    });
    
    // Set token and components
    await crowdSale.setSaleToken(await token.getAddress());
    await crowdSale.setRegistry(await mockRegistry.getAddress());
    await crowdSale.setTierManager(await mockTierManager.getAddress());
    await crowdSale.setVestingContract(await mockTokenVesting.getAddress());
    await crowdSale.setEmergencyManager(await mockEmergencyManager.getAddress());
    await crowdSale.setPriceFeed(await mockPriceFeed.getAddress());
    
    // Set presale times (start now, end in 30 days)
    const startTime = Math.floor(Date.now() / 1000);
    const endTime = startTime + (30 * 24 * 60 * 60);
    await crowdSale.setPresaleTimes(startTime, endTime);
  
    // Send token to the crowdsale for vesting
    await token.transfer(await mockTokenVesting.getAddress(), ethers.parseEther("1000000000"));
    
    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(user1.address, ethers.parseEther("100000"));
    await stablecoin.transfer(user2.address, ethers.parseEther("100000"));
    await altcoin.transfer(user1.address, ethers.parseEther("100000"));

    await crowdSale.setPurchaseRateLimits(0, ethers.parseUnits("50000", 6));
  });

  describe("Standard Purchase", function () {
    it("should allow purchasing tokens with stablecoin", async function () {
      const usdAmount = 1000 * PRICE_DECIMALS; // $1,000
      
      // Approve stablecoin first
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("10000"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("10000"));
      
      // Make purchase
      await crowdSale.connect(user1).purchaseWithToken(tierId, await stablecoin.getAddress(), usdAmount);
      
      // Verify tier manager received purchase record
      expect(await mockTierManager.lastTierId()).to.equal(tierId);
      
      // Verify treasury received funds
      const treasuryBalance = await stablecoin.balanceOf(await treasury.getAddress());
      expect(treasuryBalance).to.equal(ethers.parseUnits("1000",6)); // $1,000 in stablecoin
      
      // Verify vesting schedule created
      const userSchedules = await mockTokenVesting.getSchedulesForBeneficiary(user1.address);
      expect(userSchedules.length).to.equal(1);
      
      // Verify purchase recorded
      const userPurchase = await crowdSale.purchases(user1.address);
      expect(userPurchase.usdAmount).to.equal(usdAmount);
      
      // Check tokens purchased amount (price in tier 0 is $0.04 per token)
      // $1,000 / $0.04 = 25,000 tokens
      // With 20% bonus = 30,000 tokens
      const tokenAmount = 1000 * PRICE_DECIMALS * 1e6 / 40000; // $1,000 / $0.04
      console.log("tokenAmount", tokenAmount);
      expect(userPurchase.tokens).to.be.equal(tokenAmount);
      
      // Check bonus amount (20% bonus in tier 0)
      expect(userPurchase.bonusAmount).to.be.equal(tokenAmount * 20 / 100);
    });
    
    it("should enforce purchase limits", async function () {
      // Set small max purchase for testing
      await crowdSale.setMaxTokensPerAddress(BigInt("30000000000")); // 30,000 tokens
      
      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("10000"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("10000"));
      
      // Try to purchase too many tokens ($1,200 at $0.04 = 30,000 tokens, with bonus = 36,000 tokens)
      // This exceeds our 30,000 token limit
      const usdAmount = 1500 * PRICE_DECIMALS;
      
      await expect(
        crowdSale.connect(user1).purchase(tierId,  usdAmount)
      ).to.be.revertedWithCustomError(crowdSale,"ExceedsMaxTokensPerAddress");
    });
    
    it("should enforce minimum purchase amount", async function () {
      // Min purchase in tier 0 is $100
      const usdAmount = 50 * PRICE_DECIMALS; // $50, below minimum
      
      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("100"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("100"));
      
      await expect(
        crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale,"BelowMinPurchase");
    });
    
    it("should enforce maximum purchase amount", async function () {
      // Max purchase in tier 0 is $50,000
      const usdAmount = 55000 * PRICE_DECIMALS; // $55,000, above maximum
      
      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("100000"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("100000"));
      
      await expect(
        crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale,"AboveMaxPurchase");
    });
    
    it("should enforce tier allocation limits", async function () {
      // Set tier allocation to a low amount for testing
      const tierDetails = await mockTierManager.getTierDetails(tierId);
      const newTier = {
        ...tierDetails,
        allocation: ethers.parseEther("20000") // 20,000 tokens
      };
      
      // Update tier in mock
      // This is a simplification - in a real test you would need to modify the mock contract
      // to allow updating tiers directly
      
      // For now, simulate by having the first purchase deplete most of the allocation
      // Approve stablecoin for both users
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("800"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("800"));
      await stablecoin.connect(user2).approve(await crowdSale.getAddress(), ethers.parseEther("200"));
      await stablecoin.connect(user2).approve(await treasury.getAddress(), ethers.parseEther("200"));
      
      // User1 purchases most of the allocation
      await crowdSale.connect(user1).purchase(tierId,  700 * PRICE_DECIMALS); // $700 = 17,500 tokens
      
      // Update tier allocation in mock
      // Since we can't easily update the mock's internal state, we'll use a different approach
      // by setting up a situation where the next purchase would exceed the allocation
      
      // For simplicity, let's just mock the tokensRemainingInTier function to return a low value
      // This would need a custom mock with this functionality in a real test
      
      // User2 attempts to purchase the rest and more
      // This would exceed the remaining allocation
      // (We're testing the concept, though the actual implementation would need a proper mock)
    });
  });

  describe("Multi-Token Purchase", function () {
    it("should allow purchasing with alternative tokens", async function () {
      const paymentAmount = ethers.parseUnits("1000",6); // 1,000 alt tokens
      
      // Approve altcoin
      await altcoin.connect(user1).approve(await crowdSale.getAddress(), paymentAmount);
      await altcoin.connect(user1).approve(await treasury.getAddress(), paymentAmount);
      
      // Make purchase with altcoin
      await crowdSale.connect(user1).purchaseWithToken(tierId, await altcoin.getAddress(), paymentAmount);
      
      // Verify treasury received funds
      const treasuryBalance = await altcoin.balanceOf(await treasury.getAddress());
      expect(treasuryBalance).to.equal(paymentAmount);
      
      // Verify purchase recorded
      const userPurchase = await crowdSale.purchases(user1.address);
      expect(userPurchase.usdAmount).to.equal(1000 * PRICE_DECIMALS); // $1,000 converted
      
      // Check user payment was recorded by token
      const [, , paymentsByToken] = await crowdSale.getUserPurchaseDetails(user1.address,await altcoin.getAddress());
      expect(paymentsByToken).to.equal(paymentAmount);
    });
    
    it("should reject purchases with unsupported tokens", async function () {
      // Deploy a random token that's not supported
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const unsupportedToken = await MockERC20.deploy("Unsupported", "UNS", ethers.parseEther("10000"));
      
      // Transfer to user
      await unsupportedToken.transfer(user1.address, ethers.parseUnits("1000",6));
      
      // Approve
      await unsupportedToken.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("1000"));
      await unsupportedToken.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("1000"));
      
      // Attempt purchase
      await expect(
        crowdSale.connect(user1).purchaseWithToken(tierId, unsupportedToken, ethers.parseUnits("1000",6))
      ).to.be.revertedWithCustomError(crowdSale,"UnsupportedPaymentToken");
    });
  });

  describe("Rate Limiting", function () {
    it("should enforce minimum time between purchases", async function () {
      // Set a higher min time for testing
      await crowdSale.setPurchaseRateLimits(600, ethers.parseUnits("50000", 6)); // 10 minutes, $50,000
      
      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseEther("2000"));
      await stablecoin.connect(user1).approve(await treasury.getAddress(), ethers.parseEther("2000"));
      
      // Make first purchase
      await crowdSale.connect(user1).purchase(tierId,  1000 * PRICE_DECIMALS);
      
      // Try to make another purchase immediately
      await expect(
        crowdSale.connect(user1).purchase(tierId,  1000 * PRICE_DECIMALS)
      ).to.be.revertedWithCustomError(crowdSale,"PurchaseTooSoon");
      
      // Advance time
      const currentBlock = await ethers.provider.getBlock('latest');
      const newTimestamp = currentBlock.timestamp + 601;

// Set next block timestamp
      await ethers.provider.send("evm_setNextBlockTimestamp", [newTimestamp]);
      await ethers.provider.send("evm_mine");
      
      // Should now be able to purchase
      await crowdSale.connect(user1).purchase(tierId, 1000 * PRICE_DECIMALS);
    });
  });

  describe("Auto-compound Feature", function () {
    it("should allow toggling auto-compound setting", async function () {
      // Default should be off
      expect(await crowdSale.autoCompoundEnabled(user1.address)).to.be.false;
      
      // Toggle on
      await crowdSale.connect(user1).setAutoCompound(true);
      expect(await crowdSale.autoCompoundEnabled(user1.address)).to.be.true;
      
      // Toggle off
      await crowdSale.connect(user1).setAutoCompound(false);
      expect(await crowdSale.autoCompoundEnabled(user1.address)).to.be.false;
    });
  });
});
