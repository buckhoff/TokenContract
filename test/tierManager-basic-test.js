const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TierManager - Part 1: Basic Configuration and Tier Management", function () {
    let tierManager;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const TIER_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    // Registry contract names
    const TIER_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER"));
    const CROWDSALE_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_CROWDSALE"));

    beforeEach(async function () {
        // Get signers
        [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

        // Deploy mock registry
        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();

        // Deploy TierManager
        const TierManager = await ethers.getContractFactory("TierManager");
        tierManager = await upgrades.deployProxy(TierManager, [], {
            initializer: "initialize",
        });

        // Set up roles
        await tierManager.grantRole(ADMIN_ROLE, admin.address);
        await tierManager.grantRole(TIER_MANAGER_ROLE, admin.address);
        await tierManager.grantRole(EMERGENCY_ROLE, emergency.address);

        // Set registry
        await tierManager.setRegistry(await mockRegistry.getAddress(), TIER_MANAGER_NAME);

        // Register tier manager and crowdsale in mock registry
        await mockRegistry.setContractAddress(TIER_MANAGER_NAME, await tierManager.getAddress(), true);
        await mockRegistry.setContractAddress(CROWDSALE_NAME, owner.address, true); // Use owner as mock crowdsale
    });

    describe("Initialization", function () {
        it("should initialize with correct default values", async function () {
            expect(await tierManager.hasRole(await tierManager.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await tierManager.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await tierManager.hasRole(TIER_MANAGER_ROLE, admin.address)).to.be.true;
            expect(await tierManager.hasRole(EMERGENCY_ROLE, emergency.address)).to.be.true;
        });

        it("should have default tier configuration", async function () {
            // Check if default tiers exist (assuming TierManager has default tiers)
            const tier0 = await tierManager.getTierDetails(0);
            expect(tier0.isActive).to.be.true;
            expect(tier0.price).to.be.gt(0);
            expect(tier0.allocation).to.be.gt(0);

            const tier1 = await tierManager.getTierDetails(1);
            expect(tier1.isActive).to.be.true;
            expect(tier1.price).to.be.gt(tier0.price); // Higher tier should have higher price
        });

        it("should set registry correctly", async function () {
            expect(await tierManager.registry()).to.equal(await mockRegistry.getAddress());
            expect(await tierManager.contractName()).to.equal(TIER_MANAGER_NAME);
        });
    });

    describe("Tier Configuration", function () {
        it("should allow admin to create new tier", async function () {
            const tierId = 5;
            const tierConfig = {
                price: ethers.parseUnits("0.08", 6), // $0.08 per token
                allocation: ethers.parseEther("100000000"), // 100M tokens
                minPurchase: ethers.parseUnits("50", 6), // $50 minimum
                maxPurchase: ethers.parseUnits("25000", 6), // $25,000 maximum
                vestingTGE: 15, // 15% at TGE
                vestingMonths: 8, // 8 months vesting
                isActive: true
            };

            await tierManager.connect(admin).createTier(
                tierId,
                tierConfig.price,
                tierConfig.allocation,
                tierConfig.minPurchase,
                tierConfig.maxPurchase,
                tierConfig.vestingTGE,
                tierConfig.vestingMonths,
                tierConfig.isActive
            );

            const createdTier = await tierManager.getTierDetails(tierId);
            expect(createdTier.price).to.equal(tierConfig.price);
            expect(createdTier.allocation).to.equal(tierConfig.allocation);
            expect(createdTier.minPurchase).to.equal(tierConfig.minPurchase);
            expect(createdTier.maxPurchase).to.equal(tierConfig.maxPurchase);
            expect(createdTier.vestingTGE).to.equal(tierConfig.vestingTGE);
            expect(createdTier.vestingMonths).to.equal(tierConfig.vestingMonths);
            expect(createdTier.isActive).to.equal(tierConfig.isActive);
            expect(createdTier.sold).to.equal(0);
        });

        it("should prevent creating tier with invalid parameters", async function () {
            const tierId = 6;

            // Price too low
            await expect(
                tierManager.connect(admin).createTier(
                    tierId,
                    0, // Invalid price
                    ethers.parseEther("100000000"),
                    ethers.parseUnits("50", 6),
                    ethers.parseUnits("25000", 6),
                    15,
                    8,
                    true
                )
            ).to.be.revertedWith("Invalid price");

            // Zero allocation
            await expect(
                tierManager.connect(admin).createTier(
                    tierId,
                    ethers.parseUnits("0.08", 6),
                    0, // Invalid allocation
                    ethers.parseUnits("50", 6),
                    ethers.parseUnits("25000", 6),
                    15,
                    8,
                    true
                )
            ).to.be.revertedWith("Invalid allocation");

            // Min purchase greater than max purchase
            await expect(
                tierManager.connect(admin).createTier(
                    tierId,
                    ethers.parseUnits("0.08", 6),
                    ethers.parseEther("100000000"),
                    ethers.parseUnits("30000", 6), // Higher than max
                    ethers.parseUnits("25000", 6),
                    15,
                    8,
                    true
                )
            ).to.be.revertedWith("Min purchase exceeds max purchase");

            // Invalid TGE percentage
            await expect(
                tierManager.connect(admin).createTier(
                    tierId,
                    ethers.parseUnits("0.08", 6),
                    ethers.parseEther("100000000"),
                    ethers.parseUnits("50", 6),
                    ethers.parseUnits("25000", 6),
                    101, // Invalid TGE percentage
                    8,
                    true
                )
            ).to.be.revertedWith("Invalid TGE percentage");
        });

        it("should allow admin to update tier configuration", async function () {
            const tierId = 0;
            const newPrice = ethers.parseUnits("0.05", 6);
            const newAllocation = ethers.parseEther("200000000");

            await tierManager.connect(admin).updateTierPrice(tierId, newPrice);
            await tierManager.connect(admin).updateTierAllocation(tierId, newAllocation);

            const updatedTier = await tierManager.getTierDetails(tierId);
            expect(updatedTier.price).to.equal(newPrice);
            expect(updatedTier.allocation).to.equal(newAllocation);
        });

        it("should allow admin to activate/deactivate tiers", async function () {
            const tierId = 0;

            // Deactivate tier
            await tierManager.connect(admin).setTierActive(tierId, false);
            expect(await tierManager.isTierActive(tierId)).to.be.false;

            // Reactivate tier
            await tierManager.connect(admin).setTierActive(tierId, true);
            expect(await tierManager.isTierActive(tierId)).to.be.true;
        });

        it("should not allow non-admin to modify tiers", async function () {
            const tierId = 0;
            const newPrice = ethers.parseUnits("0.05", 6);

            await expect(
                tierManager.connect(user1).updateTierPrice(tierId, newPrice)
            ).to.be.reverted; // Will revert due to role check

            await expect(
                tierManager.connect(user1).setTierActive(tierId, false)
            ).to.be.reverted; // Will revert due to role check
        });
    });

    describe("Tier Information Queries", function () {
        it("should return correct tier details", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);

            expect(tier.price).to.be.gt(0);
            expect(tier.allocation).to.be.gt(0);
            expect(tier.sold).to.be.gte(0);
            expect(tier.minPurchase).to.be.gt(0);
            expect(tier.maxPurchase).to.be.gt(tier.minPurchase);
            expect(tier.vestingTGE).to.be.lte(100);
            expect(tier.vestingMonths).to.be.gt(0);
        });

        it("should return correct remaining tokens in tier", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);
            const remaining = await tierManager.tokensRemainingInTier(tierId);

            expect(remaining).to.equal(tier.allocation - tier.sold);
        });

        it("should return correct tier price", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);
            const price = await tierManager.getTierPrice(tierId);

            expect(price).to.equal(tier.price);
        });

        it("should return correct vesting parameters", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);
            const [tgePercent, vestingMonths] = await tierManager.getTierVestingParams(tierId);

            expect(tgePercent).to.equal(tier.vestingTGE);
            expect(vestingMonths).to.equal(tier.vestingMonths);
        });

        it("should return correct tier active status", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);
            const isActive = await tierManager.isTierActive(tierId);

            expect(isActive).to.equal(tier.isActive);
        });
    });

    describe("Total Sales Tracking", function () {
        it("should return correct total tokens sold", async function () {
            const totalSold = await tierManager.totalTokensSold();
            expect(totalSold).to.be.gte(0);
        });

        it("should track sales correctly when tokens are sold", async function () {
            // This test assumes there's a way to record sales
            // In the actual implementation, this would be called by the crowdsale contract
            const tierId = 0;
            const tokenAmount = ethers.parseEther("1000");

            const initialSold = await tierManager.totalTokensSold();
            const initialTierSold = (await tierManager.getTierDetails(tierId)).sold;

            // Only the crowdsale contract should be able to record purchases
            // For testing, we'll grant the owner the crowdsale role temporarily
            await mockRegistry.setContractAddress(CROWDSALE_NAME, owner.address, true);

            // Record a purchase (this would normally be called by crowdsale)
            await tierManager.recordPurchase(tierId, tokenAmount);

            const finalSold = await tierManager.totalTokensSold();
            const finalTierSold = (await tierManager.getTierDetails(tierId)).sold;

            expect(finalSold).to.equal(initialSold + tokenAmount);
            expect(finalTierSold).to.equal(initialTierSold + tokenAmount);
        });
    });

    describe("Access Control", function () {
        it("should prevent unauthorized tier creation", async function () {
            await expect(
                tierManager.connect(user1).createTier(
                    10,
                    ethers.parseUnits("0.1", 6),
                    ethers.parseEther("50000000"),
                    ethers.parseUnits("100", 6),
                    ethers.parseUnits("10000", 6),
                    20,
                    6,
                    true
                )
            ).to.be.reverted; // Will revert due to role check
        });

        it("should prevent unauthorized tier updates", async function () {
            await expect(
                tierManager.connect(user2).updateTierPrice(0, ethers.parseUnits("0.1", 6))
            ).to.be.reverted; // Will revert due to role check

            await expect(
                tierManager.connect(user2).updateTierAllocation(0, ethers.parseEther("300000000"))
            ).to.be.reverted; // Will revert due to role check
        });

        it("should allow only authorized roles to record purchases", async function () {
            // Non-crowdsale contract should not be able to record purchases
            await expect(
                tierManager.connect(user1).recordPurchase(0, ethers.parseEther("1000"))
            ).to.be.reverted;
        });
    });

    describe("Edge Cases", function () {
        it("should handle queries for non-existent tiers", async function () {
            const nonExistentTier = 99;

            // Should return default/empty tier data
            const tier = await tierManager.getTierDetails(nonExistentTier);
            expect(tier.price).to.equal(0);
            expect(tier.allocation).to.equal(0);
            expect(tier.isActive).to.be.false;
        });

        it("should handle tier sold out scenario", async function () {
            const tierId = 0;
            const tier = await tierManager.getTierDetails(tierId);

            // Record sales equal to the full allocation
            await mockRegistry.setContractAddress(CROWDSALE_NAME, owner.address, true);
            await tierManager.recordPurchase(tierId, tier.allocation);

            // Check that no tokens remain
            expect(await tierManager.tokensRemainingInTier(tierId)).to.equal(0);
        });
    });
});