const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Part 1: Configuration and Setup", function () {
  let crowdSale;
  let token;
  let stablecoin;
  let mockRegistry;
  let mockTierManager;
  let mockTokenVesting;
  let mockEmergencyManager;
  let mockPriceFeed;
  let mockStabilityFund;

  let owner, admin, minter, burner, treasury, emergency, user3, user2, user1;

  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
  const RECORDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RECORDER_ROLE"));

  const TEACH_TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
  const TIER_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER"));
  const TOKEN_VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));
  const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));
  const PRICE_FEED_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_PRICE_FEED"));
  const STABILITY_FUND_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_STABILITY_FUND"));

  beforeEach(async function () {
    // Get 9 signers as requested
    [owner, admin, minter, burner, treasury, emergency, user3, user2, user1] = await ethers.getSigners();

    // Deploy mock token and stablecoin
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));
    await token.waitForDeployment();

    stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseEther("10000000"));
    await stablecoin.waitForDeployment();

    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    await mockRegistry.waitForDeployment();

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

    const MockStabilityFund = await ethers.getContractFactory("MockStabilityFund");
    mockStabilityFund = await MockStabilityFund.deploy();
    await mockStabilityFund.waitForDeployment();

    // Register all contracts in the registry
    await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await token.getAddress(), true);
    await mockRegistry.setContractAddress(TIER_MANAGER_NAME, await mockTierManager.getAddress(), true);
    await mockRegistry.setContractAddress(TOKEN_VESTING_NAME, await mockTokenVesting.getAddress(), true);
    await mockRegistry.setContractAddress(EMERGENCY_MANAGER_NAME, await mockEmergencyManager.getAddress(), true);
    await mockRegistry.setContractAddress(PRICE_FEED_NAME, await mockPriceFeed.getAddress(), true);
    await mockRegistry.setContractAddress(STABILITY_FUND_NAME, await mockStabilityFund.getAddress(), true);

    // Deploy TokenCrowdSale
    const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
    crowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
      initializer: "initialize",
    });
    await crowdSale.waitForDeployment();

    // Set up roles
    await crowdSale.grantRole(ADMIN_ROLE, await admin.getAddress());
    await crowdSale.grantRole(EMERGENCY_ROLE, await emergency.getAddress());
    await crowdSale.grantRole(RECORDER_ROLE, await admin.getAddress());

    // Set registry and let it discover contracts
    await crowdSale.setRegistry(await mockRegistry.getAddress());
    await crowdSale.updateContractReferences();

    // Set presale times (start now, end in 30 days)
    const startTime = Math.floor(Date.now() / 1000);
    const endTime = startTime + (30 * 24 * 60 * 60);
    await crowdSale.setPresaleTimes(startTime, endTime);

    // Send tokens to the vesting contract for distributions
    await token.transfer(await mockTokenVesting.getAddress(), ethers.parseEther("1000000000"));

    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(await user1.getAddress(), ethers.parseEther("100000"));
    await stablecoin.transfer(await user2.getAddress(), ethers.parseEther("100000"));
    await stablecoin.transfer(await user3.getAddress(), ethers.parseEther("100000"));
  });

  describe("Initialization and Setup", function () {
    it("should initialize with the correct treasury address", async function () {
      expect(await crowdSale.treasury()).to.equal(await treasury.getAddress());
    });

    it("should set the correct roles", async function () {
      expect(await crowdSale.hasRole(await crowdSale.DEFAULT_ADMIN_ROLE(), await owner.getAddress())).to.be.true;
      expect(await crowdSale.hasRole(ADMIN_ROLE, await admin.getAddress())).to.be.true;
      expect(await crowdSale.hasRole(EMERGENCY_ROLE, await emergency.getAddress())).to.be.true;
      expect(await crowdSale.hasRole(RECORDER_ROLE, await admin.getAddress())).to.be.true;
    });

    it("should discover contracts from registry", async function () {
      // Check that contracts were discovered from registry
      expect(await crowdSale.token()).to.equal(await token.getAddress());
      expect(await crowdSale.tierManager()).to.equal(await mockTierManager.getAddress());
      expect(await crowdSale.vestingContract()).to.equal(await mockTokenVesting.getAddress());
      expect(await crowdSale.emergencyManager()).to.equal(await mockEmergencyManager.getAddress());
      expect(await crowdSale.priceFeed()).to.equal(await mockPriceFeed.getAddress());
    });

    it("should properly set presale times", async function () {
      const startTime = await crowdSale.presaleStart();
      const endTime = await crowdSale.presaleEnd();

      expect(endTime).to.be.gt(startTime);
      expect(endTime - startTime).to.be.closeTo(30n * 24n * 60n * 60n, 60n); // 30 days ± 1 minute
    });

    it("should have correct registry set", async function () {
      expect(await crowdSale.registry()).to.equal(await mockRegistry.getAddress());
    });
  });

  describe("Contract Reference Updates", function () {
    it("should update contract references when registry changes", async function () {
      // Deploy new mock contracts
      const MockTierManager = await ethers.getContractFactory("MockTierManager");
      const newMockTierManager = await MockTierManager.deploy();
      await newMockTierManager.waitForDeployment();

      // Update registry
      await mockRegistry.setContractAddress(TIER_MANAGER_NAME, await newMockTierManager.getAddress(), true);

      // Update contract references
      await crowdSale.updateContractReferences();

      // Verify update
      expect(await crowdSale.tierManager()).to.equal(await newMockTierManager.getAddress());
    });

    it("should handle registry contract updates", async function () {
      // Deploy new token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20.deploy("New Token", "NTKN", ethers.parseEther("1000000"));
      await newToken.waitForDeployment();

      // Update registry
      await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await newToken.getAddress(), true);

      // Update contract references
      await crowdSale.updateContractReferences();

      // Verify token address updated
      expect(await crowdSale.token()).to.equal(await newToken.getAddress());
    });
  });

  describe("Component Validation", function () {
    it("should revert when setting invalid presale times", async function () {
      const currentTime = Math.floor(Date.now() / 1000);

      // End time before start time
      await expect(
          crowdSale.connect(admin).setPresaleTimes(currentTime + 1000, currentTime + 500)
      ).to.be.revertedWithCustomError(crowdSale,"InvalidPresaleTimes");
    });

    it("should only allow admins to set presale times", async function () {
      const currentTime = Math.floor(Date.now() / 1000);

      // Attempt to set presale times as non-admin
      await expect(
          crowdSale.connect(user1).setPresaleTimes(currentTime, currentTime + 1000)
      ).to.be.reverted; // Will revert due to role check

      // Set presale times as admin
      await crowdSale.connect(admin).setPresaleTimes(currentTime, currentTime + 1000);

      expect(await crowdSale.presaleStart()).to.equal(currentTime);
      expect(await crowdSale.presaleEnd()).to.equal(currentTime + 1000);
    });

    it("should only allow admins to update contract references", async function () {
      // Attempt to update as non-admin
      await expect(
          crowdSale.connect(user1).updateContractReferences()
      ).to.be.reverted; // Will revert due to role check

      // Update as admin should succeed
      await crowdSale.connect(admin).updateContractReferences();
    });
  });

  describe("Purchase Limits Configuration", function () {
    it("should have default purchase limits", async function () {
      // Check default max tokens per address
      expect(await crowdSale.maxTokensPerAddress()).to.equal(ethers.parseUnits("1500000", 6)); // 1,500,000 tokens

      // Check purchase rate limits
      expect(await crowdSale.minTimeBetweenPurchases()).to.equal(60 * 60); // 1 hour

      // Default max purchase amount in USD
      expect(await crowdSale.maxPurchaseAmount()).to.equal(ethers.parseUnits("50000", 6)); // $50,000
    });

    it("should allow admin to update max tokens per address", async function () {
      const newMax = ethers.parseUnits("2000000", 6); // 2,000,000 tokens
      await crowdSale.connect(admin).setMaxTokensPerAddress(newMax);
      expect(await crowdSale.maxTokensPerAddress()).to.equal(newMax);
    });

    it("should allow admin to update purchase rate limits", async function () {
      const newTime = 30 * 60; // 30 minutes
      const newMaxAmount = ethers.parseUnits("100000", 6); // $100,000

      await crowdSale.connect(admin).setPurchaseRateLimits(newTime, newMaxAmount);

      expect(await crowdSale.minTimeBetweenPurchases()).to.equal(newTime);
      expect(await crowdSale.maxPurchaseAmount()).to.equal(newMaxAmount);
    });

    it("should not allow non-admins to update limits", async function () {
      const newMax = ethers.parseUnits("2000000", 6);

      await expect(
          crowdSale.connect(user1).setMaxTokensPerAddress(newMax)
      ).to.be.reverted; // Will revert due to role check

      await expect(
          crowdSale.connect(user1).setPurchaseRateLimits(30 * 60, ethers.parseUnits("100000", 6))
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Token Generation Event Status", function () {
    it("should start with TGE not completed", async function () {
      expect(await crowdSale.tgeCompleted()).to.be.false;
    });

    it("should not allow completing TGE during active presale", async function () {
      // Attempt to complete TGE during active presale
      await expect(
          crowdSale.completeTGE()
      ).to.be.revertedWith("Presale still active");
    });

    it("should allow admin to complete TGE after presale ends", async function () {
      // Fast forward time to after presale end
      const endTime = await crowdSale.presaleEnd();
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(endTime) + 1]);
      await ethers.provider.send("evm_mine");

      // Complete TGE
      await crowdSale.completeTGE();
      expect(await crowdSale.tgeCompleted()).to.be.true;
    });

    it("should not allow non-admins to complete TGE", async function () {
      // Fast forward time to after presale end
      const endTime = await crowdSale.presaleEnd();
      const nextTimestamp = BigInt(endTime) + BigInt(1);
      await network.provider.send("evm_setNextBlockTimestamp", [nextTimestamp]);
      await ethers.provider.send("evm_mine");

      // Attempt to complete TGE as non-admin
      await expect(
          crowdSale.connect(user1).completeTGE()
      ).to.be.reverted; // Will revert due to role check
    });
  });

  describe("Registry Integration", function () {
    it("should handle registry offline mode", async function () {
      // This test assumes the crowdsale inherits from RegistryAware
      // and can handle registry offline scenarios

      // Set registry to offline mode (if this functionality exists)
      // await crowdSale.enableRegistryOfflineMode();

      // For now, just verify registry is set correctly
      expect(await crowdSale.registry()).to.equal(await mockRegistry.getAddress());
    });

    it("should handle inactive contracts in registry", async function () {
      // Deactivate a contract in registry
      await mockRegistry.updateContractStatus(TIER_MANAGER_NAME, false, 1);

      // Update contract references should handle inactive contracts
      await crowdSale.connect(admin).updateContractReferences();

      // The contract should still have the address but may behave differently
      // depending on implementation
    });
  });

  describe("Event Emissions", function () {
    it("should emit events for configuration changes", async function () {
      const newMax = ethers.parseUnits("2000000", 6);

      // Test max tokens per address update event
      await expect(
          crowdSale.connect(admin).setMaxTokensPerAddress(newMax)
      ).to.emit(crowdSale, "MaxTokensPerAddressUpdated")
          .withArgs(newMax);
    });

    it("should emit events for presale time updates", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      const startTime = currentTime + 1000;
      const endTime = startTime + 2000;

      await expect(
          crowdSale.connect(admin).setPresaleTimes(startTime, endTime)
      ).to.emit(crowdSale, "PresaleTimesUpdated")
          .withArgs(startTime, endTime);
    });
  });

  describe("Access Control", function () {
    it("should properly manage admin roles", async function () {
      // Grant admin role to user3
      await crowdSale.grantRole(ADMIN_ROLE, await user3.getAddress());
      expect(await crowdSale.hasRole(ADMIN_ROLE, await user3.getAddress())).to.be.true;

      // User3 should now be able to perform admin functions
      const newMax = ethers.parseUnits("3000000", 6);
      await crowdSale.connect(user3).setMaxTokensPerAddress(newMax);
      expect(await crowdSale.maxTokensPerAddress()).to.equal(newMax);

      // Revoke admin role from user3
      await crowdSale.revokeRole(ADMIN_ROLE, await user3.getAddress());
      expect(await crowdSale.hasRole(ADMIN_ROLE, await user3.getAddress())).to.be.false;
    });

    it("should properly manage emergency roles", async function () {
      // Grant emergency role to user2
      await crowdSale.grantRole(EMERGENCY_ROLE, await user2.getAddress());
      expect(await crowdSale.hasRole(EMERGENCY_ROLE, await user2.getAddress())).to.be.true;

      // Revoke emergency role
      await crowdSale.revokeRole(EMERGENCY_ROLE, await user2.getAddress());
      expect(await crowdSale.hasRole(EMERGENCY_ROLE, await user2.getAddress())).to.be.false;
    });
  });
});