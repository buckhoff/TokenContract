const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Purchase Functionality", function () {
  let crowdSale;
  let token;
  let stablecoin;
  let altcoin; // Alternative payment token
  let mockRegistry;
  let mockTierManager;
  let mockTokenVesting;
  let mockEmergencyManager;
  let mockPriceFeed;

  let owner, admin, minter, burner, treasury, emergency, user3, user2, user1;

  // Constants
  const tierId = 0; // First tier

  beforeEach(async function () {
    // Get all 9 signers as required
    [owner, admin, minter, burner, treasury, emergency, user3, user2, user1] = await ethers.getSigners();

    // Deploy mock token and stablecoins
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseUnits("5000000000", 18));
    await token.waitForDeployment();

    stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseUnits("10000000", 6));
    await stablecoin.waitForDeployment();

    altcoin = await MockERC20.deploy("Alt Stablecoin", "USDT", ethers.parseUnits("10000000", 6));
    await altcoin.waitForDeployment();

    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    await mockRegistry.waitForDeployment();

    // Register token in registry
    const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
    await mockRegistry.setContractAddress(TOKEN_NAME, await token.getAddress(), true);

    // Deploy mock components
    const MockTierManager = await ethers.getContractFactory("MockTierManager");
    mockTierManager = await MockTierManager.deploy();
    await mockTierManager.waitForDeployment();

    const MockTokenVesting = await ethers.getContractFactory("MockTokenVesting");
    mockTokenVesting = await MockTokenVesting.deploy();
    await mockTokenVesting.waitForDeployment();

    const MockEmergencyManager = await ethers.getContractFactory("MockEmergencyManager");
    mockEmergencyManager = await MockEmergencyManager.deploy();
    await mockEmergencyManager.waitForDeployment();

    const MockPriceFeed = await ethers.getContractFactory("MockPriceFeed");
    mockPriceFeed = await MockPriceFeed.deploy(await stablecoin.getAddress());
    await mockPriceFeed.waitForDeployment();

    // Add alternative stablecoin to price feed
    await mockPriceFeed.addSupportedToken(await altcoin.getAddress(), ethers.parseUnits("1", 6)); // $1.00 per token

    // Deploy TokenCrowdSale
    const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
    crowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
      initializer: "initialize",
    });
    await crowdSale.waitForDeployment();

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
    await token.transfer(await mockTokenVesting.getAddress(), ethers.parseUnits("1000000000", 18));

    // Transfer stablecoin to users for purchases - using 6 decimals for USD amounts
    await stablecoin.transfer(await user1.getAddress(), ethers.parseUnits("100000", 6));
    await stablecoin.transfer(await user2.getAddress(), ethers.parseUnits("100000", 6));
    await altcoin.transfer(await user1.getAddress(), ethers.parseUnits("100000", 6));
  });

  describe("Standard Purchase with Stablecoin", function () {
    it("should allow purchasing tokens with stablecoin", async function () {
      const usdAmount = ethers.parseUnits("1000", 6); // $1,000 with 6 decimals

      // Approve stablecoin first
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("10000", 6));

      // Make purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Verify tier manager received purchase record
      expect(await mockTierManager.lastTierId()).to.equal(tierId);

      // Verify treasury received funds
      const treasuryBalance = await stablecoin.balanceOf(await treasury.getAddress());
      expect(treasuryBalance).to.equal(ethers.parseUnits("1000", 6)); // $1,000 in stablecoin

      // Verify vesting schedule created
      const userSchedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      expect(userSchedules.length).to.equal(1);

      // Verify purchase recorded
      const [tokenAmount, usdAmountRecorded, ] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), ethers.ZeroAddress);
      expect(usdAmountRecorded).to.equal(usdAmount);

      // Check tokens purchased amount (price in tier 0 is $0.04 per token)
      // $1,000 / $0.04 = 25,000 tokens (18 decimals)
      // With 20% bonus = 30,000 tokens total
      const expectedTokens = ethers.parseUnits("25000", 18); // Base tokens
      const expectedBonus = ethers.parseUnits("5000", 18);   // 20% bonus
      const expectedTotal = expectedTokens + expectedBonus;

      expect(tokenAmount).to.equal(expectedTotal);
    });

    it("should enforce purchase limits", async function () {
      // Set small max purchase for testing
      await crowdSale.setMaxTokensPerAddress(ethers.parseUnits("30000", 6)); // 30,000 tokens

      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("10000", 6));

      // Try to purchase too many tokens ($1,200 at $0.04 = 30,000 tokens, with bonus = 36,000 tokens)
      // This exceeds our 30,000 token limit
      const usdAmount = ethers.parseUnits("1200", 6);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "ExceedsMaxTokensPerAddress");
    });

    it("should enforce minimum purchase amount", async function () {
      // Min purchase in tier 0 is $100
      const usdAmount = ethers.parseUnits("50", 6); // $50, below minimum

      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("100", 6));

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "BelowMinPurchase");
    });

    it("should enforce maximum purchase amount", async function () {
      // Max purchase in tier 0 is $50,000
      const usdAmount = ethers.parseUnits("55000", 6); // $55,000, above maximum

      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("100000", 6));

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "AboveMaxPurchase");
    });

    it("should prevent purchases when presale is not active", async function () {
      // Set presale times to past
      const pastTime = Math.floor(Date.now() / 1000) - (10 * 24 * 60 * 60); // 10 days ago
      await crowdSale.setPresaleTimes(pastTime - 86400, pastTime); // 1 day duration in past

      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "PresaleNotActive");
    });
  });

  describe("Multi-Token Purchase", function () {
    it("should allow purchasing with alternative tokens", async function () {
      const paymentAmount = ethers.parseUnits("1000", 6); // 1,000 alt tokens

      // Approve altcoin
      await altcoin.connect(user1).approve(await crowdSale.getAddress(), paymentAmount);

      // Make purchase with altcoin
      await crowdSale.connect(user1).purchaseWithToken(tierId, await altcoin.getAddress(), paymentAmount);

      // Verify treasury received funds
      const treasuryBalance = await altcoin.balanceOf(await treasury.getAddress());
      expect(treasuryBalance).to.equal(paymentAmount);

      // Verify purchase recorded
      const [, usdAmount, paymentsByToken] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), await altcoin.getAddress());
      expect(usdAmount).to.equal(ethers.parseUnits("1000", 6)); // $1,000 converted

      // Check user payment was recorded by token
      expect(paymentsByToken).to.equal(paymentAmount);
    });

    it("should reject purchases with unsupported tokens", async function () {
      // Deploy a random token that's not supported
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const unsupportedToken = await MockERC20.deploy("Unsupported", "UNS", ethers.parseUnits("10000", 6));
      await unsupportedToken.waitForDeployment();

      // Transfer to user
      await unsupportedToken.transfer(await user1.getAddress(), ethers.parseUnits("1000", 6));

      // Approve
      await unsupportedToken.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

      // Attempt purchase
      await expect(
          crowdSale.connect(user1).purchaseWithToken(tierId, await unsupportedToken.getAddress(), ethers.parseUnits("1000", 6))
      ).to.be.revertedWithCustomError(crowdSale, "UnsupportedPaymentToken");
    });

    it("should handle multiple token purchases correctly", async function () {
      // First purchase with USDC
      const usdcAmount = ethers.parseUnits("500", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdcAmount);
      await crowdSale.connect(user1).purchaseWithToken(tierId, await stablecoin.getAddress(), usdcAmount);

      // Second purchase with USDT
      const usdtAmount = ethers.parseUnits("300", 6);
      await altcoin.connect(user1).approve(await crowdSale.getAddress(), usdtAmount);
      await crowdSale.connect(user1).purchaseWithToken(tierId, await altcoin.getAddress(), usdtAmount);

      // Verify total USD amount
      const [, totalUsd, ] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), ethers.ZeroAddress);
      expect(totalUsd).to.equal(ethers.parseUnits("800", 6)); // $500 + $300

      // Verify individual token payments
      const [, , usdcPayments] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), await stablecoin.getAddress());
      const [, , usdtPayments] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), await altcoin.getAddress());

      expect(usdcPayments).to.equal(usdcAmount);
      expect(usdtPayments).to.equal(usdtAmount);
    });
  });

  describe("Rate Limiting", function () {
    it("should enforce minimum time between purchases", async function () {
      // Set a higher min time for testing
      await crowdSale.setPurchaseRateLimits(600, ethers.parseUnits("50000", 6)); // 10 minutes, $50,000

      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("2000", 6));

      // Make first purchase
      await crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6));

      // Try to make another purchase immediately
      await expect(
          crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6))
      ).to.be.revertedWithCustomError(crowdSale, "PurchaseTooSoon");

      // Advance time
      await ethers.provider.send("evm_increaseTime", [601]); // 10 minutes + 1 second
      await ethers.provider.send("evm_mine");

      // Should now be able to purchase
      await crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6));
    });

    it("should enforce maximum purchase amount per transaction", async function () {
      // Set low max purchase amount
      await crowdSale.setPurchaseRateLimits(3600, ethers.parseUnits("500", 6)); // 1 hour, $500 max

      // Approve stablecoin
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

      // Try to purchase above max amount
      await expect(
          crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("600", 6))
      ).to.be.revertedWithCustomError(crowdSale, "AboveMaxPurchase");
    });

    it("should allow different users to purchase simultaneously", async function () {
      // Set rate limits
      await crowdSale.setPurchaseRateLimits(600, ethers.parseUnits("50000", 6)); // 10 minutes, $50,000

      // Approve stablecoin for both users
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));
      await stablecoin.connect(user2).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

      // Both users should be able to purchase at the same time
      await crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6));
      await crowdSale.connect(user2).purchase(tierId, ethers.parseUnits("1000", 6));

      // Verify both purchases went through
      const [user1Tokens, , ] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), ethers.ZeroAddress);
      const [user2Tokens, , ] = await crowdSale.getUserPurchaseDetails(await user2.getAddress(), ethers.ZeroAddress);

      expect(user1Tokens).to.be.gt(0);
      expect(user2Tokens).to.be.gt(0);
    });
  });

  describe("Tier Validation", function () {
    it("should reject purchases from inactive tiers", async function () {
      // Deactivate tier 0
      await mockTierManager.setTierActive(0, false);

      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "TierNotActive");
    });

    it("should reject purchases with invalid tier IDs", async function () {
      const invalidTierId = 99;
      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      await expect(
          crowdSale.connect(user1).purchase(invalidTierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "InvalidTierId");
    });

    it("should enforce tier purchase limits", async function () {
      const usdAmount = ethers.parseUnits("60000", 6); // Above tier max of $50,000
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWithCustomError(crowdSale, "ExceedsMaxTierPurchase");
    });
  });

  describe("Bonus Calculation", function () {
    it("should apply correct bonus percentages", async function () {
      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      // Make purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Verify bonus was applied (20% for tier 0)
      const [totalTokens, , ] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), ethers.ZeroAddress);
      const expectedBaseTokens = ethers.parseUnits("25000", 18); // $1000 / $0.04
      const expectedBonusTokens = ethers.parseUnits("5000", 18); // 20% bonus
      const expectedTotal = expectedBaseTokens + expectedBonusTokens;

      expect(totalTokens).to.equal(expectedTotal);
    });

    it("should handle zero bonus correctly", async function () {
      // Set tier bonus to 0%
      await mockTierManager.setTierBonus(0, 0);

      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      // Make purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Verify no bonus was applied
      const [totalTokens, , ] = await crowdSale.getUserPurchaseDetails(await user1.getAddress(), ethers.ZeroAddress);
      const expectedTokens = ethers.parseUnits("25000", 18); // $1000 / $0.04, no bonus

      expect(totalTokens).to.equal(expectedTokens);
    });
  });

  describe("Vesting Schedule Creation", function () {
    it("should create vesting schedule on first purchase", async function () {
      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      // Make purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Verify vesting schedule was created
      const userSchedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      expect(userSchedules.length).to.equal(1);

      // Verify schedule has correct parameters
      const scheduleId = userSchedules[0];
      const scheduleAmount = await mockTokenVesting.scheduleAmounts(scheduleId);
      const scheduleTge = await mockTokenVesting.scheduleTgePercentages(scheduleId);
      const scheduleDuration = await mockTokenVesting.scheduleDurations(scheduleId);

      expect(scheduleAmount).to.be.gt(0);
      expect(scheduleTge).to.equal(20); // 20% TGE from tier
      expect(scheduleDuration).to.equal(6 * 30 * 24 * 60 * 60); // 6 months in seconds
    });

    it("should not create multiple vesting schedules for same user", async function () {
      const usdAmount = ethers.parseUnits("500", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

      // Make first purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Advance time to bypass rate limiting
      await ethers.provider.send("evm_increaseTime", [3601]); // 1 hour + 1 second
      await ethers.provider.send("evm_mine");

      // Make second purchase
      await crowdSale.connect(user1).purchase(tierId, usdAmount);

      // Should still have only one vesting schedule
      const userSchedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      expect(userSchedules.length).to.equal(1);
    });
  });

  describe("Purchase Events", function () {
    it("should emit purchase events correctly", async function () {
      const usdAmount = ethers.parseUnits("1000", 6);
      const paymentAmount = ethers.parseUnits("1000", 6);

      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), paymentAmount);

      await expect(
          crowdSale.connect(user1).purchaseWithToken(tierId, await stablecoin.getAddress(), paymentAmount)
      ).to.emit(crowdSale, "PurchaseWithToken")
          .withArgs(
              await user1.getAddress(),
              tierId,
              await stablecoin.getAddress(),
              paymentAmount,
              ethers.parseUnits("25000", 18), // Expected token amount
              usdAmount
          );
    });
  });

  describe("Emergency Pause During Purchase", function () {
    it("should prevent purchases when emergency manager is paused", async function () {
      // Set emergency state to paused
      await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY

      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.revertedWith("TokenCrowdSale: contract is paused");
    });

    it("should allow purchases when emergency state is normal", async function () {
      // Ensure emergency state is normal
      await mockEmergencyManager.setEmergencyState(0); // NORMAL

      const usdAmount = ethers.parseUnits("1000", 6);
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), usdAmount);

      // Purchase should succeed
      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.not.be.reverted;
    });
  });

  describe("Insufficient Balance/Allowance", function () {
    it("should revert when user has insufficient token balance", async function () {
      // Transfer away user's tokens
      await stablecoin.connect(user1).transfer(await user2.getAddress(), ethers.parseUnits("100000", 6));

      const usdAmount = ethers.parseUnits("1000", 6);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.reverted; // ERC20 transfer will fail
    });

    it("should revert when user has insufficient allowance", async function () {
      const usdAmount = ethers.parseUnits("1000", 6);
      const insufficientAllowance = ethers.parseUnits("500", 6);

      // Approve insufficient amount
      await stablecoin.connect(user1).approve(await crowdSale.getAddress(), insufficientAllowance);

      await expect(
          crowdSale.connect(user1).purchase(tierId, usdAmount)
      ).to.be.reverted; // ERC20 transferFrom will fail
    });
  });
});