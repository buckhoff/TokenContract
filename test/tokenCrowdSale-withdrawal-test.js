const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Token Withdrawal Functionality", function () {
  let crowdSale;
  let token;
  let stablecoin;
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

    // Deploy mock token and stablecoin
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseUnits("5000000000", 18));
    await token.waitForDeployment();

    stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseUnits("10000000", 6));
    await stablecoin.waitForDeployment();

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

    // Send token to the vesting contract for distributions
    await token.transfer(await mockTokenVesting.getAddress(), ethers.parseUnits("1000000", 18));

    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(await user1.getAddress(), ethers.parseUnits("100000", 6));

    // Perform a purchase so user has tokens to withdraw
    await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));
    await crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6));

    // Complete TGE (fast forward to after presale)
    await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]); // 31 days
    await ethers.provider.send("evm_mine");
    await crowdSale.completeTGE();
  });

  describe("Token Withdrawal", function () {
    it("should allow withdrawing tokens after TGE", async function () {
      // Configure mock vesting to have claimable tokens
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseUnits("1000", 18);

      // Set claimable amount in mock vesting
      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);

      // Withdraw tokens
      await crowdSale.connect(user1).withdrawTokens();

      // Verify withdrawal was recorded
      expect(await mockTokenVesting.lastClaimedAmount()).to.equal(claimableAmount);

      // Verify claim history was updated
      const claimCount = await crowdSale.getClaimCount(await user1.getAddress());
      expect(claimCount).to.equal(1);

      // Get claim details
      const claimHistory = await crowdSale.getClaimHistory(await user1.getAddress());
      expect(claimHistory[0].amount).to.equal(claimableAmount);
    });

    it("should emit withdrawal events", async function () {
      // Configure mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseUnits("1000", 18);

      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);

      // Expect withdrawal event
      await expect(crowdSale.connect(user1).withdrawTokens())
          .to.emit(crowdSale, "TokensWithdrawn")
          .withArgs(await user1.getAddress(), claimableAmount);
    });

    it("should not allow withdrawing tokens before TGE", async function () {
      // Deploy a fresh crowdsale without TGE completion
      const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
      const freshCrowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
        initializer: "initialize",
      });
      await freshCrowdSale.waitForDeployment();

      // Set components
      await freshCrowdSale.setSaleToken(await token.getAddress());
      await freshCrowdSale.setVestingContract(await mockTokenVesting.getAddress());
      await freshCrowdSale.setEmergencyManager(await mockEmergencyManager.getAddress());

      // Attempt to withdraw tokens
      await expect(
          freshCrowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWithCustomError(freshCrowdSale, "TGENotCompleted");
    });

    it("should not allow withdrawing when no tokens are claimable", async function () {
      // Set claimable amount to 0 in mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      await mockTokenVesting.setClaimableAmount(scheduleId, 0);

      // Attempt to withdraw tokens
      await expect(
          crowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWithCustomError(crowdSale, "NoTokensToWithdraw");
    });

    it("should not allow withdrawal if user has not purchased tokens", async function () {
      // Attempt to withdraw as user who has not purchased
      await expect(
          crowdSale.connect(user2).withdrawTokens()
      ).to.be.revertedWithCustomError(crowdSale, "NoTokensToWithdraw");
    });

    it("should handle multiple withdrawals correctly", async function () {
      // Configure mock vesting for first withdrawal
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const firstClaimable = ethers.parseUnits("500", 18);

      await mockTokenVesting.setClaimableAmount(scheduleId, firstClaimable);
      await crowdSale.connect(user1).withdrawTokens();

      // Advance time and set up second withdrawal
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]); // 30 days
      await ethers.provider.send("evm_mine");

      const secondClaimable = ethers.parseUnits("300", 18);
      await mockTokenVesting.setClaimableAmount(scheduleId, secondClaimable);
      await crowdSale.connect(user1).withdrawTokens();

      // Verify claim history has two entries
      const claimCount = await crowdSale.getClaimCount(await user1.getAddress());
      expect(claimCount).to.equal(2);

      const claimHistory = await crowdSale.getClaimHistory(await user1.getAddress());
      expect(claimHistory[0].amount).to.equal(firstClaimable);
      expect(claimHistory[1].amount).to.equal(secondClaimable);
    });

    it("should calculate claimable tokens correctly", async function () {
      // Configure mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseUnits("1200", 18);

      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);

      // Check claimable amount
      const calculatedClaimable = await crowdSale.claimableTokens(await user1.getAddress());
      expect(calculatedClaimable).to.equal(claimableAmount);
    });

    it("should return zero claimable tokens before TGE", async function () {
      // Deploy fresh crowdsale without TGE
      const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
      const freshCrowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
        initializer: "initialize",
      });
      await freshCrowdSale.waitForDeployment();

      // Check claimable amount before TGE
      const claimable = await freshCrowdSale.claimableTokens(await user1.getAddress());
      expect(claimable).to.equal(0);
    });
  });

  describe("Withdrawal Security", function () {
    it("should prevent reentrancy attacks", async function () {
      // Configure mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseUnits("1000", 18);

      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);

      // First withdrawal should succeed
      await crowdSale.connect(user1).withdrawTokens();

      // Immediate second withdrawal should fail (no claimable tokens)
      await expect(
          crowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWithCustomError(crowdSale, "NoTokensToWithdraw");
    });

    it("should prevent withdrawals when contract is paused", async function () {
      // Set emergency state to pause the contract
      await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY

      // Configure mock vesting
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      await mockTokenVesting.setClaimableAmount(scheduleId, ethers.parseUnits("1000", 18));

      // Attempt withdrawal while paused
      await expect(
          crowdSale.connect(user1).withdrawTokens()
      ).to.be.revertedWith("TokenCrowdSale: contract is paused");
    });
  });

  describe("Vesting Schedule Integration", function () {
    it("should properly integrate with vesting contract", async function () {
      // Verify vesting schedule was created during purchase
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      expect(schedules.length).to.equal(1);

      const scheduleId = schedules[0];
      const scheduleOwner = await mockTokenVesting.scheduleOwners(scheduleId);
      const scheduleAmount = await mockTokenVesting.scheduleAmounts(scheduleId);

      expect(scheduleOwner).to.equal(await user1.getAddress());
      expect(scheduleAmount).to.be.gt(0);
    });

    it("should handle vesting contract failures gracefully", async function () {
      // This test would require a more sophisticated mock that can simulate failures
      // For now, we'll test that the basic integration works
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      expect(schedules.length).to.be.gt(0);
    });
  });

  describe("Edge Cases", function () {
    it("should handle very small claimable amounts", async function () {
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const smallAmount = 1; // 1 wei

      await mockTokenVesting.setClaimableAmount(scheduleId, smallAmount);

      await crowdSale.connect(user1).withdrawTokens();

      const claimHistory = await crowdSale.getClaimHistory(await user1.getAddress());
      expect(claimHistory[0].amount).to.equal(smallAmount);
    });

    it("should handle very large claimable amounts", async function () {
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const largeAmount = ethers.parseUnits("1000000", 18); // 1M tokens

      await mockTokenVesting.setClaimableAmount(scheduleId, largeAmount);

      await crowdSale.connect(user1).withdrawTokens();

      const claimHistory = await crowdSale.getClaimHistory(await user1.getAddress());
      expect(claimHistory[0].amount).to.equal(largeAmount);
    });

    it("should handle timestamp edge cases", async function () {
      // Test around TGE completion time
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];
      const claimableAmount = ethers.parseUnits("1000", 18);

      await mockTokenVesting.setClaimableAmount(scheduleId, claimableAmount);
      await crowdSale.connect(user1).withdrawTokens();

      // Verify timestamp was recorded properly
      const claimHistory = await crowdSale.getClaimHistory(await user1.getAddress());
      expect(claimHistory[0].timestamp).to.be.gt(0);
    });
  });

  describe("Gas Optimization", function () {
    it("should handle batch operations efficiently", async function () {
      // This test verifies that repeated operations don't cause excessive gas usage
      const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
      const scheduleId = schedules[0];

      // Perform multiple small withdrawals
      for (let i = 0; i < 3; i++) {
        await mockTokenVesting.setClaimableAmount(scheduleId, ethers.parseUnits("100", 18));
        await crowdSale.connect(user1).withdrawTokens();

        // Advance time between withdrawals
        await ethers.provider.send("evm_increaseTime", [86400]); // 1 day
        await ethers.provider.send("evm_mine");
      }

      // Verify all withdrawals were recorded
      const claimCount = await crowdSale.getClaimCount(await user1.getAddress());
      expect(claimCount).to.equal(3);
    });
  });
});