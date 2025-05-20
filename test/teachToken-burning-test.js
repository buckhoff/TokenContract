const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TeachToken - Part 2: Burning Functionality", function () {
  let teachToken;
  let mockImmutableContract;
  let mockRegistry;
  let mockStabilityFund;
  let owner, admin, minter, burner, treasury, user1, user2;
  
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  
  // For mock registry
  const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
  const STABILITY_FUND_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_STABILITY_FUND"));
  
  beforeEach(async function () {
    // Get signers
    [owner, admin, minter, burner, treasury, user1, user2] = await ethers.getSigners();
    
    // Deploy mock immutable contract
    const MockImmutableTokenContract = await ethers.getContractFactory("MockImmutableTokenContract");
    mockImmutableContract = await MockImmutableTokenContract.deploy();
    
    // Deploy mock registry and stability fund
    const MockRegistry = await ethers.getContractFactory("MockRegistry");
    mockRegistry = await MockRegistry.deploy();
    
    const MockStabilityFund = await ethers.getContractFactory("MockStabilityFund");
    mockStabilityFund = await MockStabilityFund.deploy();
    
    // Configure mock registry
    await mockRegistry.setContractAddress(TOKEN_NAME, true, 1);
    await mockRegistry.setContractAddress(STABILITY_FUND_NAME, mockStabilityFund.address, true);
    
    // Deploy TeachToken
    const TeachToken = await ethers.getContractFactory("TeachToken");
    teachToken = await upgrades.deployProxy(TeachToken, [mockImmutableContract.address], {
      initializer: "initialize",
    });
    
    // Set up roles
    await teachToken.grantRole(ADMIN_ROLE, admin.address);
    await teachToken.grantRole(MINTER_ROLE, minter.address);
    await teachToken.grantRole(BURNER_ROLE, burner.address);
    
    // Set registry and perform initial distribution
    await teachToken.setRegistry(mockRegistry.address);
    
    // Perform initial distribution
    await teachToken.performInitialDistribution(
      treasury.address, // platformEcosystem
      user1.address,    // communityIncentives
      user2.address,    // initialLiquidity
      owner.address,    // publicPresale
      admin.address,    // teamAndDev
      minter.address,   // educationalPartners
      burner.address    // reserve
    );
  });

  describe("Burning Tokens", function () {
    it("should allow users to burn their own tokens", async function () {
      const burnAmount = ethers.parseEther("1000");
      
      // Get initial balance and supply
      const initialBalance = await teachToken.balanceOf(owner.address);
      const initialSupply = await teachToken.totalSupply();
      
      // Burn tokens
      await teachToken.burn(burnAmount);
      
      // Check balance and supply after burn
      expect(await teachToken.balanceOf(owner.address)).to.equal(initialBalance.sub(burnAmount));
      expect(await teachToken.totalSupply()).to.equal(initialSupply.sub(burnAmount));
    });
    
    it("should allow authorized burners to burn tokens from others", async function () {
      const burnAmount = ethers.parseEther("1000");
      
      // Get initial balance and supply
      const initialBalance = await teachToken.balanceOf(owner.address);
      const initialSupply = await teachToken.totalSupply();
      
      // Approve burner to spend tokens
      await teachToken.approve(burner.address, burnAmount);
      
      // Burner burns tokens from owner
      await teachToken.connect(burner).burnFrom(owner.address, burnAmount);
      
      // Check balance and supply after burn
      expect(await teachToken.balanceOf(owner.address)).to.equal(initialBalance.sub(burnAmount));
      expect(await teachToken.totalSupply()).to.equal(initialSupply.sub(burnAmount));
    });
    
    it("should notify stability fund when tokens are burned", async function () {
      const burnAmount = ethers.parseEther("1000");
      
      // Burn tokens
      await teachToken.burn(burnAmount);
      
      // Check if the stability fund was notified
      expect(await mockStabilityFund.lastBurnAmount()).to.equal(burnAmount);
      expect(await mockStabilityFund.burnNotificationCount()).to.equal(1);
    });
    
    it("should not allow unauthorized accounts to burn tokens from others", async function () {
      const burnAmount = ethers.parseEther("1000");
      
      // Approve user1 to spend tokens (not a burner)
      await teachToken.approve(user1.address, burnAmount);
      
      // Attempt to burn tokens from owner
      await expect(
        teachToken.connect(user1).burnFrom(owner.address, burnAmount)
      ).to.be.reverted; // Will revert due to role check
    });
    
    it("should prevent burning when the contract is paused", async function () {
      // Pause the token contract
      await teachToken.pause();
      
      // Attempt to burn tokens
      await expect(
        teachToken.burn(ethers.parseEther("1000"))
      ).to.be.revertedWith("TeachToken: Paused");
    });
  });

  describe("Burner Role Management", function () {
    it("should allow adding burners", async function () {
      // Add user1 as a burner
      await teachToken.addBurner(user1.address);
      
      // Check if user1 has the burner role
      expect(await teachToken.hasRole(BURNER_ROLE, user1.address)).to.be.true;
    });
    
    it("should allow removing burners", async function () {
      // First add user1 as a burner
      await teachToken.addBurner(user1.address);
      expect(await teachToken.hasRole(BURNER_ROLE, user1.address)).to.be.true;
      
      // Then remove user1 as a burner
      await teachToken.removeBurner(user1.address);
      
      // Check if user1 no longer has the burner role
      expect(await teachToken.hasRole(BURNER_ROLE, user1.address)).to.be.false;
    });
    
    it("should not allow non-admins to add burners", async function () {
      // Attempt to add user2 as a burner from user1 (non-admin)
      await expect(
        teachToken.connect(user1).addBurner(user2.address)
      ).to.be.reverted; // Will revert due to role check
    });
  });
});
