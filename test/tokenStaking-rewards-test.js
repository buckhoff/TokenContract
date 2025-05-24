const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenStaking - Part 2: Advanced Rewards and Multipliers", function () {
    let tokenStaking;
    let mockToken;
    let mockRewardsPool;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const STAKING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("STAKING_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    beforeEach(async function () {
        [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockToken = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));

        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();

        const MockRewardsPool = await ethers.getContractFactory("MockRewardsPool");
        mockRewardsPool = await MockRewardsPool.deploy();

        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        tokenStaking = await upgrades.deployProxy(TokenStaking, [
            await mockToken.getAddress(),
            await mockRewardsPool.getAddress()
        ], {
            initializer: "initialize",
        });

        await tokenStaking.grantRole(ADMIN_ROLE, admin.address);
        await tokenStaking.grantRole(STAKING_MANAGER_ROLE, admin.address);
        await tokenStaking.grantRole(EMERGENCY_ROLE, emergency.address);

        const TOKEN_STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));
        await tokenStaking.setRegistry(await mockRegistry.getAddress(), TOKEN_STAKING_NAME);

        // Transfer tokens to users
        await mockToken.transfer(user1.address, ethers.parseEther("100000"));
        await mockToken.transfer(user2.address, ethers.parseEther("75000"));
        await mockToken.transfer(user3.address, ethers.parseEther("50000"));

        // Transfer tokens to rewards pool
        await mockToken.transfer(await mockRewardsPool.getAddress(), ethers.parseEther("2000000"));
    });

    describe("Loyalty Multipliers", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200, // 12% base APY
                180 * 24 * 60 * 60, // 180 days lock
                ethers.parseEther("1000"),
                ethers.parseEther("100000"),
                true
            );

            poolId = 1;

            const stakeAmount = ethers.parseEther("10000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);
            stakeId = 0;
        });

        it("should apply loyalty multipliers based on staking duration", async function () {
            // Set loyalty multipliers in rewards pool
            await mockRewardsPool.setLoyaltyMultiplier(user1.address, 12000); // 20% bonus

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]); // 30 days
            await ethers.provider.send("evm_mine");

            const baseRewards = await tokenStaking.calculateBaseRewards(user1.address, stakeId);
            const totalRewards = await tokenStaking.calculateTotalRewards(user1.address, stakeId);

            expect(totalRewards).to.be.gt(baseRewards);
            expect(totalRewards).to.equal(baseRewards * BigInt(12000) / BigInt(10000)); // 20% more
        });

        it("should increase loyalty multiplier over time", async function () {
            // Fast forward 6 months
            await ethers.provider.send("evm_increaseTime", [180 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            // Auto-update loyalty multiplier
            await tokenStaking.connect(admin).updateLoyaltyMultipliers([user1.address]);

            const multiplier = await mockRewardsPool.loyaltyMultiplier(user1.address);
            expect(multiplier).to.be.gt(10000); // Should be above 100%
        });

        it("should calculate projected loyalty bonuses", async function () {
            const projection = await tokenStaking.calculateLoyaltyProjection(
                user1.address,
                365 * 24 * 60 * 60 // 1 year projection
            );

            expect(projection.projectedMultiplier).to.be.gt(10000);
            expect(projection.additionalRewards).to.be.gt(0);
        });
    });

    describe("Activity-Based Rewards", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1500, // 15% APY
                90 * 24 * 60 * 60,
                ethers.parseEther("500"),
                ethers.parseEther("50000"),
                true
            );

            const stakeAmount = ethers.parseEther("5000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(1, stakeAmount);
        });

        it("should reward platform activity", async function () {
            // Record platform activity
            await mockRewardsPool.recordActivity(user1.address, 5000);

            const activityMultiplier = await mockRewardsPool.activityMultiplier(user1.address);
            expect(activityMultiplier).to.equal(11000); // 10% bonus for 5000 activity score

            // Check boosted rewards
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const totalRewards = await tokenStaking.calculateTotalRewards(user1.address, 0);
            const baseRewards = await tokenStaking.calculateBaseRewards(user1.address, 0);

            expect(totalRewards).to.be.gt(baseRewards);
        });

        it("should create activity-based reward events", async function () {
            const eventId = await mockRewardsPool.createRewardEvent(
                "Community Challenge",
                ethers.parseEther("1000")
            );

            // User participates
            await mockRewardsPool.participateInEvent(eventId);

            // Check additional rewards
            const pendingRewards = await mockRewardsPool.getPendingRewards(user1.address);
            expect(pendingRewards).to.equal(ethers.parseEther("1000"));
        });

        it("should batch distribute activity rewards", async function () {
            const users = [user1.address, user2.address, user3.address];
            const amounts = [
                ethers.parseEther("500"),
                ethers.parseEther("750"),
                ethers.parseEther("300")
            ];

            await mockRewardsPool.batchDistributeRewards(users, amounts);

            for (let i = 0; i < users.length; i++) {
                const rewards = await mockRewardsPool.getPendingRewards(users[i]);
                expect(rewards).to.equal(amounts[i]);
            }
        });
    });

    describe("Tiered Staking Rewards", function () {
        beforeEach(async function () {
            // Create multiple pools with different tiers
            await tokenStaking.connect(admin).createStakingPool(
                800, // Bronze: 8% APY
                30 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                false
            );

            await tokenStaking.connect(admin).createStakingPool(
                1200, // Silver: 12% APY
                90 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("50000"),
                true
            );

            await tokenStaking.connect(admin).createStakingPool(
                1800, // Gold: 18% APY
                180 * 24 * 60 * 60,
                ethers.parseEther("10000"),
                ethers.parseEther("200000"),
                true
            );
        });

        it("should calculate tier-based reward multipliers", async function () {
            // Stake in different tiers
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("500"));
            await tokenStaking.connect(user1).stake(1, ethers.parseEther("500")); // Bronze

            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), ethers.parseEther("5000"));
            await tokenStaking.connect(user2).stake(2, ethers.parseEther("5000")); // Silver

            await mockToken.connect(user3).approve(await tokenStaking.getAddress(), ethers.parseEther("15000"));
            await tokenStaking.connect(user3).stake(3, ethers.parseEther("15000")); // Gold

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const bronzeRewards = await tokenStaking.calculatePendingRewards(user1.address, 0);
            const silverRewards = await tokenStaking.calculatePendingRewards(user2.address, 0);
            const goldRewards = await tokenStaking.calculatePendingRewards(user3.address, 0);

            // Gold should have highest rewards per token
            const bronzeRate = bronzeRewards * BigInt(10000) / ethers.parseEther("500");
            const silverRate = silverRewards * BigInt(10000) / ethers.parseEther("5000");
            const goldRate = goldRewards * BigInt(10000) / ethers.parseEther("15000");

            expect(goldRate).to.be.gt(silverRate);
            expect(silverRate).to.be.gt(bronzeRate);
        });

        it("should allow tier upgrades based on stake amount", async function () {
            // Start in bronze
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("500"));
            await tokenStaking.connect(user1).stake(1, ethers.parseEther("500"));

            // Upgrade to silver by staking more
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("2000"));
            await tokenStaking.connect(user1).stake(2, ethers.parseEther("2000"));

            const userTotalStaked = await tokenStaking.getUserTotalStaked(user1.address);
            expect(userTotalStaked).to.equal(ethers.parseEther("2500"));

            // Should qualify for silver tier benefits
            const silverAccess = await tokenStaking.getUserTierAccess(user1.address);
            expect(silverAccess).to.be.gte(2); // Silver tier or higher
        });
    });

    describe("Bonus Reward Events", function () {
        let poolId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("50000"),
                true
            );

            poolId = 1;

            const stakeAmount = ethers.parseEther("8000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);
        });

        it("should create limited-time bonus events", async function () {
            const eventDuration = 7 * 24 * 60 * 60; // 7 days
            const bonusMultiplier = 15000; // 50% bonus

            await tokenStaking.connect(admin).createBonusEvent(
                "Holiday Bonus",
                eventDuration,
                bonusMultiplier,
                [poolId] // Applicable pools
            );

            // Fast forward 3 days into event
            await ethers.provider.send("evm_increaseTime", [3 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const bonusRewards = await tokenStaking.calculateBonusRewards(user1.address, 0);
            expect(bonusRewards).to.be.gt(0);

            const totalRewards = await tokenStaking.calculateTotalRewards(user1.address, 0);
            const baseRewards = await tokenStaking.calculateBaseRewards(user1.address, 0);

            expect(totalRewards).to.equal(baseRewards * BigInt(bonusMultiplier) / BigInt(10000));
        });

        it("should handle milestone-based bonus rewards", async function () {
            const milestones = [
                { threshold: ethers.parseEther("50000"), bonus: ethers.parseEther("500") },
                { threshold: ethers.parseEther("100000"), bonus: ethers.parseEther("1200") },
                { threshold: ethers.parseEther("200000"), bonus: ethers.parseEther("3000") }
            ];

            await tokenStaking.connect(admin).setGlobalMilestones(milestones);

            // Simulate reaching first milestone
            await tokenStaking.connect(admin).updateGlobalStaked(ethers.parseEther("55000"));

            // All stakers should receive milestone bonus
            const milestoneRewards = await tokenStaking.calculateMilestoneRewards(user1.address);
            expect(milestoneRewards).to.equal(ethers.parseEther("500"));
        });

        it("should distribute seasonal bonus multipliers", async function () {
            // Set seasonal bonus (e.g., summer campaign)
            await tokenStaking.connect(admin).setSeasonalBonus(
                2000, // 20% bonus
                90 * 24 * 60 * 60 // 90 days duration
            );

            await ethers.provider.send("evm_increaseTime", [45 * 24 * 60 * 60]); // Halfway through
            await ethers.provider.send("evm_mine");

            const seasonalRewards = await tokenStaking.calculateSeasonalBonus(user1.address, 0);
            expect(seasonalRewards).to.be.gt(0);
        });
    });

    describe("Referral Rewards", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200,
                90 * 24 * 60 * 60,
                ethers.parseEther("500"),
                ethers.parseEther("25000"),
                true
            );

            // Enable referral system
            await tokenStaking.connect(admin).enableReferralSystem(
                500, // 5% referrer bonus
                200  // 2% referee bonus
            );
        });

        it("should track referral relationships", async function () {
            // User1 refers user2
            await tokenStaking.connect(user2).setReferrer(user1.address);

            expect(await tokenStaking.getReferrer(user2.address)).to.equal(user1.address);

            // User2 stakes with referral
            const stakeAmount = ethers.parseEther("3000");
            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user2).stake(1, stakeAmount);

            // User1 should receive referral bonus
            const referralBonus = await tokenStaking.calculateReferralBonus(user1.address);
            expect(referralBonus).to.be.gt(0);
        });

        it("should apply multi-level referral bonuses", async function () {
            // Set up referral chain: user1 -> user2 -> user3
            await tokenStaking.connect(user2).setReferrer(user1.address);
            await tokenStaking.connect(user3).setReferrer(user2.address);

            // Enable multi-level (2 levels)
            await tokenStaking.connect(admin).setMultiLevelReferral([500, 200]); // 5% level 1, 2% level 2

            const stakeAmount = ethers.parseEther("5000");
            await mockToken.connect(user3).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user3).stake(1, stakeAmount);

            const level1Bonus = await tokenStaking.calculateReferralBonus(user2.address); // Direct referrer
            const level2Bonus = await tokenStaking.calculateReferralBonus(user1.address); // Second level

            expect(level1Bonus).to.be.gt(level2Bonus);
            expect(level2Bonus).to.be.gt(0);
        });

        it("should limit referral bonus claims", async function () {
            await tokenStaking.connect(user2).setReferrer(user1.address);

            const stakeAmount = ethers.parseEther("2000");
            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user2).stake(1, stakeAmount);

            // Set daily claim limit
            await tokenStaking.connect(admin).setReferralClaimLimit(ethers.parseEther("100"));

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const totalBonus = await tokenStaking.calculateReferralBonus(user1.address);
            await tokenStaking.connect(user1).claimReferralBonus();

            const claimed = await tokenStaking.getReferralClaimed(user1.address);
            expect(claimed).to.be.lte(ethers.parseEther("100")); // Limited by daily cap
        });
    });

    describe("Dynamic Reward Adjustments", function () {
        let poolId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1500, // 15% base APY
                120 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("100000"),
                true
            );

            poolId = 1;
        });

        it("should adjust rewards based on total staked amount", async function () {
            // Initial low stake
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("5000"));
            await tokenStaking.connect(user1).stake(poolId, ethers.parseEther("5000"));

            const initialAPY = await tokenStaking.getCurrentAPY(poolId);

            // Massive stake increase
            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), ethers.parseEther("50000"));
            await tokenStaking.connect(user2).stake(poolId, ethers.parseEther("50000"));

            // APY should decrease due to higher total staked
            const adjustedAPY = await tokenStaking.getCurrentAPY(poolId);
            expect(adjustedAPY).to.be.lt(initialAPY);
        });

        it("should implement reward halving events", async function () {
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("10000"));
            await tokenStaking.connect(user1).stake(poolId, ethers.parseEther("10000"));

            const initialRewardRate = await tokenStaking.getPoolRewardRate(poolId);

            // Trigger halving event
            await tokenStaking.connect(admin).triggerRewardHalving(poolId);

            const newRewardRate = await tokenStaking.getPoolRewardRate(poolId);
            expect(newRewardRate).to.equal(initialRewardRate / BigInt(2));
        });

        it("should apply market-based reward adjustments", async function () {
            await tokenStaking.connect(admin).enableMarketAdjustments(poolId);

            // Simulate market conditions affecting rewards
            await tokenStaking.connect(admin).setMarketMultiplier(8000); // 20% reduction due to bear market

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("8000"));
            await tokenStaking.connect(user1).stake(poolId, ethers.parseEther("8000"));

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const marketAdjustedRewards = await tokenStaking.calculateMarketAdjustedRewards(user1.address, 0);
            const baseRewards = await tokenStaking.calculateBaseRewards(user1.address, 0);

            expect(marketAdjustedRewards).to.equal(baseRewards * BigInt(8000) / BigInt(10000));
        });
    });

    describe("Reward Distribution Mechanics", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200,
                90 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("50000"),
                true
            );

            // Multiple users stake
            const stakes = [
                { user: user1, amount: ethers.parseEther("10000") },
                { user: user2, amount: ethers.parseEther("15000") },
                { user: user3, amount: ethers.parseEther("8000") }
            ];

            for (const stake of stakes) {
                await mockToken.connect(stake.user).approve(await tokenStaking.getAddress(), stake.amount);
                await tokenStaking.connect(stake.user).stake(1, stake.amount);
            }
        });

        it("should distribute rewards proportionally", async function () {
            await ethers.provider.send("evm_increaseTime", [60 * 24 * 60 * 60]); // 60 days
            await ethers.provider.send("evm_mine");

            const rewards1 = await tokenStaking.calculatePendingRewards(user1.address, 0);
            const rewards2 = await tokenStaking.calculatePendingRewards(user2.address, 0);
            const rewards3 = await tokenStaking.calculatePendingRewards(user3.address, 0);

            // Rewards should be proportional to stake amounts (10k:15k:8k)
            const ratio12 = rewards1 * BigInt(15) / rewards2 / BigInt(10);
            const ratio13 = rewards1 * BigInt(8) / rewards3 / BigInt(10);

            expect(ratio12).to.be.closeTo(1, 0.1); // Allow 10% variance
            expect(ratio13).to.be.closeTo(1, 0.1);
        });

        it("should handle batch reward distribution", async function () {
            const users = [user1.address, user2.address, user3.address];
            const stakeIds = [0, 0, 0];

            await ethers.provider.send("evm_increaseTime", [45 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            // Admin triggers batch distribution
            await tokenStaking.connect(admin).batchDistributeRewards(users, stakeIds);

            // All users should have received their rewards
            for (const user of users) {
                const pendingRewards = await tokenStaking.calculatePendingRewards(user, 0);
                expect(pendingRewards).to.equal(0); // Should be reset after distribution
            }
        });

        it("should handle reward pool depletion gracefully", async function () {
            // Drain most of the rewards pool
            const poolBalance = await mockToken.balanceOf(await mockRewardsPool.getAddress());
            await mockRewardsPool.emergencyDrainPool();

            // Add minimal amount back
            await mockToken.transfer(await mockRewardsPool.getAddress(), ethers.parseEther("1000"));

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            // Should still calculate rewards but may be limited
            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, 0);

            // Try to claim - should either succeed with limited amount or fail gracefully
            try {
                await tokenStaking.connect(user1).claimRewards(0);
            } catch (error) {
                expect(error.message).to.include("Insufficient reward pool balance");
            }
        });
    });

    describe("Advanced Reward Analytics", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(1000, 60 * 24 * 60 * 60, ethers.parseEther("500"), ethers.parseEther("25000"), true);

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("5000"));
            await tokenStaking.connect(user1).stake(1, ethers.parseEther("5000"));
        });

        it("should calculate reward velocity", async function () {
            await ethers.provider.send("evm_increaseTime", [15 * 24 * 60 * 60]); // 15 days
            await ethers.provider.send("evm_mine");

            const velocity = await tokenStaking.calculateRewardVelocity(user1.address, 0);
            expect(velocity.dailyRate).to.be.gt(0);
            expect(velocity.weeklyProjection).to.be.gt(0);
        });

        it("should provide reward history analytics", async function () {
            // Fast forward and claim multiple times
            for (let i = 0; i < 3; i++) {
                await ethers.provider.send("evm_increaseTime", [10 * 24 * 60 * 60]);
                await ethers.provider.send("evm_mine");
                await tokenStaking.connect(user1).claimRewards(0);
            }

            const history = await tokenStaking.getRewardHistory(user1.address, 0);
            expect(history.totalClaimed).to.be.gt(0);
            expect(history.claimCount).to.equal(3);
        });

        it("should calculate optimal claiming frequency", async function () {
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const optimization = await tokenStaking.calculateOptimalClaiming(user1.address, 0);
            expect(optimization.recommendedFrequency).to.be.gt(0);
            expect(optimization.gasCostConsideration).to.be.gt(0);
        });
    });
});