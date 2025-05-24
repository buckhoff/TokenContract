const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TierManager - Part 2: Bonus System and Dynamic Pricing", function () {
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

    describe("Bonus Configuration", function () {
        it("should allow admin to set tier bonus percentages", async function () {
            const tierId = 0;
            const bonusPercentage = 25; // 25% bonus

            await tierManager.connect(admin).setTierBonus(tierId, bonusPercentage);

            const currentBonus = await tierManager.getCurrentBonus(tierId);
            expect(currentBonus).to.equal(bonusPercentage);
        });

        it("should prevent setting bonus percentage above maximum", async function () {
            const tierId = 0;
            const invalidBonus = 101; // Over 100%

            await expect(
                tierManager.connect(admin).setTierBonus(tierId, invalidBonus)
            ).to.be.revertedWith("Bonus percentage too high");
        });

        it("should allow setting zero bonus", async function () {
            const tierId = 0;
            const zeroBonus = 0;

            await tierManager.connect(admin).setTierBonus(tierId, zeroBonus);

            const currentBonus = await tierManager.getCurrentBonus(tierId);
            expect(currentBonus).to.equal(zeroBonus);
        });

        it("should not allow non-admin to set bonus percentages", async function () {
            const tierId = 0;
            const bonusPercentage = 20;

            await expect(
                tierManager.connect(user1).setTierBonus(tierId, bonusPercentage)
            ).to.be.reverted; // Will revert due to role check
        });
    });

    describe("Time-Based Bonuses", function () {
        beforeEach(async function () {
            // Set up a time-based bonus schedule
            const tierId = 0;
            const startTime = Math.floor(Date.now() / 1000);
            const phases = [
                { endTime: startTime + 86400, bonus: 30 }, // Day 1: 30% bonus
                { endTime: startTime + 172800, bonus: 20 }, // Day 2: 20% bonus
                { endTime: startTime + 259200, bonus: 10 }, // Day 3: 10% bonus
                { endTime: startTime + 345600, bonus: 0 }   // Day 4+: 0% bonus
            ];

            // Set up time-based bonuses (if the contract supports it)
            for (let i = 0; i < phases.length; i++) {
                await tierManager.connect(admin).setTimedBonus(
                    tierId,
                    i,
                    phases[i].endTime,
                    phases[i].bonus
                );
            }
        });

        it("should return correct bonus for current time", async function () {
            const tierId = 0;
            const currentBonus = await tierManager.getCurrentBonus(tierId);

            // Should return the first phase bonus (30%)
            expect(currentBonus).to.equal(30);
        });

        it("should update bonus as time progresses", async function () {
            const tierId = 0;

            // Advance time to second phase
            await ethers.provider.send("evm_increaseTime", [86401]); // Move past first day
            await ethers.provider.send("evm_mine");

            const currentBonus = await tierManager.getCurrentBonus(tierId);
            expect(currentBonus).to.equal(20); // Should be in second phase
        });

        it("should handle end of bonus period", async function () {
            const tierId = 0;

            // Advance time past all bonus phases
            await ethers.provider.send("evm_increaseTime", [345601]); // Move past all phases
            await ethers.provider.send("evm_mine");

            const currentBonus = await tierManager.getCurrentBonus(tierId);
            expect(currentBonus).to.equal(0); // No bonus after all phases
        });
    });

    describe("Volume-Based Bonuses", function () {
        it("should apply volume bonus for large purchases", async function () {
            const tierId = 0;
            const largeAmount = ethers.parseUnits("10000", 6); // $10,000 purchase

            // Set volume-based bonus thresholds
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("5000", 6), // $5,000 threshold
                5 // 5% additional bonus
            );

            const bonus = await tierManager.getVolumeBonus(largeAmount);
            expect(bonus).to.equal(5);
        });

        it("should not apply volume bonus for small purchases", async function () {
            const tierId = 0;
            const smallAmount = ethers.parseUnits("1000", 6); // $1,000 purchase

            // Set volume-based bonus thresholds
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("5000", 6), // $5,000 threshold
                5 // 5% additional bonus
            );

            const bonus = await tierManager.getVolumeBonus(smallAmount);
            expect(bonus).to.equal(0);
        });

        it("should handle multiple volume tiers", async function () {
            // Set multiple volume bonus thresholds
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("1000", 6), // $1,000 threshold
                2 // 2% bonus
            );

            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("5000", 6), // $5,000 threshold
                5 // 5% bonus
            );

            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("25000", 6), // $25,000 threshold
                10 // 10% bonus
            );

            // Test different purchase amounts
            expect(await tierManager.getVolumeBonus(ethers.parseUnits("500", 6))).to.equal(0);
            expect(await tierManager.getVolumeBonus(ethers.parseUnits("2000", 6))).to.equal(2);
            expect(await tierManager.getVolumeBonus(ethers.parseUnits("10000", 6))).to.equal(5);
            expect(await tierManager.getVolumeBonus(ethers.parseUnits("30000", 6))).to.equal(10);
        });
    });

    describe("Cumulative Bonus Calculation", function () {
        beforeEach(async function () {
            const tierId = 0;

            // Set base tier bonus
            await tierManager.connect(admin).setTierBonus(tierId, 15); // 15% base bonus

            // Set time-based bonus
            const startTime = Math.floor(Date.now() / 1000);
            await tierManager.connect(admin).setTimedBonus(
                tierId,
                0,
                startTime + 86400,
                10 // 10% time bonus
            );

            // Set volume bonus
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("5000", 6),
                5 // 5% volume bonus
            );
        });

        it("should calculate total bonus correctly", async function () {
            const tierId = 0;
            const purchaseAmount = ethers.parseUnits("10000", 6); // $10,000

            const totalBonus = await tierManager.calculateTotalBonus(tierId, purchaseAmount);

            // Should combine base (15%) + time (10%) + volume (5%) = 30%
            expect(totalBonus).to.equal(30);
        });

        it("should handle bonus calculation without volume bonus", async function () {
            const tierId = 0;
            const purchaseAmount = ethers.parseUnits("1000", 6); // $1,000 (below volume threshold)

            const totalBonus = await tierManager.calculateTotalBonus(tierId, purchaseAmount);

            // Should combine base (15%) + time (10%) = 25%
            expect(totalBonus).to.equal(25);
        });

        it("should cap total bonus at maximum percentage", async function () {
            const tierId = 0;

            // Set very high bonuses
            await tierManager.connect(admin).setTierBonus(tierId, 50);
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("1000", 6),
                40
            );

            const purchaseAmount = ethers.parseUnits("10000", 6);
            const totalBonus = await tierManager.calculateTotalBonus(tierId, purchaseAmount);

            // Should be capped at maximum (e.g., 50%)
            expect(totalBonus).to.be.lte(50);
        });
    });

    describe("Bonus Token Calculation", function () {
        it("should calculate bonus tokens correctly", async function () {
            const tierId = 0;
            const tokenAmount = ethers.parseEther("10000"); // 10,000 tokens
            const bonusPercentage = 20; // 20% bonus

            await tierManager.connect(admin).setTierBonus(tierId, bonusPercentage);

            const bonusTokens = await tierManager.calculateBonusTokens(tierId, tokenAmount);
            const expectedBonus = tokenAmount * BigInt(bonusPercentage) / BigInt(100);

            expect(bonusTokens).to.equal(expectedBonus);
        });

        it("should return zero bonus tokens when no bonus is set", async function () {
            const tierId = 0;
            const tokenAmount = ethers.parseEther("10000");

            await tierManager.connect(admin).setTierBonus(tierId, 0); // No bonus

            const bonusTokens = await tierManager.calculateBonusTokens(tierId, tokenAmount);
            expect(bonusTokens).to.equal(0);
        });

        it("should handle fractional bonus calculations", async function () {
            const tierId = 0;
            const tokenAmount = ethers.parseEther("1000"); // 1,000 tokens
            const bonusPercentage = 15; // 15% bonus

            await tierManager.connect(admin).setTierBonus(tierId, bonusPercentage);

            const bonusTokens = await tierManager.calculateBonusTokens(tierId, tokenAmount);
            const expectedBonus = tokenAmount * BigInt(15) / BigInt(100); // 150 tokens

            expect(bonusTokens).to.equal(expectedBonus);
        });
    });

    describe("Bonus Events and Logging", function () {
        it("should emit event when bonus is set", async function () {
            const tierId = 0;
            const bonusPercentage = 25;

            await expect(
                tierManager.connect(admin).setTierBonus(tierId, bonusPercentage)
            ).to.emit(tierManager, "TierBonusUpdated")
                .withArgs(tierId, bonusPercentage);
        });

        it("should emit event when volume bonus is set", async function () {
            const threshold = ethers.parseUnits("5000", 6);
            const bonus = 5;

            await expect(
                tierManager.connect(admin).setVolumeBonus(threshold, bonus)
            ).to.emit(tierManager, "VolumeBonusUpdated")
                .withArgs(threshold, bonus);
        });

        it("should emit event when timed bonus is configured", async function () {
            const tierId = 0;
            const phaseId = 0;
            const endTime = Math.floor(Date.now() / 1000) + 86400;
            const bonus = 20;

            await expect(
                tierManager.connect(admin).setTimedBonus(tierId, phaseId, endTime, bonus)
            ).to.emit(tierManager, "TimedBonusConfigured")
                .withArgs(tierId, phaseId, endTime, bonus);
        });
    });

    describe("Bonus System Security", function () {
        it("should prevent unauthorized bonus modifications", async function () {
            const tierId = 0;
            const bonusPercentage = 50;

            await expect(
                tierManager.connect(user1).setTierBonus(tierId, bonusPercentage)
            ).to.be.reverted;

            await expect(
                tierManager.connect(user2).setVolumeBonus(
                    ethers.parseUnits("1000", 6),
                    10
                )
            ).to.be.reverted;
        });

        it("should validate bonus parameters", async function () {
            const tierId = 0;

            // Test invalid bonus percentage (over 100%)
            await expect(
                tierManager.connect(admin).setTierBonus(tierId, 150)
            ).to.be.revertedWith("Bonus percentage too high");

            // Test invalid volume threshold (zero)
            await expect(
                tierManager.connect(admin).setVolumeBonus(0, 10)
            ).to.be.revertedWith("Invalid volume threshold");

            // Test invalid time bonus (past time)
            const pastTime = Math.floor(Date.now() / 1000) - 86400; // Yesterday
            await expect(
                tierManager.connect(admin).setTimedBonus(tierId, 0, pastTime, 10)
            ).to.be.revertedWith("Invalid end time");
        });

        it("should handle emergency bonus reset", async function () {
            const tierId = 0;

            // Set some bonuses
            await tierManager.connect(admin).setTierBonus(tierId, 25);
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("1000", 6),
                10
            );

            // Emergency reset all bonuses
            await tierManager.connect(emergency).emergencyResetBonuses();

            // All bonuses should be reset to zero
            expect(await tierManager.getCurrentBonus(tierId)).to.equal(0);
            expect(await tierManager.getVolumeBonus(ethers.parseUnits("10000", 6))).to.equal(0);
        });
    });

    describe("Bonus Interaction with Tier Sales", function () {
        beforeEach(async function () {
            // Set up bonuses for testing
            await tierManager.connect(admin).setTierBonus(0, 20); // 20% bonus for tier 0
            await tierManager.connect(admin).setTierBonus(1, 15); // 15% bonus for tier 1

            // Set up volume bonuses
            await tierManager.connect(admin).setVolumeBonus(
                ethers.parseUnits("5000", 6),
                5
            );
        });

        it("should apply correct bonus when recording purchase", async function () {
            const tierId = 0;
            const tokenAmount = ethers.parseEther("1000");
            const purchaseAmount = ethers.parseUnits("5000", 6); // Qualifies for volume bonus

            // Record purchase with bonus calculation
            await tierManager.recordPurchaseWithBonus(
                tierId,
                tokenAmount,
                purchaseAmount
            );

            // Verify that both tier and volume bonuses were applied
            const tierDetails = await tierManager.getTierDetails(tierId);
            const expectedBonus = tokenAmount * BigInt(25) / BigInt(100); // 20% tier + 5% volume

            // The sold amount should include the bonus tokens
            expect(tierDetails.sold).to.equal(tokenAmount + expectedBonus);
        });

        it("should track bonus tokens separately from base tokens", async function () {
            const tierId = 0;
            const tokenAmount = ethers.parseEther("1000");
            const purchaseAmount = ethers.parseUnits("2000", 6); // Below volume threshold

            await tierManager.recordPurchaseWithBonus(
                tierId,
                tokenAmount,
                purchaseAmount
            );

            const bonusStats = await tierManager.getBonusStats(tierId);
            const expectedBonus = tokenAmount * BigInt(20) / BigInt(100); // 20% tier bonus only

            expect(bonusStats.totalBonusTokens).to.equal(expectedBonus);
            expect(bonusStats.totalBaseTokens).to.equal(tokenAmount);
        });
    });
});