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
  
  let owner, admin, treasury, user1, user2;
  
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
  const RECORDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RECORDER_ROLE"));
  
  const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
  
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
    
    // Set up roles
    await crowdSale.grantRole(ADMIN_ROLE, admin.address);
    await crowdSale.grantRole(EMERGENCY_ROLE, admin.address);
    await crowdSale.grantRole(RECORDER_ROLE, admin.address);
    
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
    
    // Send token to the crowdsale for vesting
    await token.transfer(mockTokenVesting.address, ethers.parseEther("1000000000"));
    
    // Transfer stablecoin to users for purchases
    await stablecoin.transfer(user1.address, ethers.parseEther("100000"));
    await stablecoin.transfer(user2.address, ethers.parseEther("100000"));
  });

  describe("Initialization and Setup", function () {
    it("should initialize with the correct treasury address", async function () {
      expect(await crowdSale.treasury()).to.equal(treasury.address);
    });
    
    it("should set the correct roles", async function () {
      expect(await crowdSale.hasRole(await crowdSale.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
      expect(await crowdSale.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await crowdSale.hasRole(EMERGENCY_ROLE, admin.address)).to.be.true;
      expect(await crowdSale.hasRole(RECORDER_ROLE, admin.address)).to.be.true;
    });
    
    it("should set the token address", async function () {
      expect(await crowdSale.token()).to.equal(token.address);
    });
    
    it("should prevent setting token address twice", async function () {
      await expect(
        crowdSale.setSaleToken(stablecoin.address)
      ).to.be.revertedWith("TokenAlreadySet");
    });
    
    it("should properly set the tier manager", async function () {
      expect(await crowdSale.tierManager()).to.equal(mockTierManager.address);
    });
    
    it("should properly set the vesting contract", async function () {
      expect(await crowdSale.vestingContract()).to.equal(mockTokenVesting.address);
    });
    
    it("should properly set the emergency manager", async function () {
      expect(await crowdSale.emergencyManager()).to.equal(mockEmergencyManager.address);
    });
    
    it("should properly set the price feed", async function () {
      expect(await crowdSale.priceFeed()).to.equal(mockPriceFeed.address);
    });
    
    it("should set presale times correctly", async function () {
      const startTime = await crowdSale.presaleStart();
      const endTime = await crowdSale.presaleEnd();
      
      expect(endTime).to.be.gt(startTime);
      expect(endTime.sub(startTime)).to.be.closeTo(
        ethers.BigNumber.from(30 * 24 * 60 * 60), // 30 days
        60 // Allow 1 minute variance for test execution time
      );
    });
  });

  describe("Component Validation", function () {
    it("should revert when setting zero address components", async function () {
      await expect(
        crowdSale.connect(admin).setTierManager(ethers.constants.AddressZero)
      ).to.be.revertedWith("ZeroComponentAddress");
      
      await expect(
        crowdSale.connect(admin).setVestingContract(ethers.constants.AddressZero)
      ).to.be.revertedWith("ZeroComponentAddress");
      
      await expect(
        crowdSale.connect(admin).setEmergencyManager(ethers.constants.AddressZero)
      ).to.be.revertedWith("ZeroComponentAddress");
      
      await expect(
        crowdSale.connect(admin).setPriceFeed(ethers.constants.AddressZero)
      ).to.be.revertedWith("ZeroComponentAddress");
    });
    
    it("should revert when setting invalid presale times", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      
      // End time before start time
      await expect(
        crowdSale.connect(admin).setPresaleTimes(currentTime + 1000, currentTime + 500)
      ).to.be.revertedWith("InvalidPresaleTimes");
    });
    
    it("should only allow admins to set components", async function () {
      const MockTierManager = await ethers.getContractFactory("MockTierManager");
      const newMockTierManager = await MockTierManager.deploy();
      
      // Attempt to set component as non-admin
      await expect(
        crowdSale.connect(user1).setTierManager(newMockTierManager.address)
      ).to.be.reverted; // Will revert due to role check
      
      // Set component as admin
      await crowdSale.connect(admin).setTierManager(newMockTierManager.address);
      expect(await crowdSale.tierManager()).to.equal(newMockTierManager.address);
    });
  });

  describe("Purchase Limits", function () {
    it("should have default purchase limits", async function () {
      // Check default max tokens per address
      expect(await crowdSale.maxTokensPerAddress()).to.equal(ethers.BigNumber.from("1500000000000"));
      
      // Check purchase rate limits
      expect(await crowdSale.minTimeBetweenPurchases()).to.equal(60 * 60); // 1 hour
      
      // Default max purchase amount in USD
      expect(await crowdSale.maxPurchaseAmount()).to.equal(ethers.BigNumber.from("50000000000")); // $50,000
    });
    
    it("should allow admin to update max tokens per address", async function () {
      const newMax = ethers.BigNumber.from("2000000000000");
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
      await ethers.provider.send("evm_setNextBlockTimestamp", [endTime.add(1).toNumber()]);
      await ethers.provider.send("evm_mine");
      
      // Complete TGE
      await crowdSale.completeTGE();
      expect(await crowdSale.tgeCompleted()).to.be.true;
    });
  });
});
