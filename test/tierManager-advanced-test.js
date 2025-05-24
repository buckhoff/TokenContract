const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TierManager - Part 3: Advanced Features and Emergency Functions", function () {
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
        await mockRegistry.setContractAddress(CROWDSALE_NAME, owner.address, true);
    });

    describe("Tier Auto-Progression", function () {
        beforeEach(async function () {
            // Create a tier with limited allocation for testing
            await tierManager.connect(admin).createTier(
                5, // tierId
                ethers.parseUnits("0.05", 6), // $0.05 per token
                ethers.parseEther("1000"), // Only 1,000 tokens allocation
                ethers.parseUnits("100", 6), // $100 min
                ethers.parseUnits("10000", 6), // $10,000 max
                25, // 25% TGE
                6, // 6 months vesting
                true // active
            );
        });

        it("should automatically progress to next tier when current tier is exhausted", async function () {
            const currentTier = 5;
            const nextTier = 1; // Assuming tier 1 exists

            // Enable auto-progression
            await tierManager.connect(admin).setAutoProgression(true);
            await tierManager.connect(admin).setTierProgression(currentTier, nextTier);

            // Fill up the current tier completely
            const tierAllocation = ethers.parseEther("1000");
            await tierManager.recordPurchase(currentTier, tierAllocation);

            // Verify tier is exhausted
            expect(await tierManager.tokensRemainingInTier(currentTier)).to.equal(0);

            // Check that auto-progression is triggered
            const activeStatus = await tierManager.isTierActive(currentTier);
            expect(activeStatus).to.be.false; // Should be deactivated when exhausted

            // Verify next tier is still active
            expect(await tierManager.isTierActive(nextTier)).to.be.true;
        });

        it("should handle auto-progression configuration", async function () {
            const tier1 = 0;
            const tier2 = 1;

            await tierManager.connect(admin).setTierProgression(tier1, tier2);

            const nextTier = await tierManager.getNextTier(tier1);
            expect(nextTier).to.equal(tier2);
        });

        it("should prevent circular tier progression", async function () {
            const tier1 = 0;
            const tier2 = 1;

            // Set up progression: 0 -> 1
            await tierManager.connect(admin).setTierProgression(tier1, tier2);

            // Attempt to create circular progression: 1 -> 0
            await expect(
                tierManager.connect(admin).setTierProgression(tier2, tier1)
            ).to.be.revertedWith("Circular progression not allowed");
        });
    });

    describe("Dynamic Pricing", function () {
        it("should allow setting dynamic pricing based on demand", async function () {
            const tierId = 0;
            const basePrice = ethers.parseUnits("0.04", 6);
            const maxPriceIncrease = 50; // 50% max increase

            await tierManager.connect(admin).enableDynamicPricing(
                tierId,
                basePrice,
                maxPriceIncrease
            );

            // Verify dynamic pricing is enabled
            const pricingConfig = await tierManager.getDynamicPricingConfig(tierId);
            expect(pricingConfig.enabled).to.be.true;
            expect(pricingConfig.basePrice).to.equal(basePrice);
            expect(pricingConfig.maxIncrease).to.equal(maxPriceIncrease);
        });

        it("should adjust price based on tier sales progress", async function () {
            const tierId = 0;
            const basePrice = ethers.parseUnits("0.04", 6);

            await tierManager.connect(admin).enableDynamicPricing(
                tierId,
                basePrice,
                100 // 100% max increase
            );

            // Get initial price
            const initialPrice = await tierManager.getCurrentPrice(tierId);
            expect(initialPrice).to.equal(basePrice);

            // Sell 50% of tier allocation
            const tierDetails = await tierManager.getTierDetails(tierId);
            const halfAllocation = tierDetails.allocation / BigInt(2);
            await tierManager.recordPurchase(tierId, halfAllocation);

            // Price should increase
            const newPrice = await tierManager.getCurrentPrice(tierId);
            expect(newPrice).to.be.gt(basePrice);
        });

        it("should not exceed maximum price increase", async function () {
            const tierId = 0;
            const basePrice = ethers.parseUnits("0.04", 6);
            const maxIncrease = 25; // 25% max

            await tierManager.connect(admin).enableDynamicPricing(
                tierId,
                basePrice,
                maxIncrease
            );

            // Sell entire tier allocation
            const tierDetails = await tierManager.getTierDetails(tierId);
            await tierManager.recordPurchase(tierId, tierDetails.allocation);

            // Price should not exceed base price + 25%
            const finalPrice = await tierManager.getCurrentPrice(tierId);
            const maxAllowedPrice = basePrice + (basePrice * BigInt(maxIncrease) / BigInt(100));
            expect(finalPrice).to.be.lte(maxAllowedPrice);
        });
    });

    describe("Tier Snapshots and Analytics", function () {
        beforeEach(async function () {
            // Record some sample purchases
            await tierManager.recordPurchase(0, ethers.parseEther("10000"));
            await tierManager.recordPurchase(1, ethers.parseEther("5000"));
        });

        it("should create tier performance snapshots", async function () {
            const snapshotId = await tierManager.createSnapshot();

            const snapshot = await tierManager.getSnapshot(snapshotId);
            expect(snapshot.timestamp).to.be.gt(0);
            expect(snapshot.totalSold).to.be.gt(0);
        });

        it("should track tier sale velocity", async function () {
            const tierId = 0;
            const initialTime = await ethers.provider.getBlock('latest').then(b => b.timestamp);

            // Record initial purchase
            await tierManager.recordPurchase(tierId, ethers.parseEther("1000"));

            // Advance time
            await ethers.provider.send("evm_increaseTime", [3600]); // 1 hour
            await ethers.provider.send("evm_mine");

            // Record another purchase
            await tierManager.recordPurchase(tierId, ethers.parseEther("2000"));

            const velocity = await tierManager.getTierVelocity(tierId, 3600); // Last hour
            expect(velocity).to.equal(ethers.parseEther("2000"));
        });

        it("should calculate tier completion percentage", async function () {
            const tierId = 0;
            const tierDetails = await tierManager.getTierDetails(tierId);

            // Sell 30% of allocation
            const soldAmount = tierDetails.allocation * BigInt(30) / BigInt(100);
            await tierManager.recordPurchase(tierId, soldAmount);

            const completionPercentage = await tierManager.getTierCompletionPercentage(tierId);
            expect(completionPercentage).to.be.closeTo(30, 1); // Allow 1% variance
        });

        it("should provide tier sales analytics", async function () {
            const tierId = 0;

            const analytics = await tierManager.getTierAnalytics(tierId);
            expect(analytics.totalSales).to.be.gte(0);
            expect(analytics.averagePurchaseSize).to.be.gte(0);
            expect(analytics.uniqueBuyers).to.be.gte(0);
        });
    });

    describe("Emergency Functions", function () {
        it("should allow emergency pause of all tiers", async function () {
            await tierManager.connect(emergency).emergencyPauseAllTiers();

            // All tiers should be inactive
            expect(await tierManager.isTierActive(0)).to.be.false;
            expect(await tierManager.isTierActive(1)).to.be.false;
        });

        it("should allow emergency reactivation of tiers", async function () {
            // First pause all tiers
            await tierManager.connect(emergency).emergencyPauseAllTiers();

            // Then reactivate specific tier
            await tierManager.connect(emergency).emergencyReactivateTier(0);

            expect(await tierManager.isTierActive(0)).to.be.true;
            expect(await tierManager.isTierActive(1)).to.be.false; // Others remain paused
        });

        it("should allow emergency allocation adjustment", async function () {
            const tierId = 0;
            const originalAllocation = (await tierManager.getTierDetails(tierId)).allocation;
            const newAllocation = originalAllocation + ethers.parseEther("100000");

            await tierManager.connect(emergency).emergencyAdjustAllocation(tierId, newAllocation);

            const updatedTier = await tierManager.getTierDetails(tierId);
            expect(updatedTier.allocation).to.equal(newAllocation);
        });

        it("should allow emergency price override", async function () {
            const tierId = 0;
            const emergencyPrice = ethers.parseUnits("0.01", 6); // Very low emergency price

            await tierManager.connect(emergency).emergencyPriceOverride(tierId, emergencyPrice);

            const currentPrice = await tierManager.getCurrentPrice(tierId);
            expect(currentPrice).to.equal(emergencyPrice);
        });

        it("should prevent non-emergency roles from using emergency functions", async function () {
            await expect(
                tierManager.connect(user1).emergencyPauseAllTiers()
            ).to.be.reverted;

            await expect(
                tierManager.connect(admin).emergencyPriceOverride(0, ethers.parseUnits("0.01", 6))
            ).to.be.reverted;
        });
    });

    describe("Cross-Tier Functionality", function () {
        it("should handle tier bridging for partial purchases", async function () {
            const tier1Id = 0;
            const tier2Id = 1;

            // Set up tier bridging
            await tierManager.connect(admin).enableTierBridging(tier1Id, tier2Id);

            // Get tier 1 remaining tokens (assume it's low)
            const tier1Remaining = await tierManager.tokensRemainingInTier(tier1Id);

            // Attempt to purchase more than remaining in tier 1
            const purchaseAmount = tier1Remaining + ethers.parseEther("1000");

            // This should bridge to tier 2
            await tierManager.recordBridgedPurchase(tier1Id, purchaseAmount);

            // Verify tier 1 is exhausted and tier 2 has the overflow
            expect(await tierManager.tokensRemainingInTier(tier1Id)).to.equal(0);

            const tier2Details = await tierManager.getTierDetails(tier2Id);
            expect(tier2Details.sold).to.be.gt(0);
        });

        it("should calculate weighted average price across tiers", async function () {
            const tier1Id = 0;
            const tier2Id = 1;

            // Record purchases in both tiers
            await tierManager.recordPurchase(tier1Id, ethers.parseEther("5000"));
            await tierManager.recordPurchase(tier2Id, ethers.parseEther("3000"));

            const weightedPrice = await tierManager.getWeightedAveragePrice([tier1Id, tier2Id]);
            expect(weightedPrice).to.be.gt(0);
        });

        it("should provide cross-tier statistics", async function () {
            const tiers = [0, 1];

            const crossTierStats = await tierManager.getCrossTierStats(tiers);
            expect(crossTierStats.totalSold).to.be.gte(0);
            expect(crossTierStats.totalAllocation).to.be.gt(0);
            expect(crossTierStats.averagePrice).to.be.gt(0);
        });
    });

    describe("Tier Validation and Constraints", function () {
        it("should validate tier consistency", async function () {
            // This should pass for properly configured tiers
            const isValid = await tierManager.validateTierConsistency();
            expect(isValid).to.be.true;
        });

        it("should detect and report tier inconsistencies", async function () {
            // Create an invalid tier configuration
            await tierManager.connect(admin).createTier(
                10,
                ethers.parseUnits("0.10", 6), // High price
                ethers.parseEther("1000000"), // Large allocation
                ethers.parseUnits("1000000", 6), // Very high min purchase (impossible)
                ethers.parseUnits("2000000", 6), // Even higher max
                150, // Invalid TGE > 100%
                0, // Invalid vesting months
                true
            );

            const inconsistencies = await tierManager.getTierInconsistencies();
            expect(inconsistencies.length).to.be.gt(0);
        });

        it("should enforce global tier constraints", async function () {
            const totalAllocation = await tierManager.getTotalAllocation();
            const maxSupply = await tierManager.getMaxSupplyLimit();

            expect(totalAllocation).to.be.lte(maxSupply);
        });
    });

    describe("Integration with Registry System", function () {
        it("should update contract references when registry changes", async function () {
            // Deploy new mock registry
            const NewMockRegistry = await ethers.getContractFactory("MockRegistry");
            const newMockRegistry = await NewMockRegistry.deploy();

            // Update registry
            await tierManager.connect(admin).setRegistry(
                await newMockRegistry.getAddress(),
                TIER_MANAGER_NAME
            );

            expect(await tierManager.registry()).to.equal(await newMockRegistry.getAddress());
        });

        it("should handle registry offline mode", async function () {
            // Enable offline mode
            await tierManager.connect(admin).enableRegistryOfflineMode();

            // Operations should still work with fallback addresses
            const tierId = 0;
            const tokenAmount = ethers.parseEther("1000");

            // This should not revert even if registry is offline
            await expect(
                tierManager.recordPurchase(tierId, tokenAmount)
            ).to.not.be.reverted;
        });

        it("should respect system pause from registry", async function () {
            // Set system as paused in registry
            await mockRegistry.setPaused(true);

            // Tier operations should be paused
            await expect(
                tierManager.recordPurchase(0, ethers.parseEther("1000"))
            ).to.be.revertedWith("SystemPaused");
        });
    });

    describe("Upgrade and Migration", function () {
        it("should handle tier data migration", async function () {
            // Create backup of current tier data
            const backupId = await tierManager.connect(admin).createTierBackup();

            const backup = await tierManager.getTierBackup(backupId);
            expect(backup.timestamp).to.be.gt(0);
            expect(backup.tierCount).to.be.gt(0);
        });

        it("should allow tier data restoration", async function () {
            // Create backup first
            const backupId = await tierManager.connect(admin).createTierBackup();

            // Modify some tier data
            await tierManager.connect(admin).setTierActive(0, false);

            // Restore from backup
            await tierManager.connect(admin).restoreFromBackup(backupId);

            // Tier should be active again
            expect(await tierManager.isTierActive(0)).to.be.true;
        });

        it("should export tier configuration for migration", async function () {
            const exportData = await tierManager.exportTierConfiguration();

            expect(exportData.version).to.be.gt(0);
            expect(exportData.tiers.length).to.be.gt(0);
            expect(exportData.checksum).to.not.equal(ethers.ZeroHash);
        });
    });
});