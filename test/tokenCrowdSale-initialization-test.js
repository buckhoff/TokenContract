const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Initialization and Configuration", function () {
  let crowdSale;
  let token;
  let stablecoin;
  let mockRegistry;
  let mockTierManager;
  let mockTokenVesting;
  let mockEmergencyManager;
  let mockPriceFeed;

  let owner, admin, minter, burner, treasury, emergency, user3, user2, user1;

  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
  const RECORDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RECORDER_ROLE"));

  const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
  const TIER_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER"));
  const TOKEN_VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));
  const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));
  const PRICE_FEED_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_PRICE_FEED"));

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

    // Set up roles
    await crowdSale.grantRole(ADMIN_ROLE, await admin.getAddress());
    await crowdSale.grantRole(EMERGENCY_ROLE, await emergency.getAddress());
    await crowdSale.grantRole(RECORDER_ROLE, await admin.getAddress());

    // Register all contracts in the registry
    await mockRegistry.setContractAddress(TOKEN_NAME, await token.getAddress(), true);
    await mockRegistry.setContractAddress(TIER_MANAGER_NAME, await mockTierManager.getAddress(), true);
    await mockRegistry.setContractAddress(TOKEN_VESTING_NAME, await mockTokenVesting.getAddress(), true);
    await mockRegistry.setContractAddress(EMERGENCY_MANAGER_NAME, await mockEmergencyManager.getAddress(), true);
    await mockRegistry.setContractAddress(PRICE_FEED_NAME, await mockPriceFeed.getAddress(), true);

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

    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(await user1.getAddress(), ethers.parseUnits("100000", 6));
    await stablecoin.transfer(await user2.getAddress(), ethers.parseUnits("100000", 6));
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

    it("should set the token address", async function () {
      expect(await crowdSale.token()).to.equal(await token.getAddress());
    });

    it("should prevent setting token address twice", async function () {
      await expect(
          crowdSale.setSaleToken(await stablecoin.getAddress())
      ).to.be.revertedWithCustomError(crowdSale, "TokenAlreadySet");
    });

    it("should properly set the tier manager", async function () {
      expect(await crowdSale.tierManager()).to.equal(await mockTierManager.getAddress());
    });

    it("should properly set the vesting contract", async function () {
      expect(await crowdSale.vestingContract()).to.equal(await mockTokenVesting.getAddress());
    });

    it("should properly set the emergency manager", async function () {
      expect(await crowdSale.emergencyManager()).to.equal(await mockEmergencyManager.getAddress());
    });

    it("should properly set the price feed", async function () {
      expect(await crowdSale.priceFeed()).to.equal(await mockPriceFeed.getAddress());
    });

    it("should set presale times correctly", async function () {
      const startTime = await crowdSale.presaleStart();
      const endTime = await crowdSale.presaleEnd();

      expect(endTime).to.be.gt(startTime);
      expect(endTime - startTime).to.be.closeTo(
          BigInt(30 * 24 * 60 * 60), // 30 days
          BigInt(60) // Allow 1 minute variance for test execution time
      );
    });
  });

  describe("Component Validation", function () {
    it("should revert when setting zero address components", async function () {
      await expect(
          crowdSale.connect(admin).setTierManager(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(crowdSale, "ZeroComponentAddress");

      await expect(
          crowdSale.connect(admin).setVestingContract(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(crowdSale, "ZeroComponentAddress");

      await expect(
          crowdSale.connect(admin).setEmergencyManager(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(crowdSale, "ZeroComponentAddress");

      await expect(
          crowdSale.connect(admin).setPriceFeed(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(crowdSale, "ZeroComponentAddress");
    });

    it("should revert when setting invalid presale times", async function () {
      const currentTime = Math.floor(Date.now() / 1000);

      // End time before start time
      await expect(
          crowdSale.connect(admin).setPresaleTimes(currentTime + 1000, currentTime + 500)
      ).to.be.revertedWithCustomError(crowdSale, "InvalidPresaleTimes");
    });

    it("should only allow admins to set components", async function () {
      const MockTierManager = await ethers.getContractFactory("MockTierManager");
      const newMockTierManager = await MockTierManager.deploy();
      await newMockTierManager.waitForDeployment();

      // Attempt to set component as non-admin
      await expect(
          crowdSale.connect(user1).setTierManager(await newMockTierManager.getAddress())
      ).to.be.reverted; // Will revert due to role check

      // Set component as admin
      await crowdSale.connect(admin).setTierManager(await newMockTierManager.getAddress());
      expect(await crowdSale.tierManager()).to.equal(await newMockTierManager.getAddress());
    });
  });

  describe("Purchase Limits Configuration", function () {
    it("should have default purchase limits", async function () {
      // Check default max tokens per address (1.5M tokens with 6 decimals)
      expect(await crowdSale.maxTokensPerAddress()).to.equal(ethers.parseUnits("1500000", 6));

      // Check purchase rate limits
      expect(await crowdSale.minTimeBetweenPurchases()).to.equal(60 * 60); // 1 hour

      // Default max purchase amount in USD (6 decimals)
      expect(await crowdSale.maxPurchaseAmount()).to.equal(ethers.parseUnits("50000", 6)); // $50,000
    });

    it("should allow admin to update max tokens per address", async function () {
      const newMax = ethers.parseUnits("2000000", 6);
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

    it("should not allow completing TGE twice", async function () {
      // Fast forward time to after presale end
      const endTime = await crowdSale.presaleEnd();
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(endTime) + 3600]);
      await ethers.provider.send("evm_mine");

      // Complete TGE first time
      await crowdSale.completeTGE();

      // Attempt to complete TGE again
      await expect(
          crowdSale.completeTGE()
      ).to.be.revertedWith("TGE already completed");
    });
  });

  describe("Registry Integration", function () {
    it("should update contract references from registry", async function () {
      // Deploy a new token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20.deploy("New Token", "NTK", ethers.parseUnits("1000000", 18));
      await newToken.waitForDeployment();

      // Update registry
      await mockRegistry.setContractAddress(TOKEN_NAME, await newToken.getAddress(), true);

      // Update contract references
      await crowdSale.updateContractReferences();

      // Verify token address updated
      expect(await crowdSale.token()).to.equal(await newToken.getAddress());
    });

    it("should handle registry offline mode gracefully", async function () {
      // Set registry to inactive
      await mockRegistry.setContractAddress(TOKEN_NAME, await token.getAddress(), false);

      // Update contract references should not fail
      await expect(crowdSale.updateContractReferences()).to.not.be.reverted;
    });
  });

  describe("Auto-compound Feature Configuration", function () {
    it("should allow users to toggle auto-compound setting", async function () {
      // Default should be off
      expect(await crowdSale.autoCompoundEnabled(await user1.getAddress())).to.be.false;

      // Toggle on
      await crowdSale.connect(user1).setAutoCompound(true);
      expect(await crowdSale.autoCompoundEnabled(await user1.getAddress())).to.be.true;

      // Toggle off
      await crowdSale.connect(user1).setAutoCompound(false);
      expect(await crowdSale.autoCompoundEnabled(await user1.getAddress())).to.be.false;
    });

    it("should emit events when auto-compound is toggled", async function () {
      await expect(crowdSale.connect(user1).setAutoCompound(true))
          .to.emit(crowdSale, "AutoCompoundUpdated")
          .withArgs(await user1.getAddress(), true);

      await expect(crowdSale.connect(user1).setAutoCompound(false))
          .to.emit(crowdSale, "AutoCompoundUpdated")
          .withArgs(await user1.getAddress(), false);
    });
  });

  describe("Component Events", function () {
    it("should emit events when components are set", async function () {
      const MockTierManager = await ethers.getContractFactory("MockTierManager");
      const newTierManager = await MockTierManager.deploy();
      await newTierManager.waitForDeployment();

      await expect(crowdSale.connect(admin).setTierManager(await newTierManager.getAddress()))
          .to.emit(crowdSale, "ComponentSet")
          .withArgs("TierManager", await newTierManager.getAddress());
    });

    it("should emit events when registry is set", async function () {
      const MockRegistry = await ethers.getContractFactory("MockRegistry");
      const newRegistry = await MockRegistry.deploy();
      await newRegistry.waitForDeployment();

      await expect(crowdSale.connect(owner).setRegistry(await newRegistry.getAddress()))
          .to.emit(crowdSale, "RegistrySet")
          .withArgs(await newRegistry.getAddress());
    });
  });
});