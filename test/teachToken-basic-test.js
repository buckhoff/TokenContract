const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TeachToken - Part 1: Basic Functionality", function () {
  let teachToken;
  let mockImmutableContract;
  let owner, admin, minter, burner, treasury, user1, user2;
  
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  
  beforeEach(async function () {
    // Get signers
    [owner, admin, minter, burner, treasury, user1, user2] = await ethers.getSigners();
    
    // Deploy mock immutable contract
    const MockImmutableTokenContract = await ethers.getContractFactory("MockImmutableTokenContract");
    mockImmutableContract = await MockImmutableTokenContract.deploy();
    
    // Deploy TeachToken
    const TeachToken = await ethers.getContractFactory("TeachToken");
    teachToken = await upgrades.deployProxy(TeachToken, [mockImmutableContract.address], {
      initializer: "initialize",
    });
    
    // Set up roles
    await teachToken.grantRole(ADMIN_ROLE, admin.address);
    await teachToken.grantRole(MINTER_ROLE, minter.address);
    await teachToken.grantRole(BURNER_ROLE, burner.address);
  });

  describe("Initialization", function () {
    it("should set the name and symbol from the immutable contract", async function () {
      expect(await teachToken.name()).to.equal("TeacherSupport Token");
      expect(await teachToken.symbol()).to.equal("TEACH");
    });
    
    it("should set the correct roles", async function () {
      expect(await teachToken.hasRole(await teachToken.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
      expect(await teachToken.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await teachToken.hasRole(MINTER_ROLE, minter.address)).to.be.true;
      expect(await teachToken.hasRole(BURNER_ROLE, burner.address)).to.be.true;
    });
    
    it("should not have completed initial distribution", async function () {
      expect(await teachToken.isInitialDistributionComplete()).to.be.false;
    });
  });

  describe("Initial Token Distribution", function () {
    it("should allow admin to perform initial distribution", async function () {
      // Set up addresses for distribution
      const platformEcosystem = treasury.address;
      const communityIncentives = user1.address;
      const initialLiquidity = user2.address;
      const publicPresale = owner.address;
      const teamAndDev = admin.address;
      const educationalPartners = minter.address;
      const reserve = burner.address;
      
      // Perform the initial distribution
      await teachToken.performInitialDistribution(
        platformEcosystem,
        communityIncentives,
        initialLiquidity,
        publicPresale,
        teamAndDev,
        educationalPartners,
        reserve
      );
      
      // Verify distribution is marked as complete
      expect(await teachToken.isInitialDistributionComplete()).to.be.true;
      
      // Verify token allocations
      const presaleAllocation = await mockImmutableContract.calculateAllocation(
        await mockImmutableContract.PUBLIC_PRESALE_ALLOCATION_BPS()
      );
      expect(await teachToken.balanceOf(publicPresale)).to.equal(presaleAllocation);
      
      const communityAllocation = await mockImmutableContract.calculateAllocation(
        await mockImmutableContract.COMMUNITY_INCENTIVES_ALLOCATION_BPS()
      );
      expect(await teachToken.balanceOf(communityIncentives)).to.equal(communityAllocation);
      
      // Verify total supply
      const totalSupply = await teachToken.totalSupply();
      expect(totalSupply).to.equal(await mockImmutableContract.MAX_SUPPLY());
    });
    
    it("should prevent initial distribution with zero addresses", async function () {
      // Set up addresses for distribution with one zero address
      const platformEcosystem = treasury.address;
      const communityIncentives = user1.address;
      const initialLiquidity = user2.address;
      const publicPresale = owner.address;
      const teamAndDev = ethers.constants.AddressZero; // Zero address
      const educationalPartners = minter.address;
      const reserve = burner.address;
      
      // Attempt to perform the initial distribution
      await expect(
        teachToken.performInitialDistribution(
          platformEcosystem,
          communityIncentives,
          initialLiquidity,
          publicPresale,
          teamAndDev,
          educationalPartners,
          reserve
        )
      ).to.be.revertedWith("Zero address for teamAndDev");
    });
    
    it("should prevent duplicate addresses in distribution", async function () {
      // Set up addresses for distribution with duplicates
      const platformEcosystem = treasury.address;
      const communityIncentives = user1.address;
      const initialLiquidity = user1.address; // Duplicate
      const publicPresale = owner.address;
      const teamAndDev = admin.address;
      const educationalPartners = minter.address;
      const reserve = burner.address;
      
      // Attempt to perform the initial distribution
      await expect(
        teachToken.performInitialDistribution(
          platformEcosystem,
          communityIncentives,
          initialLiquidity,
          publicPresale,
          teamAndDev,
          educationalPartners,
          reserve
        )
      ).to.be.revertedWith("Duplicate addresses not allowed");
    });
    
    it("should prevent distribution to be performed twice", async function () {
      // Set up addresses for distribution
      const platformEcosystem = treasury.address;
      const communityIncentives = user1.address;
      const initialLiquidity = user2.address;
      const publicPresale = owner.address;
      const teamAndDev = admin.address;
      const educationalPartners = minter.address;
      const reserve = burner.address;
      
      // Perform the initial distribution
      await teachToken.performInitialDistribution(
        platformEcosystem,
        communityIncentives,
        initialLiquidity,
        publicPresale,
        teamAndDev,
        educationalPartners,
        reserve
      );
      
      // Attempt to perform the distribution again
      await expect(
        teachToken.performInitialDistribution(
          platformEcosystem,
          communityIncentives,
          initialLiquidity,
          publicPresale,
          teamAndDev,
          educationalPartners,
          reserve
        )
      ).to.be.revertedWith("Initial distribution already completed");
    });
  });

  describe("Token Transfers", function () {
    beforeEach(async function () {
      // Perform initial distribution to have tokens for testing
      await teachToken.performInitialDistribution(
        treasury.address,
        user1.address,
        user2.address,
        owner.address,
        admin.address,
        minter.address,
        burner.address
      );
    });
    
    it("should allow token transfers between users", async function () {
      const transferAmount = ethers.parseEther("1000");
      
      // Get initial balances
      const initialOwnerBalance = await teachToken.balanceOf(owner.address);
      const initialUser1Balance = await teachToken.balanceOf(user1.address);
      
      // Perform transfer
      await teachToken.transfer(user1.address, transferAmount);
      
      // Check balances after transfer
      expect(await teachToken.balanceOf(owner.address)).to.equal(initialOwnerBalance.sub(transferAmount));
      expect(await teachToken.balanceOf(user1.address)).to.equal(initialUser1Balance.add(transferAmount));
    });
    
    it("should allow token transfers with allowance", async function () {
      const approveAmount = ethers.parseEther("2000");
      const transferAmount = ethers.parseEther("1000");
      
      // Get initial balances
      const initialOwnerBalance = await teachToken.balanceOf(owner.address);
      const initialUser1Balance = await teachToken.balanceOf(user1.address);
      
      // Approve user1 to spend owner's tokens
      await teachToken.approve(user1.address, approveAmount);
      
      // User1 transfers tokens from owner to themselves
      await teachToken.connect(user1).transferFrom(owner.address, user1.address, transferAmount);
      
      // Check balances after transfer
      expect(await teachToken.balanceOf(owner.address)).to.equal(initialOwnerBalance.sub(transferAmount));
      expect(await teachToken.balanceOf(user1.address)).to.equal(initialUser1Balance.add(transferAmount));
      
      // Check remaining allowance
      expect(await teachToken.allowance(owner.address, user1.address)).to.equal(approveAmount.sub(transferAmount));
    });
    
    it("should prevent transfers when paused", async function () {
      // Pause the token
      await teachToken.pause();
      
      // Attempt to transfer
      await expect(
        teachToken.transfer(user1.address, ethers.parseEther("1000"))
      ).to.be.revertedWith("TeachToken: Paused");
    });
  });
});
