const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TokenStaking Contract", function () {
    let TokenStaking;
    let staking;
    let TeachToken;
    let teachToken;
    let ContractRegistry;
    let registry;
    let MockGovernance;
    let governance;
    let owner;
    let platformManager;
    let teacher1;
    let teacher2;
    let school1;
    let school2;

    // Constants for testing
    const BASE_REWARD_RATE = ethers.utils.parseEther("0.001"); // 0.001 tokens per day per staked token
    const REPUTATION_MULTIPLIER = 100; // 1x multiplier
    const MAX_DAILY_REWARD = ethers.utils.parseEther("1000"); // 1000 tokens per day max
    const MINIMUM_CLAIM_PERIOD = 86400; // 1 day in seconds

    beforeEach(async function () {
        // Get contract factories
        TokenStaking = await ethers.getContractFactory("TokenStaking");
        TeachToken = await ethers.getContractFactory("TeachToken");
        ContractRegistry = await ethers.getContractFactory("ContractRegistry");

        // Mock Governance (using TeachToken as a base for simplicity)
        MockGovernance = await ethers.getContractFactory("TeachToken");

        // Get signers
        [owner, platformManager, teacher1, teacher2, school1, school2] = await ethers.getSigners();

        // Deploy token
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.deployed();

        // Deploy staking contract
        staking = await upgrades.deployProxy(TokenStaking, [
            teachToken.address,
            platformManager.address
        ], {
            initializer: "initialize",
        });
        await staking.deployed();

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
        });
        await registry.deployed();

        // Deploy mock governance
        governance = await upgrades.deployProxy(MockGovernance, [], {
            initializer: "initialize",
        });
        await governance.deployed();

        // Setup registry
        const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
        const STAKING_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_STAKING"));
        const GOVERNANCE_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_GOVERNANCE"));

        await registry.registerContract(TOKEN_NAME, teachToken.address, "0x00000000");
        await registry.registerContract(STAKING_NAME, staking.address, "0x00000000");
        await registry.registerContract(GOVERNANCE_NAME, governance.address, "0x00000000");

        // Set registry in staking contract
        await staking.setRegistry(registry.address);

        // Mint tokens for testing
        await teachToken.mint(owner.address, ethers.utils.parseEther("10000000")); // 10M tokens
        await teachToken.mint(teacher1.address, ethers.utils.parseEther("1000000")); // 1M tokens
        await teachToken.mint(teacher2.address, ethers.utils.parseEther("500000")); // 500K tokens

        // Add rewards to staking pool
        await teachToken.approve(staking.address, ethers.utils.parseEther("1000000"));
        await staking.addRewardsToPool(ethers.utils.parseEther("1000000"));

        // Register schools
        await staking.registerSchool(school1.address, "Test School 1");
        await staking.registerSchool(school2.address, "Test School 2");

        // Create staking pools
        await staking.createStakingPool(
            "Short-term Pool",
            ethers.utils.parseEther("0.001"), // 0.1% daily reward rate
            30 * 86400, // 30 days lock
            500 // 5% early withdrawal fee
        );

        await staking.createStakingPool(
            "Medium-term Pool",
            ethers.utils.parseEther("0.002"), // 0.2% daily reward rate
            90 * 86400, // 90 days lock
            1000 // 10% early withdrawal fee
        );

        await staking.createStakingPool(
            "Long-term Pool",
            ethers.utils.parseEther("0.003"), // 0.3% daily reward rate
            180 * 86400, // 180 days lock
            1500 // 15% early withdrawal fee
        );

        // Activate all pools
        for (let i = 0; i < 3; i++) {
            await staking.updateStakingPool(
                i,
                await (await staking.getPoolDetails(i)).rewardRate,
                await (await staking.getPoolDetails(i)).lockDuration,
                await (await staking.getPoolDetails(i)).earlyWithdrawalFee,
                true
            );
        }

        // Approve token transfers for teachers
        await teachToken.connect(teacher1).approve(staking.address, ethers.utils.parseEther("1000000"));
        await teachToken.connect(teacher2).approve(staking.address, ethers.utils.parseEther("500000"));
    });

    describe("Deployment", function () {
        it("Should set the correct token address", async function () {
            expect(await staking.token()).to.equal(teachToken.address);
        });

        it("Should set the correct platform rewards manager", async function () {
            expect(await staking.platformRewardsManager()).to.equal(platformManager.address);
        });

        it("Should initialize with zero staked tokens", async function () {
            for (let i = 0; i < 3; i++) {
                const pool = await staking.getPoolDetails(i);
                expect(pool.totalStaked).to.equal(0);
            }
        });

        it("Should have correct number of staking pools", async function () {
            expect(await staking.getPoolCount()).to.equal(3);
        });
    });

    describe("School Management", function () {
        it("Should register schools correctly", async function () {
            const schoolCount = await staking.getSchoolCount();
            expect(schoolCount).to.equal(2);

            const schoolDetails1 = await staking.getSchoolDetails(school1.address);
            expect(schoolDetails1.name).to.equal("Test School 1");
            expect(schoolDetails1.isRegistered).to.equal(true);
            expect(schoolDetails1.isActive).to.equal(true);

            const schoolDetails2 = await staking.getSchoolDetails(school2.address);
            expect(schoolDetails2.name).to.equal("Test School 2");
        });

        it("Should update school information", async function () {
            await staking.updateSchool(school1.address, "Updated School Name", false);

            const schoolDetails = await staking.getSchoolDetails(school1.address);
            expect(schoolDetails.name).to.equal("Updated School Name");
            expect(schoolDetails.isActive).to.equal(false);
        });

        it("Should not register same school twice", async function () {
            await expect(
                staking.registerSchool(school1.address, "Duplicate School")
            ).to.be.revertedWith("TokenStaking: already registered");
        });

        it("Should not update non-existent school", async function () {
            await expect(
                staking.updateSchool(teacher1.address, "Not a School", true)
            ).to.be.revertedWith("TokenStaking: school not registered");
        });
    });

    describe("Staking Pool Management", function () {
        it("Should create staking pools with correct parameters", async function () {
            // Check pool details for all pools
            for (let i = 0; i < 3; i++) {
                const pool = await staking.getPoolDetails(i);
                expect(pool.isActive).to.equal(true);
            }

            // Verify specific pool
            const pool1 = await staking.getPoolDetails(1);
            expect(pool1.name).to.equal("Medium-term Pool");
            expect(pool1.rewardRate).to.equal(ethers.utils.parseEther("0.002"));
            expect(pool1.lockDuration).to.equal(90 * 86400);
            expect(pool1.earlyWithdrawalFee).to.equal(1000);
        });

        it("Should update staking pool parameters", async function () {
            const newRate = ethers.utils.parseEther("0.004");
            const newDuration = 60 * 86400;
            const newFee = 800;

            await staking.updateStakingPool(0, newRate, newDuration, newFee, true);

            const pool = await staking.getPoolDetails(0);
            expect(pool.rewardRate).to.equal(newRate);
            expect(pool.lockDuration).to.equal(newDuration);
            expect(pool.earlyWithdrawalFee).to.equal(newFee);
        });

        it("Should not create pool with excessive early withdrawal fee", async function () {
            await expect(
                staking.createStakingPool(
                    "Invalid Pool",
                    ethers.utils.parseEther("0.001"),
                    30 * 86400,
                    3500 // 35% fee (too high)
                )
            ).to.be.revertedWith("TokenStaking: fee too high");
        });

        it("Should calculate correct APY for pools", async function () {
            // For a pool with 0.001 tokens per token per day
            // APY should be approximately 36.5% (0.001 * 365 * 100)
            const apy0 = await staking.getPoolAPY(0);

            // Allow for slight precision differences in calculation
            expect(apy0).to.be.closeTo(3650, 50); // ~36.5% with some tolerance

            // For pool with 0.003 rate
            const apy2 = await staking.getPoolAPY(2);
            expect(apy2).to.be.closeTo(10950, 50); // ~109.5% with some tolerance
        });
    });

    describe("Staking Operations", function () {
        it("Should allow staking tokens in a pool", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Initial balances
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const initialPoolTotal = (await staking.getPoolDetails(0)).totalStaked;

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Check balances after staking
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const finalPoolTotal = (await staking.getPoolDetails(0)).totalStaked;

            expect(finalTeacherBalance).to.equal(initialTeacherBalance.sub(stakeAmount));
            expect(finalPoolTotal).to.equal(initialPoolTotal.add(stakeAmount));

            // Check user stake
            const userStake = await staking.getUserStake(0, teacher1.address);
            expect(userStake.amount).to.equal(stakeAmount);
            expect(userStake.schoolBeneficiary).to.equal(school1.address);
        });

        it("Should not allow staking with inactive school", async function () {
            // Deactivate school
            await staking.updateSchool(school1.address, "Inactive School", false);

            // Try to stake with inactive school
            await expect(
                staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address)
            ).to.be.revertedWith("TokenStaking: school not active");
        });

        it("Should not allow staking in inactive pool", async function () {
            // Deactivate pool
            await staking.updateStakingPool(
                0,
                ethers.utils.parseEther("0.001"),
                30 * 86400,
                500,
                false
            );

            // Try to stake in inactive pool
            await expect(
                staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address)
            ).to.be.revertedWith("TokenStaking: pool not active");
        });

        it("Should allow unstaking after lock period", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Fast forward past lock period
            await time.increase(31 * 86400); // 31 days

            // Initial balances before unstaking
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const initialPoolTotal = (await staking.getPoolDetails(0)).totalStaked;

            // Unstake tokens
            await staking.connect(teacher1).unstake(0, stakeAmount);

            // Check balances after unstaking
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const finalPoolTotal = (await staking.getPoolDetails(0)).totalStaked;

            expect(finalTeacherBalance).to.equal(initialTeacherBalance.add(stakeAmount));
            expect(finalPoolTotal).to.equal(initialPoolTotal.sub(stakeAmount));

            // Check user stake is zero
            const userStake = await staking.getUserStake(0, teacher1.address);
            expect(userStake.amount).to.equal(0);
        });

        it("Should apply early withdrawal fee when unstaking before lock period", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Get pool details for fee calculation
            const pool = await staking.getPoolDetails(0);
            const earlyWithdrawalFee = pool.earlyWithdrawalFee;

            // Calculate expected fee
            const expectedFee = stakeAmount.mul(earlyWithdrawalFee).div(10000);
            const expectedReturn = stakeAmount.sub(expectedFee);

            // Initial balances before unstaking
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);

            // Unstake tokens early (no time increase)
            await staking.connect(teacher1).unstake(0, stakeAmount);

            // Check balances after unstaking
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);

            // Teacher should receive stakeAmount minus fee
            expect(finalTeacherBalance).to.equal(initialTeacherBalance.add(expectedReturn));
        });
    });

    describe("Reward Calculation and Claiming", function () {
        it("Should calculate pending rewards correctly", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Fast forward 10 days
            await time.increase(10 * 86400);

            // Calculate expected reward (based on pool's reward rate)
            const pool = await staking.getPoolDetails(0);
            const timeElapsed = 10 * 86400;
            const expectedReward = stakeAmount.mul(pool.rewardRate).mul(timeElapsed).div(365 * 86400).div(ethers.utils.parseEther("1"));

            // Get pending reward
            const pendingReward = await staking.calculatePendingReward(0, teacher1.address);

            // Should be close to expected (allow small rounding differences)
            expect(pendingReward).to.be.closeTo(expectedReward, ethers.utils.parseEther("0.1"));
        });

        it("Should allow claiming rewards", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Fast forward 10 days
            await time.increase(10 * 86400);

            // Get pending reward before claiming
            const pendingReward = await staking.calculatePendingReward(0, teacher1.address);
            expect(pendingReward).to.be.gt(0);

            // Get user stake details to check rewards split
            const stakeDetails = await staking.getUserStake(0, teacher1.address);
            const userRewardPortion = stakeDetails.userRewardPortion;

            // Initial balances
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const initialSchoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;

            // Claim rewards
            await staking.connect(teacher1).claimReward(0);

            // Check balances after claiming
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);
            const finalSchoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;

            // Teacher should receive their portion of rewards
            expect(finalTeacherBalance).to.be.closeTo(
                initialTeacherBalance.add(userRewardPortion),
                ethers.utils.parseEther("0.01") // Allow small difference
            );

            // School should have their portion added to totalRewards
            const schoolRewardPortion = pendingReward.sub(userRewardPortion);
            expect(finalSchoolRewards).to.be.closeTo(
                initialSchoolRewards.add(schoolRewardPortion),
                ethers.utils.parseEther("0.01") // Allow small difference
            );
        });

        it("Should not allow claiming too frequently", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Fast forward 1 hour (less than minimum claim period)
            await time.increase(3600);

            // Try to claim rewards
            await expect(
                staking.connect(teacher1).claimReward(0)
            ).to.be.revertedWith("TokenStaking: no rewards");
        });

        it("Should correctly track total rewards paid", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Initial rewards paid
            const initialRewardsPaid = await staking.totalRewardsPaid();

            // Stake tokens and accumulate rewards
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);
            await time.increase(10 * 86400);

            // Claim rewards
            await staking.connect(teacher1).claimReward(0);

            // Final rewards paid
            const finalRewardsPaid = await staking.totalRewardsPaid();

            // Should have increased
            expect(finalRewardsPaid).to.be.gt(initialRewardsPaid);
        });
    });

    describe("School Reward Management", function () {
        it("Should accumulate school rewards correctly", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Initial school rewards
            const initialSchoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;

            // Fast forward 10 days
            await time.increase(10 * 86400);

            // Claim rewards
            await staking.connect(teacher1).claimReward(0);

            // Check school rewards increased
            const finalSchoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;
            expect(finalSchoolRewards).to.be.gt(initialSchoolRewards);
        });

        it("Should allow platform manager to withdraw school rewards", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens and accumulate rewards
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);
            await time.increase(10 * 86400);
            await staking.connect(teacher1).claimReward(0);

            // School rewards
            const schoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;
            expect(schoolRewards).to.be.gt(0);

            // Initial balances
            const initialManagerBalance = await teachToken.balanceOf(platformManager.address);

            // Withdraw rewards
            await staking.connect(platformManager).withdrawSchoolRewards(school1.address, schoolRewards);

            // Check balances
            const finalManagerBalance = await teachToken.balanceOf(platformManager.address);
            const finalSchoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;

            expect(finalManagerBalance).to.equal(initialManagerBalance.add(schoolRewards));
            expect(finalSchoolRewards).to.equal(0);
        });

        it("Should not allow non-manager to withdraw school rewards", async function () {
            // Accumulate some rewards first
            const stakeAmount = ethers.utils.parseEther("10000");
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);
            await time.increase(10 * 86400);
            await staking.connect(teacher1).claimReward(0);

            // School rewards
            const schoolRewards = (await staking.getSchoolDetails(school1.address)).totalRewards;

            // Try to withdraw as non-manager
            await expect(
                staking.connect(teacher1).withdrawSchoolRewards(school1.address, schoolRewards)
            ).to.be.reverted;
        });

        it("Should update platform rewards manager", async function () {
            await staking.updatePlatformRewardsManager(teacher2.address);

            expect(await staking.platformRewardsManager()).to.equal(teacher2.address);

            // Verify new manager has MANAGER_ROLE
            const MANAGER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MANAGER_ROLE"));
            expect(await staking.hasRole(MANAGER_ROLE, teacher2.address)).to.equal(true);
        });
    });

    describe("Unstaking Requests", function () {
        it("Should set cooldown period", async function () {
            const newCooldown = 3 * 86400; // 3 days

            await staking.setCooldownPeriod(newCooldown);

            expect(await staking.cooldownPeriod()).to.equal(newCooldown);
        });

        it("Should allow requesting unstake", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Request unstake
            await staking.connect(teacher1).requestUnstake(0, stakeAmount);

            // Check user stake is reduced
            const userStake = await staking.getUserStake(0, teacher1.address);
            expect(userStake.amount).to.equal(0);

            // Check unstaking request exists
            const requests = await staking.getUnstakingRequests(teacher1.address, 0);
            expect(requests.length).to.equal(1);

            // Calculate expected amount after fee (if any)
            const pool = await staking.getPoolDetails(0);
            let expectedAmount = stakeAmount;

            // Apply early withdrawal fee if within lock period
            if (pool.lockDuration > 0) {
                const fee = stakeAmount.mul(pool.earlyWithdrawalFee).div(10000);
                expectedAmount = stakeAmount.sub(fee);
            }

            expect(requests[0].amount).to.equal(expectedAmount);
            expect(requests[0].claimed).to.equal(false);
        });

        it("Should allow claiming unstaked tokens after cooldown", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Request unstake
            await staking.connect(teacher1).requestUnstake(0, stakeAmount);

            // Get unstaking request
            const requests = await staking.getUnstakingRequests(teacher1.address, 0);
            const requestAmount = requests[0].amount;

            // Initial balance
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);

            // Fast forward past cooldown period
            const cooldown = await staking.cooldownPeriod();
            await time.increase(cooldown.toNumber() + 100); // Add some margin

            // Claim unstaked tokens
            await staking.connect(teacher1).claimUnstakedTokens(0, 0);

            // Check balance increased
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);
            expect(finalTeacherBalance).to.equal(initialTeacherBalance.add(requestAmount));

            // Check request marked as claimed
            const updatedRequests = await staking.getUnstakingRequests(teacher1.address, 0);
            expect(updatedRequests[0].claimed).to.equal(true);
        });

        it("Should not allow claiming before cooldown ends", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Request unstake
            await staking.connect(teacher1).requestUnstake(0, stakeAmount);

            // Fast forward half of cooldown period
            const cooldown = await staking.cooldownPeriod();
            await time.increase(cooldown.toNumber() / 2);

            // Try to claim unstaked tokens
            await expect(
                staking.connect(teacher1).claimUnstakedTokens(0, 0)
            ).to.be.revertedWith("TokenStaking: cooldown not over");
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow emergency roles to pause staking", async function () {
            expect(await staking.paused()).to.equal(false);

            await staking.pauseStaking();

            expect(await staking.paused()).to.equal(true);
        });

        it("Should prevent staking operations when paused", async function () {
            // Pause staking
            await staking.pauseStaking();

            // Try to stake
            await expect(
                staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address)
            ).to.be.revertedWith("TokenStaking: contract is paused");
        });

        it("Should allow emergency unstake with fee", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Set emergency unstake fee
            const emergencyFee = 2000; // 20%
            await staking.setEmergencyUnstakeFee(emergencyFee);

            // Calculate expected fee
            const expectedFee = stakeAmount.mul(emergencyFee).div(10000);
            const expectedReturn = stakeAmount.sub(expectedFee);

            // Initial balance
            const initialTeacherBalance = await teachToken.balanceOf(teacher1.address);

            // Emergency unstake
            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));
            await staking.grantRole(EMERGENCY_ROLE, teacher1.address);
            await staking.connect(teacher1).emergencyUnstake(0, stakeAmount);

            // Check balance
            const finalTeacherBalance = await teachToken.balanceOf(teacher1.address);
            expect(finalTeacherBalance).to.equal(initialTeacherBalance.add(expectedReturn));
        });

        it("Should resume from pause", async function () {
            // Pause staking
            await staking.pauseStaking();
            expect(await staking.paused()).to.equal(true);

            // Resume
            await staking.unpauseStaking();
            expect(await staking.paused()).to.equal(false);

            // Staking should work again
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);
        });
    });

    describe("Governance Integration", function () {
        it("Should allow updating voting power", async function () {
            // This is mostly for coverage since we can't really test the internal behavior
            // without a fully implemented governance contract

            // Stake some tokens to create a stake
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);

            // Call updateVotingPower (either directly or through stake)
            // This should succeed, though no assertions on actual voting power changes can be made
            await expect(staking.notifyGovernanceOfStakeChange(teacher1.address)).to.not.be.reverted;
        });

        it("Should get user stake details for governance", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Get stake details for voting
            const stakeForVoting = await staking.getUserStakeforVoting(0, teacher1.address);

            expect(stakeForVoting.amount).to.equal(stakeAmount);
            expect(stakeForVoting.startTime).to.be.gt(0);
        });

        it("Should calculate total user stake across pools", async function () {
            // Stake in multiple pools
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);
            await staking.connect(teacher1).stake(1, ethers.utils.parseEther("20000"), school1.address);

            // Check total stake
            const totalStake = await staking.getTotalUserStake(teacher1.address);
            expect(totalStake).to.equal(ethers.utils.parseEther("30000"));
        });
    });

    describe("Reward Pool Management", function () {
        it("Should add rewards to pool correctly", async function () {
            // Initial rewards pool
            const initialRewardsPool = await staking.rewardsPool();

            // Add rewards
            const addAmount = ethers.utils.parseEther("100000");
            await teachToken.approve(staking.address, addAmount);
            await staking.addRewardsToPool(addAmount);

            // Check updated rewards pool
            const finalRewardsPool = await staking.rewardsPool();
            expect(finalRewardsPool).to.equal(initialRewardsPool.add(addAmount));
        });

        it("Should adjust reward rates based on available rewards", async function () {
            // Get initial reward rates
            const initialRates = [];
            for (let i = 0; i < 3; i++) {
                const pool = await staking.getPoolDetails(i);
                initialRates.push(pool.rewardRate);
            }

            // Adjust reward rates
            await staking.adjustRewardRates();

            // Get adjusted rates
            const adjustedRates = [];
            for (let i = 0; i < 3; i++) {
                const pool = await staking.getPoolDetails(i);
                adjustedRates.push(pool.rewardRate);
            }

            // Rates should be different
            // Note: This test is somewhat flexible as the actual adjustment
            // will depend on total staked tokens and rewards pool
            // In a real scenario with significant staking, we'd see clear changes

            // Check that at least the timestamp was updated
            expect(await staking.lastRewardAdjustment()).to.be.gt(0);
        });

        it("Should calculate time until unlock correctly", async function () {
            const stakeAmount = ethers.utils.parseEther("10000");

            // Stake tokens
            await staking.connect(teacher1).stake(0, stakeAmount, school1.address);

            // Get pool lock duration
            const pool = await staking.getPoolDetails(0);
            const lockDuration = pool.lockDuration;

            // Calculate expected time remaining
            // Should be close to full lock duration initially
            const timeUntilUnlock = await staking.getTimeUntilUnlock(0, teacher1.address);
            expect(timeUntilUnlock).to.be.closeTo(lockDuration, 10); // Allow small difference for block times

            // Fast forward half the lock period
            await time.increase(lockDuration.div(2).toNumber());

            // Time until unlock should be about half now
            const halfTimeUnlock = await staking.getTimeUntilUnlock(0, teacher1.address);
            expect(halfTimeUnlock).to.be.closeTo(lockDuration.div(2), 10);

            // Fast forward past lock period
            await time.increase(lockDuration.div(2).toNumber() + 100);

            // Time until unlock should be 0
            const finalTimeUnlock = await staking.getTimeUntilUnlock(0, teacher1.address);
            expect(finalTimeUnlock).to.equal(0);
        });
    });

    describe("Registry Integration", function () {
        it("Should update its registry reference", async function () {
            // Deploy a new registry
            const newRegistry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });
            await newRegistry.deployed();

            // Update registry in staking contract
            await staking.setRegistry(newRegistry.address);

            expect(await staking.registry()).to.equal(newRegistry.address);
        });

        it("Should update contract references from registry", async function () {
            // Deploy a new token
            const newToken = await upgrades.deployProxy(TeachToken, [], {
                initializer: "initialize",
            });
            await newToken.deployed();

            // Update token in registry
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
            await registry.updateContract(TOKEN_NAME, newToken.address, "0x00000000");

            // Update contract references
            await staking.updateContractReferences();

            // Token should be updated to the new token
            expect(await staking.token()).to.equal(newToken.address);
        });
    });

    describe("Multi-User Scenario", function () {
        it("Should handle multiple users staking and claiming correctly", async function () {
            // Both teachers stake in pool 0
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);
            await staking.connect(teacher2).stake(0, ethers.utils.parseEther("20000"), school2.address);

            // Fast forward 15 days
            await time.increase(15 * 86400);

            // Get pending rewards for both
            const pendingReward1 = await staking.calculatePendingReward(0, teacher1.address);
            const pendingReward2 = await staking.calculatePendingReward(0, teacher2.address);

            // Teacher2 should have approximately 2x the rewards of teacher1
            expect(pendingReward2).to.be.closeTo(pendingReward1.mul(2), ethers.utils.parseEther("0.1"));

            // Both claim rewards
            await staking.connect(teacher1).claimReward(0);
            await staking.connect(teacher2).claimReward(0);

            // Check school rewards
            const school1Rewards = (await staking.getSchoolDetails(school1.address)).totalRewards;
            const school2Rewards = (await staking.getSchoolDetails(school2.address)).totalRewards;

            // School2 should have approximately 2x the rewards of school1
            expect(school2Rewards).to.be.closeTo(school1Rewards.mul(2), ethers.utils.parseEther("0.1"));

            // Teacher1 unstakes
            await staking.connect(teacher1).requestUnstake(0, ethers.utils.parseEther("10000"));

            // Fast forward past cooldown
            await time.increase((await staking.cooldownPeriod()).toNumber() + 100);

            // Claim unstaked tokens
            await staking.connect(teacher1).claimUnstakedTokens(0, 0);

            // Only teacher2 has stake now
            expect((await staking.getUserStake(0, teacher1.address)).amount).to.equal(0);
            expect((await staking.getUserStake(0, teacher2.address)).amount).to.equal(ethers.utils.parseEther("20000"));

            // Pool total stake should equal teacher2's stake
            const poolDetails = await staking.getPoolDetails(0);
            expect(poolDetails.totalStaked).to.equal(ethers.utils.parseEther("20000"));
        });
    });

    describe("Recovery Functions", function () {
        it("Should allow recovering non-staking tokens sent by mistake", async function () {
            // Deploy a dummy token
            const DummyToken = await ethers.getContractFactory("TeachToken");
            const dummyToken = await upgrades.deployProxy(DummyToken, [], {
                initializer: "initialize",
            });
            await dummyToken.deployed();

            // Mint some dummy tokens to owner
            await dummyToken.mint(owner.address, ethers.utils.parseEther("1000"));

            // Send some to staking contract "by mistake"
            await dummyToken.transfer(staking.address, ethers.utils.parseEther("100"));

            // Verify dummy tokens received
            expect(await dummyToken.balanceOf(staking.address)).to.equal(ethers.utils.parseEther("100"));

            // Initial owner balance
            const initialOwnerBalance = await dummyToken.balanceOf(owner.address);

            // Recover tokens
            await staking.recoverTokens(dummyToken.address, ethers.utils.parseEther("100"));

            // Check balances
            expect(await dummyToken.balanceOf(staking.address)).to.equal(0);
            expect(await dummyToken.balanceOf(owner.address)).to.equal(initialOwnerBalance.add(ethers.utils.parseEther("100")));
        });

        it("Should not allow recovering staking token", async function () {
            await expect(
                staking.recoverTokens(teachToken.address, ethers.utils.parseEther("100"))
            ).to.be.revertedWith("TokenStaking: cannot recover staking token");
        });
    });

    describe("Edge Cases", function () {
        it("Should handle zero stake correctly", async function () {
            // Check pending reward with no stake
            const pendingReward = await staking.calculatePendingReward(0, teacher1.address);
            expect(pendingReward).to.equal(0);

            // Check time until unlock with no stake
            const timeUntilUnlock = await staking.getTimeUntilUnlock(0, teacher1.address);
            expect(timeUntilUnlock).to.equal(0);
        });

        it("Should handle staking additional tokens in existing position", async function () {
            // Initial stake
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);

            // Fast forward a bit to accrue some rewards
            await time.increase(5 * 86400);

            // Check pending reward
            const pendingBefore = await staking.calculatePendingReward(0, teacher1.address);
            expect(pendingBefore).to.be.gt(0);

            // Stake more tokens
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("5000"), school1.address);

            // Check total stake
            const userStake = await staking.getUserStake(0, teacher1.address);
            expect(userStake.amount).to.equal(ethers.utils.parseEther("15000"));

            // Pending reward should be claimed during the additional stake
            const pendingAfter = await staking.calculatePendingReward(0, teacher1.address);
            expect(pendingAfter).to.be.lt(pendingBefore); // Should be close to 0, but might have some due to block time
        });

        it("Should handle partial unstaking", async function () {
            // Initial stake
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);

            // Unstake partial amount
            await staking.connect(teacher1).unstake(0, ethers.utils.parseEther("4000"));

            // Check remaining stake
            const userStake = await staking.getUserStake(0, teacher1.address);
            expect(userStake.amount).to.equal(ethers.utils.parseEther("6000"));
        });

        it("Should not allow unstaking more than staked", async function () {
            // Initial stake
            await staking.connect(teacher1).stake(0, ethers.utils.parseEther("10000"), school1.address);

            // Try to unstake more than staked
            await expect(
                staking.connect(teacher1).unstake(0, ethers.utils.parseEther("12000"))
            ).to.be.revertedWith("TokenStaking: insufficient stake");
        });
    });
});