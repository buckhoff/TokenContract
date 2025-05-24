const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenStaking - Part 1: Basic Staking Operations", function () {
    let tokenStaking;
    let mockToken;
    let mockStaking;
    let mockRewardsPool;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const STAKING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("STAKING_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    // Registry contract names
    const TOKEN_STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));
    const TEACH_TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
    const REWARDS_POOL_NAME = ethers.keccak256(ethers.toUtf8Bytes("REWARDS_POOL"));

    beforeEach(async function () {
        // Get signers
        [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

        // Deploy mock token
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockToken = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));

        // Deploy mock registry
        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();

        // Deploy mock staking
        const MockStaking = await ethers.getContractFactory("MockStaking");
        mockStaking = await MockStaking.deploy();

        // Deploy mock rewards pool
        const MockRewardsPool = await ethers.getContractFactory("MockRewardsPool");
        mockRewardsPool = await MockRewardsPool.deploy();

        // Deploy TokenStaking
        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        tokenStaking = await upgrades.deployProxy(TokenStaking, [
            await mockToken.getAddress(),
            await mockRewardsPool.getAddress()
        ], {
            initializer: "initialize",
        });

        // Set up roles
        await tokenStaking.grantRole(ADMIN_ROLE, admin.address);
        await tokenStaking.grantRole(STAKING_MANAGER_ROLE, admin.address);
        await tokenStaking.grantRole(EMERGENCY_ROLE, emergency.address);

        // Set registry
        await tokenStaking.setRegistry(await mockRegistry.getAddress(), TOKEN_STAKING_NAME);

        // Register contracts in mock registry
        await mockRegistry.setContractAddress(TOKEN_STAKING_NAME, await tokenStaking.getAddress(), true);
        await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await mockToken.getAddress(), true);
        await mockRegistry.setContractAddress(REWARDS_POOL_NAME, await mockRewardsPool.getAddress(), true);

        // Transfer tokens to users for staking
        await mockToken.transfer(user1.address, ethers.parseEther("100000"));
        await mockToken.transfer(user2.address, ethers.parseEther("75000"));
        await mockToken.transfer(user3.address, ethers.parseEther("50000"));

        // Transfer tokens to rewards pool
        await mockToken.transfer(await mockRewardsPool.getAddress(), ethers.parseEther("1000000"));
    });

    describe("Initialization", function () {
        it("should initialize with correct token and rewards pool", async function () {
            expect(await tokenStaking.stakingToken()).to.equal(await mockToken.getAddress());
            expect(await tokenStaking.rewardsPool()).to.equal(await mockRewardsPool.getAddress());
        });

        it("should set correct roles", async function () {
            expect(await tokenStaking.hasRole(await tokenStaking.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await tokenStaking.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await tokenStaking.hasRole(STAKING_MANAGER_ROLE, admin.address)).to.be.true;
            expect(await tokenStaking.hasRole(EMERGENCY_ROLE, emergency.address)).to.be.true;
        });

        it("should set registry correctly", async function () {
            expect(await tokenStaking.registry()).to.equal(await mockRegistry.getAddress());
            expect(await tokenStaking.contractName()).to.equal(TOKEN_STAKING_NAME);
        });
    });

    describe("Staking Pool Management", function () {
        it("should allow admin to create staking pools", async function () {
            const poolParams = {
                rewardRate: 1200, // 12% APY
                lockPeriod: 90 * 24 * 60 * 60, // 90 days
                minStake: ethers.parseEther("100"),
                maxStake: ethers.parseEther("100000"),
                allowCompounding: true
            };

            const tx = await tokenStaking.connect(admin).createStakingPool(
                poolParams.rewardRate,
                poolParams.lockPeriod,
                poolParams.minStake,
                poolParams.maxStake,
                poolParams.allowCompounding
            );

            await expect(tx).to.emit(tokenStaking, "StakingPoolCreated").withArgs(1);

            const pool = await tokenStaking.getPoolInfo(1);
            expect(pool.rewardRate).to.equal(poolParams.rewardRate);
            expect(pool.lockPeriod).to.equal(poolParams.lockPeriod);
            expect(pool.minStake).to.equal(poolParams.minStake);
            expect(pool.maxStake).to.equal(poolParams.maxStake);
            expect(pool.allowCompounding).to.equal(poolParams.allowCompounding);
            expect(pool.isActive).to.be.true;
        });

        it("should allow admin to update pool parameters", async function () {
            // Create pool first
            await tokenStaking.connect(admin).createStakingPool(
                1000, // 10% APY
                60 * 24 * 60 * 60, // 60 days
                ethers.parseEther("50"),
                ethers.parseEther("50000"),
                false
            );

            const poolId = 1;
            const newRewardRate = 1500; // 15% APY

            await tokenStaking.connect(admin).updatePoolRewardRate(poolId, newRewardRate);

            const pool = await tokenStaking.getPoolInfo(poolId);
            expect(pool.rewardRate).to.equal(newRewardRate);
        });

        it("should allow admin to activate/deactivate pools", async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                true
            );

            const poolId = 1;

            // Deactivate pool
            await tokenStaking.connect(admin).setPoolActive(poolId, false);
            expect((await tokenStaking.getPoolInfo(poolId)).isActive).to.be.false;

            // Reactivate pool
            await tokenStaking.connect(admin).setPoolActive(poolId, true);
            expect((await tokenStaking.getPoolInfo(poolId)).isActive).to.be.true;
        });

        it("should prevent non-admin from creating pools", async function () {
            await expect(
                tokenStaking.connect(user1).createStakingPool(
                    1000,
                    60 * 24 * 60 * 60,
                    ethers.parseEther("100"),
                    ethers.parseEther("10000"),
                    true
                )
            ).to.be.reverted; // Will revert due to role check
        });
    });

    describe("Basic Staking Operations", function () {
        let poolId;

        beforeEach(async function () {
            // Create a test pool
            await tokenStaking.connect(admin).createStakingPool(
                1200, // 12% APY
                90 * 24 * 60 * 60, // 90 days lock
                ethers.parseEther("100"), // Min stake
                ethers.parseEther("50000"), // Max stake
                true // Allow compounding
            );

            poolId = 1;
        });

        it("should allow users to stake tokens", async function () {
            const stakeAmount = ethers.parseEther("1000");

            // Approve tokens
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            const tx = await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            await expect(tx).to.emit(tokenStaking, "TokensStaked")
                .withArgs(user1.address, poolId, 0, stakeAmount);

            // Check stake was recorded
            const userStake = await tokenStaking.getUserStake(user1.address, 0);
            expect(userStake.amount).to.equal(stakeAmount);
            expect(userStake.poolId).to.equal(poolId);
            expect(userStake.startTime).to.be.gt(0);

            // Check pool total
            const pool = await tokenStaking.getPoolInfo(poolId);
            expect(pool.totalStaked).to.equal(stakeAmount);

            // Check user's total staked
            const userTotal = await tokenStaking.getUserTotalStaked(user1.address);
            expect(userTotal).to.equal(stakeAmount);
        });

        it("should prevent staking below minimum", async function () {
            const belowMin = ethers.parseEther("50"); // Below 100 minimum

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), belowMin);

            await expect(
                tokenStaking.connect(user1).stake(poolId, belowMin)
            ).to.be.revertedWith("Below minimum stake");
        });

        it("should prevent staking above maximum", async function () {
            const aboveMax = ethers.parseEther("60000"); // Above 50000 maximum

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), aboveMax);

            await expect(
                tokenStaking.connect(user1).stake(poolId, aboveMax)
            ).to.be.revertedWith("Above maximum stake");
        });

        it("should prevent staking in inactive pools", async function () {
            // Deactivate pool
            await tokenStaking.connect(admin).setPoolActive(poolId, false);

            const stakeAmount = ethers.parseEther("1000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            await expect(
                tokenStaking.connect(user1).stake(poolId, stakeAmount)
            ).to.be.revertedWith("Pool not active");
        });

        it("should allow multiple stakes from same user", async function () {
            const stake1 = ethers.parseEther("1000");
            const stake2 = ethers.parseEther("2000");

            // First stake
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stake1);
            await tokenStaking.connect(user1).stake(poolId, stake1);

            // Second stake
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stake2);
            await tokenStaking.connect(user1).stake(poolId, stake2);

            // Check user has 2 stakes
            const userStakeCount = await tokenStaking.getUserStakeCount(user1.address);
            expect(userStakeCount).to.equal(2);

            // Check total staked
            const userTotal = await tokenStaking.getUserTotalStaked(user1.address);
            expect(userTotal).to.equal(stake1 + stake2);
        });
    });

    describe("Unstaking Operations", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            // Create pool
            await tokenStaking.connect(admin).createStakingPool(
                1200, // 12% APY
                30 * 24 * 60 * 60, // 30 days lock
                ethers.parseEther("100"),
                ethers.parseEther("50000"),
                true
            );

            poolId = 1;

            // User stakes tokens
            const stakeAmount = ethers.parseEther("5000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            stakeId = 0;
        });

        it("should allow unstaking after lock period", async function () {
            // Fast forward past lock period
            await ethers.provider.send("evm_increaseTime", [35 * 24 * 60 * 60]); // 35 days
            await ethers.provider.send("evm_mine");

            const initialBalance = await mockToken.balanceOf(user1.address);
            const stakeAmount = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;

            const tx = await tokenStaking.connect(user1).unstake(stakeId);

            await expect(tx).to.emit(tokenStaking, "TokensUnstaked")
                .withArgs(user1.address, poolId, stakeId, stakeAmount);

            const finalBalance = await mockToken.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(stakeAmount);

            // Stake should be cleared
            const userStake = await tokenStaking.getUserStake(user1.address, stakeId);
            expect(userStake.amount).to.equal(0);
        });

        it("should apply penalty for early unstaking", async function () {
            // Try to unstake before lock period ends
            const initialBalance = await mockToken.balanceOf(user1.address);
            const stakeAmount = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;

            await tokenStaking.connect(user1).unstake(stakeId);

            const finalBalance = await mockToken.balanceOf(user1.address);
            const received = finalBalance - initialBalance;

            // Should receive less than staked due to penalty
            expect(received).to.be.lt(stakeAmount);

            // Check penalty was applied
            const penalty = await tokenStaking.getSlashedAmount(user1.address);
            expect(penalty).to.be.gt(0);
        });

        it("should prevent unstaking non-existent stakes", async function () {
            const nonExistentStakeId = 999;

            await expect(
                tokenStaking.connect(user1).unstake(nonExistentStakeId)
            ).to.be.revertedWith("No stake found");
        });

        it("should prevent other users from unstaking", async function () {
            await expect(
                tokenStaking.connect(user2).unstake(stakeId)
            ).to.be.revertedWith("Not your stake");
        });
    });

    describe("Reward Calculations", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            // Create pool with known APY
            await tokenStaking.connect(admin).createStakingPool(
                1200, // 12% APY
                90 * 24 * 60 * 60, // 90 days lock
                ethers.parseEther("100"),
                ethers.parseEther("50000"),
                true
            );

            poolId = 1;

            // User stakes tokens
            const stakeAmount = ethers.parseEther("10000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            stakeId = 0;
        });

        it("should calculate rewards correctly over time", async function () {
            // Fast forward 30 days
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);

            // 12% APY on 10,000 tokens for 30 days ≈ 98.63 tokens
            const expectedRewards = ethers.parseEther("98.63");
            expect(pendingRewards).to.be.closeTo(expectedRewards, ethers.parseEther("5")); // 5 token tolerance
        });

        it("should show zero rewards initially", async function () {
            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);
            expect(pendingRewards).to.equal(0);
        });

        it("should calculate total user rewards across all stakes", async function () {
            // Create second stake
            const stake2Amount = ethers.parseEther("5000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stake2Amount);
            await tokenStaking.connect(user1).stake(poolId, stake2Amount);

            // Fast forward
            await ethers.provider.send("evm_increaseTime", [60 * 24 * 60 * 60]); // 60 days
            await ethers.provider.send("evm_mine");

            const totalRewards = await tokenStaking.getUserTotalRewards(user1.address);
            expect(totalRewards).to.be.gt(0);
        });
    });

    describe("Reward Claiming", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1500, // 15% APY
                60 * 24 * 60 * 60, // 60 days lock
                ethers.parseEther("100"),
                ethers.parseEther("50000"),
                true
            );

            poolId = 1;

            const stakeAmount = ethers.parseEther("8000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            stakeId = 0;

            // Fast forward to accrue rewards
            await ethers.provider.send("evm_increaseTime", [45 * 24 * 60 * 60]); // 45 days
            await ethers.provider.send("evm_mine");
        });

        it("should allow claiming rewards", async function () {
            const initialBalance = await mockToken.balanceOf(user1.address);
            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);

            expect(pendingRewards).to.be.gt(0);

            const tx = await tokenStaking.connect(user1).claimRewards(stakeId);

            await expect(tx).to.emit(tokenStaking, "RewardsClaimed")
                .withArgs(user1.address, stakeId, pendingRewards);

            const finalBalance = await mockToken.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(pendingRewards);

            // Pending rewards should be reset
            const newPendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);
            expect(newPendingRewards).to.equal(0);
        });

        it("should prevent claiming when no rewards available", async function () {
            // Claim all rewards first
            await tokenStaking.connect(user1).claimRewards(stakeId);

            // Try to claim again immediately
            await expect(
                tokenStaking.connect(user1).claimRewards(stakeId)
            ).to.be.revertedWith("No rewards to claim");
        });

        it("should allow batch claiming from multiple stakes", async function () {
            // Create additional stakes
            const stake2Amount = ethers.parseEther("3000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stake2Amount);
            await tokenStaking.connect(user1).stake(poolId, stake2Amount);

            const stakeIds = [0, 1];
            const initialBalance = await mockToken.balanceOf(user1.address);

            const tx = await tokenStaking.connect(user1).batchClaimRewards(stakeIds);

            const finalBalance = await mockToken.balanceOf(user1.address);
            const totalClaimed = finalBalance - initialBalance;

            expect(totalClaimed).to.be.gt(0);
            await expect(tx).to.emit(tokenStaking, "BatchRewardsClaimed");
        });
    });

    describe("Compound Staking", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1800, // 18% APY
                120 * 24 * 60 * 60, // 120 days lock
                ethers.parseEther("500"),
                ethers.parseEther("100000"),
                true // Allow compounding
            );

            poolId = 1;

            const stakeAmount = ethers.parseEther("20000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            stakeId = 0;

            // Enable compounding
            await tokenStaking.connect(user1).enableCompounding(stakeId);

            // Fast forward to accrue rewards
            await ethers.provider.send("evm_increaseTime", [90 * 24 * 60 * 60]); // 90 days
            await ethers.provider.send("evm_mine");
        });

        it("should allow enabling compound staking", async function () {
            const userStake = await tokenStaking.getUserStake(user1.address, stakeId);
            expect(userStake.isCompounding).to.be.true;
        });

        it("should compound rewards back into stake", async function () {
            const originalStakeAmount = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;
            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);

            expect(pendingRewards).to.be.gt(0);

            const tx = await tokenStaking.connect(user1).compoundRewards(stakeId);

            await expect(tx).to.emit(tokenStaking, "RewardsCompounded")
                .withArgs(user1.address, stakeId, pendingRewards);

            const newStakeAmount = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;
            expect(newStakeAmount).to.equal(originalStakeAmount + pendingRewards);

            // Pending rewards should be reset
            const newPendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);
            expect(newPendingRewards).to.equal(0);
        });

        it("should prevent compounding when not enabled", async function () {
            // Create new stake without compounding
            const stakeAmount = ethers.parseEther("5000");
            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user2).stake(poolId, stakeAmount);

            const newStakeId = 0; // user2's first stake

            await expect(
                tokenStaking.connect(user2).compoundRewards(newStakeId)
            ).to.be.revertedWith("Compounding not enabled");
        });

        it("should prevent compounding in pools that don't allow it", async function () {
            // Create pool without compounding
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                false // No compounding
            );

            const noCompoundPoolId = 2;
            const stakeAmount = ethers.parseEther("2000");

            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user2).stake(noCompoundPoolId, stakeAmount);

            const newStakeId = 0;

            await expect(
                tokenStaking.connect(user2).enableCompounding(newStakeId)
            ).to.be.revertedWith("Compounding not allowed in this pool");
        });
    });

    describe("Staking Statistics", function () {
        beforeEach(async function () {
            // Create multiple pools and stakes for statistics testing
            await tokenStaking.connect(admin).createStakingPool(
                1200, // 12% APY
                90 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("50000"),
                true
            );

            await tokenStaking.connect(admin).createStakingPool(
                1500, // 15% APY
                180 * 24 * 60 * 60,
                ethers.parseEther("500"),
                ethers.parseEther("100000"),
                false
            );

            // Multiple users stake in different pools
            const stake1 = ethers.parseEther("10000");
            const stake2 = ethers.parseEther("15000");
            const stake3 = ethers.parseEther("8000");

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stake1);
            await tokenStaking.connect(user1).stake(1, stake1);

            await mockToken.connect(user2).approve(await tokenStaking.getAddress(), stake2);
            await tokenStaking.connect(user2).stake(2, stake2);

            await mockToken.connect(user3).approve(await tokenStaking.getAddress(), stake3);
            await tokenStaking.connect(user3).stake(1, stake3);
        });

        it("should return correct global staking statistics", async function () {
            const globalStats = await tokenStaking.getGlobalStats();

            expect(globalStats.totalStaked).to.equal(ethers.parseEther("33000")); // 10k + 15k + 8k
            expect(globalStats.totalStakers).to.equal(3);
            expect(globalStats.totalPools).to.equal(2);
        });

        it("should return correct pool statistics", async function () {
            const pool1Stats = await tokenStaking.getPoolStats(1);
            const pool2Stats = await tokenStaking.getPoolStats(2);

            expect(pool1Stats.totalStaked).to.equal(ethers.parseEther("18000")); // 10k + 8k
            expect(pool1Stats.stakerCount).to.equal(2);

            expect(pool2Stats.totalStaked).to.equal(ethers.parseEther("15000"));
            expect(pool2Stats.stakerCount).to.equal(1);
        });

        it("should return correct user statistics", async function () {
            const user1Stats = await tokenStaking.getUserStats(user1.address);

            expect(user1Stats.totalStaked).to.equal(ethers.parseEther("10000"));
            expect(user1Stats.activeStakes).to.equal(1);
            expect(user1Stats.totalRewardsClaimed).to.equal(0); // No claims yet
        });

        it("should calculate correct APY for pools", async function () {
            const pool1APY = await tokenStaking.getPoolAPY(1);
            const pool2APY = await tokenStaking.getPoolAPY(2);

            expect(pool1APY).to.equal(1200); // 12%
            expect(pool2APY).to.equal(1500); // 15%
        });
    });

    describe("Access Control", function () {
        it("should prevent unauthorized pool creation", async function () {
            await expect(
                tokenStaking.connect(user1).createStakingPool(
                    1000,
                    60 * 24 * 60 * 60,
                    ethers.parseEther("100"),
                    ethers.parseEther("10000"),
                    true
                )
            ).to.be.reverted;
        });

        it("should prevent unauthorized pool parameter updates", async function () {
            // Create pool first
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                true
            );

            await expect(
                tokenStaking.connect(user1).updatePoolRewardRate(1, 1500)
            ).to.be.reverted;
        });

        it("should allow adding staking managers", async function () {
            await tokenStaking.connect(admin).grantRole(STAKING_MANAGER_ROLE, user1.address);

            expect(await tokenStaking.hasRole(STAKING_MANAGER_ROLE, user1.address)).to.be.true;

            // User1 should now be able to create pools
            await tokenStaking.connect(user1).createStakingPool(
                800,
                30 * 24 * 60 * 60,
                ethers.parseEther("50"),
                ethers.parseEther("5000"),
                false
            );
        });
    });

    describe("Edge Cases", function () {
        it("should handle zero reward scenarios", async function () {
            // Create pool with 0% APY
            await tokenStaking.connect(admin).createStakingPool(
                0, // 0% APY
                30 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                false
            );

            const poolId = 1;
            const stakeAmount = ethers.parseEther("1000");

            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);

            // Fast forward
            await ethers.provider.send("evm_increaseTime", [60 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, 0);
            expect(pendingRewards).to.equal(0);
        });

        it("should handle queries for non-existent pools", async function () {
            const nonExistentPoolId = 999;

            const poolInfo = await tokenStaking.getPoolInfo(nonExistentPoolId);
            expect(poolInfo.isActive).to.be.false;
            expect(poolInfo.totalStaked).to.equal(0);
        });

        it("should handle users with no stakes", async function () {
            const userStats = await tokenStaking.getUserStats(user3.address);
            expect(userStats.totalStaked).to.equal(0);
            expect(userStats.activeStakes).to.equal(0);
        });
    });

    describe("Integration with Registry", function () {
        it("should respect system pause from registry", async function () {
            // Create pool first
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                true
            );

            // Set system as paused in registry
            await mockRegistry.setPaused(true);

            const stakeAmount = ethers.parseEther("1000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            // Staking operations should be paused
            await expect(
                tokenStaking.connect(user1).stake(1, stakeAmount)
            ).to.be.revertedWith("SystemPaused");
        });

        it("should handle registry offline mode", async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                true
            );

            // Enable offline mode
            await tokenStaking.connect(admin).enableRegistryOfflineMode();

            const stakeAmount = ethers.parseEther("1000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            // Operations should still work
            await expect(
                tokenStaking.connect(user1).stake(1, stakeAmount)
            ).to.not.be.reverted;
        });
    });
});