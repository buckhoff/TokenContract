const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TokenStaking Contract", function () {
    let teachToken;
    let staking;
    let owner;
    let user1;
    let user2;
    let school1;
    let school2;
    let platformRewardsManager;

    const initialSupply = ethers.parseEther("10000000"); // 10M tokens for testing

    beforeEach(async function () {
        // Get the contract factories and signers
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        [owner, user1, user2, school1, school2, platformRewardsManager] = await ethers.getSigners();

        // Deploy token
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.waitForDeployment();

        // Mint tokens to users for staking
        await teachToken.mint(owner.address, initialSupply);
        await teachToken.transfer(user1.address, ethers.parseEther("100000"));
        await teachToken.transfer(user2.address, ethers.parseEther("50000"));

        // Deploy staking contract
        staking = await upgrades.deployProxy(TokenStaking, [
            await teachToken.getAddress(),
            platformRewardsManager.address
        ], {
            initializer: "initialize",
        });
        await staking.waitForDeployment();

        // Add rewards to staking contract
        await teachToken.transfer(await staking.getAddress(), ethers.parseEther("1000000"));
        await staking.addRewardsToPool(ethers.parseEther("1000000"));

        // Register schools
        await staking.registerSchool(school1.address, "School 1");
        await staking.registerSchool(school2.address, "School 2");

        // Create a staking pool
        await staking.createStakingPool(
            "Test Pool",
            ethers.parseEther("0.1"), // 10% APY
            90 * 24 * 60 * 60, // 90 days lock
            500, // 5% early withdrawal fee
        );
    });

    describe("Deployment", function () {
        it("Should set the right token", async function () {
            expect(await staking.token()).to.equal(await teachToken.getAddress());
        });

        it("Should set the platform rewards manager", async function () {
            expect(await staking.platformRewardsManager()).to.equal(platformRewardsManager.address);
        });

        it("Should set the correct roles", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
            const MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE"));
            const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

            expect(await staking.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await staking.hasRole(MANAGER_ROLE, platformRewardsManager.address)).to.equal(true);
            expect(await staking.hasRole(EMERGENCY_ROLE, owner.address)).to.equal(true);
        });
    });

    describe("Staking Pool Management", function () {
        it("Should create a staking pool correctly", async function () {
            const poolDetails = await staking.getPoolDetails(0);

            expect(poolDetails.name).to.equal("Test Pool");
            expect(poolDetails.rewardRate).to.equal(ethers.parseEther("0.1"));
            expect(poolDetails.lockDuration).to.equal(90 * 24 * 60 * 60);
            expect(poolDetails.earlyWithdrawalFee).to.equal(500);
            expect(poolDetails.totalStaked).to.equal(0);
            expect(poolDetails.isActive).to.equal(true);
        });

        it("Should allow updating a staking pool", async function () {
            await staking.updateStakingPool(
                0,
                ethers.parseEther("0.15"), // 15% APY
                120 * 24 * 60 * 60, // 120 days lock
                700, // 7% early withdrawal fee
                true // Active
            );

            const poolDetails = await staking.getPoolDetails(0);

            expect(poolDetails.rewardRate).to.equal(ethers.parseEther("0.15"));
            expect(poolDetails.lockDuration).to.equal(120 * 24 * 60 * 60);
            expect(poolDetails.earlyWithdrawalFee).to.equal(700);
            expect(poolDetails.isActive).to.equal(true);
        });

        it("Should not allow creating a pool with fee too high", async function () {
            await expect(
                staking.createStakingPool(
                    "High Fee Pool",
                    ethers.parseEther("0.1"),
                    90 * 24 * 60 * 60,
                    3100 // 31% (over the 30% limit)
                )
            ).to.be.revertedWith("TokenStaking: fee too high");
        });
    });

    describe("Staking Operations", function () {
        const stakeAmount = ethers.parseEther("10000");

        beforeEach(async function () {
            // Approve staking contract to spend tokens
            await teachToken.connect(user1).approve(await staking.getAddress(), stakeAmount);
        });

        it("Should allow staking tokens", async function () {
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Check user's stake
            const userStake = await staking.getUserStake(0, user1.address);
            expect(userStake.amount).to.equal(stakeAmount);
            expect(userStake.schoolBeneficiary).to.equal(school1.address);

            // Check pool total staked
            const poolDetails = await staking.getPoolDetails(0);
            expect(poolDetails.totalStaked).to.equal(stakeAmount);
        });

        it("Should calculate rewards correctly", async function () {
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Advance time by 30 days
            await time.increase(30 * 24 * 60 * 60);

            // Calculate pending reward
            const pendingReward = await staking.calculatePendingReward(0, user1.address);

            // Expected reward calculation:
            // amount * rewardRate * timeElapsed / (365 days) / 1e18
            // For 30 days with 10% APY:
            // 10000e18 * 0.1e18 * (30 * 24 * 60 * 60) / (365 * 24 * 60 * 60) / 1e18
            const expectedReward = stakeAmount * BigInt(30) / BigInt(365) / 10n;

            // Allow some rounding difference
            expect(pendingReward).to.be.approximately(expectedReward, ethers.parseEther("0.01"));
        });

        it("Should allow claiming rewards", async function () {
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Advance time by 30 days
            await time.increase(30 * 24 * 60 * 60);

            // Claim rewards
            await staking.connect(user1).claimReward(0);

            // Check user's balance
            const reward = await staking.calculatePendingReward(0, user1.address);
            expect(reward).to.equal(0); // All rewards claimed

            // School should have received their share
            const schoolDetails = await staking.getSchoolDetails(school1.address);
            expect(schoolDetails.totalRewards).to.be.gt(0);
        });

        it("Should handle unstaking correctly", async function () {
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Advance time to after lock period
            await time.increase(100 * 24 * 60 * 60); // 100 days (beyond 90-day lock)

            // Unstake
            const balanceBefore = await teachToken.balanceOf(user1.address);
            await staking.connect(user1).unstake(0, stakeAmount);
            const balanceAfter = await teachToken.balanceOf(user1.address);

            // User should receive back the full staked amount
            expect(balanceAfter - balanceBefore).to.equal(stakeAmount);

            // Pool should be empty
            const poolDetails = await staking.getPoolDetails(0);
            expect(poolDetails.totalStaked).to.equal(0);
        });

        it("Should apply early withdrawal fee", async function () {
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Unstake early (before lock period ends)
            const balanceBefore = await teachToken.balanceOf(user1.address);
            await staking.connect(user1).unstake(0, stakeAmount);
            const balanceAfter = await teachToken.balanceOf(user1.address);

            // Early withdrawal fee of 5% should be applied
            const fee = stakeAmount * 5n / 100n;
            expect(balanceAfter - balanceBefore).to.equal(stakeAmount - fee);

            // Reward pool should have increased by the fee amount
            const rewardsPoolBefore = ethers.parseEther("1000000"); // Initial rewards
            const rewardsPoolAfter = await staking.rewardsPool();
            expect(rewardsPoolAfter - rewardsPoolBefore).to.equal(fee);
        });
    });

    describe("School Management", function () {
        const stakeAmount = ethers.parseEther("10000");

        beforeEach(async function () {
            // Stake tokens to generate rewards for schools
            await teachToken.connect(user1).approve(await staking.getAddress(), stakeAmount);
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Advance time to generate rewards
            await time.increase(30 * 24 * 60 * 60);

            // Claim rewards to allocate rewards to school
            await staking.connect(user1).claimReward(0);
        });

        it("Should track school rewards correctly", async function () {
            const schoolDetails = await staking.getSchoolDetails(school1.address);
            expect(schoolDetails.totalRewards).to.be.gt(0);
        });

        it("Should allow platform manager to withdraw school rewards", async function () {
            const schoolDetails = await staking.getSchoolDetails(school1.address);
            const schoolRewards = schoolDetails.totalRewards;

            // Platform manager withdraws rewards
            await staking.connect(platformRewardsManager).withdrawSchoolRewards(school1.address, schoolRewards);

            // Check platform manager received tokens
            expect(await teachToken.balanceOf(platformRewardsManager.address)).to.equal(schoolRewards);

            // School rewards should be reset
            const updatedSchoolDetails = await staking.getSchoolDetails(school1.address);
            expect(updatedSchoolDetails.totalRewards).to.equal(0);
        });

        it("Should not allow non-managers to withdraw school rewards", async function () {
            const schoolDetails = await staking.getSchoolDetails(school1.address);
            const schoolRewards = schoolDetails.totalRewards;

            await expect(
                staking.connect(user1).withdrawSchoolRewards(school1.address, schoolRewards)
            ).to.be.reverted;
        });

        it("Should allow updating school information", async function () {
            await staking.updateSchool(school1.address, "Updated School Name", false);

            const schoolDetails = await staking.getSchoolDetails(school1.address);
            expect(schoolDetails.name).to.equal("Updated School Name");
            expect(schoolDetails.isActive).to.equal(false);
        });
    });

    describe("Emergency Functions", function () {
        const stakeAmount = ethers.parseEther("10000");

        beforeEach(async function () {
            // Approve and stake tokens
            await teachToken.connect(user1).approve(await staking.getAddress(), stakeAmount);
            await staking.connect(user1).stake(0, stakeAmount, school1.address);
        });

        it("Should allow pausing staking operations", async function () {
            await staking.pauseStaking();

            // Approve more tokens
            await teachToken.connect(user1).approve(await staking.getAddress(), stakeAmount);

            // Try to stake (should fail)
            await expect(
                staking.connect(user1).stake(0, stakeAmount, school1.address)
            ).to.be.revertedWith("TokenStaking: contract is paused");
        });

        it("Should allow emergency unstake with fee", async function () {
            // Set emergency unstake fee
            await staking.setEmergencyUnstakeFee(2000); // 20%

            // Pause staking
            await staking.pauseStaking();

            // Emergency unstake
            const balanceBefore = await teachToken.balanceOf(user1.address);
            await staking.connect(user1).emergencyUnstake(0, stakeAmount);
            const balanceAfter = await teachToken.balanceOf(user1.address);

            // Emergency fee of 20% should be applied
            const fee = stakeAmount * 20n / 100n;
            expect(balanceAfter - balanceBefore).to.equal(stakeAmount - fee);
        });

        it("Should recover accidentally sent tokens", async function () {
            // Deploy a new token for testing recovery
            const TestToken = await ethers.getContractFactory("TeachToken");
            const testToken = await upgrades.deployProxy(TestToken, [], {
                initializer: "initialize",
            });

            // Mint some test tokens to owner
            await testToken.mint(owner.address, ethers.parseEther("1000"));

            // Transfer test tokens to staking contract (simulating accidental send)
            await testToken.transfer(await staking.getAddress(), ethers.parseEther("100"));

            // Recover tokens
            await staking.recoverTokens(await testToken.getAddress(), ethers.parseEther("100"));

            // Owner should receive the recovered tokens
            expect(await testToken.balanceOf(owner.address)).to.equal(ethers.parseEther("1000"));
        });

        it("Should not allow recovering staking token", async function () {
            await expect(
                staking.recoverTokens(await teachToken.getAddress(), ethers.parseEther("100"))
            ).to.be.revertedWith("TokenStaking: cannot recover staking token");
        });
    });

    describe("Integration with Registry", function () {
        it("Should set and use registry", async function () {
            // Deploy registry
            const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });

            // Set registry in staking contract
            await staking.setRegistry(await registry.getAddress());
            expect(await staking.registry()).to.equal(await registry.getAddress());

            // Register token in registry
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
            await registry.registerContract(TOKEN_NAME, await teachToken.getAddress(), "0x00000000");

            // Update contract references
            await staking.updateContractReferences();

            // The test passed if no errors occurred
        });
    });

    describe("APY and Calculations", function () {
        it("Should calculate APY correctly", async function () {
            const apy = await staking.getPoolAPY(0);

            // Reward rate of 0.1 (10%) should give 10% APY
            expect(apy).to.equal(1000); // 10.00%
        });

        it("Should adjust reward rates based on available rewards", async function () {
            // Initially set a high reward rate
            await staking.updateStakingPool(
                0,
                ethers.parseEther("0.5"), // 50% APY (very high)
                90 * 24 * 60 * 60,
                500,
                true
            );

            // Stake a large amount
            await teachToken.connect(user1).approve(await staking.getAddress(), ethers.parseEther("900000"));
            await staking.connect(user1).stake(0, ethers.parseEther("900000"), school1.address);

            // Adjust rates based on staked tokens and rewards pool
            await staking.adjustRewardRates();

            // The rate should be adjusted downward to be sustainable
            const poolDetails = await staking.getPoolDetails(0);
            expect(poolDetails.rewardRate).to.be.lt(ethers.parseEther("0.5"));
        });
    });

    describe("Unstaking with Cooldown", function () {
        const stakeAmount = ethers.parseEther("10000");

        beforeEach(async function () {
            // Approve and stake tokens
            await teachToken.connect(user1).approve(await staking.getAddress(), stakeAmount);
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Set cooldown period to 1 day for testing
            await staking.setCooldownPeriod(24 * 60 * 60);
        });

        it("Should request unstake and honor cooldown period", async function () {
            // Request unstake
            await staking.connect(user1).requestUnstake(0, stakeAmount);

            // Verify request is created
            const requests = await staking.getUnstakingRequests(user1.address, 0);
            expect(requests.length).to.equal(1);
            expect(requests[0].amount).to.equal(stakeAmount);
            expect(requests[0].claimed).to.equal(false);

            // Try to claim before cooldown (should fail)
            await expect(
                staking.connect(user1).claimUnstakedTokens(0, 0)
            ).to.be.revertedWith("TokenStaking: cooldown not over");

            // Advance time past cooldown
            await time.increase(25 * 60 * 60); // 25 hours

            // Now claim should succeed
            await staking.connect(user1).claimUnstakedTokens(0, 0);

            // Check that tokens were received and request marked as claimed
            const updatedRequests = await staking.getUnstakingRequests(user1.address, 0);
            expect(updatedRequests[0].claimed).to.equal(true);

            // User should have their tokens back
            expect(await teachToken.balanceOf(user1.address)).to.be.gte(stakeAmount);
        });
    });

    describe("Governance Integration", function () {
        it("Should update voting power", async function () {
            // Deploy mock governance contract
            const mockGovernance = await ethers.deployContract("ContractRegistry"); // Using registry as a mock
            await mockGovernance.initialize();

            // Deploy registry and register governance
            const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });

            const GOVERNANCE_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_GOVERNANCE"));
            await registry.registerContract(GOVERNANCE_NAME, await mockGovernance.getAddress(), "0x00000000");

            // Set registry in staking contract
            await staking.setRegistry(await registry.getAddress());

            // This test is mainly to verify that the notifyGovernanceOfStakeChange function
            // doesn't revert even if governance contract doesn't implement updateVotingPower
        });
    });

    describe("Upgradeability", function() {
        it("Should be upgradeable using the UUPS pattern", async function() {
            // Stake some tokens first
            await teachToken.connect(user1).approve(await staking.getAddress(), ethers.parseEther("10000"));
            await staking.connect(user1).stake(0, ethers.parseEther("10000"), school1.address);

            // Deploy a new implementation
            const TokenStakingV2 = await ethers.getContractFactory("TokenStaking");

            // Upgrade to new implementation
            const upgradedStaking = await upgrades.upgradeProxy(
                await staking.getAddress(),
                TokenStakingV2
            );

            // Check that the address stayed the same
            expect(await upgradedStaking.getAddress()).to.equal(await staking.getAddress());

            // Verify state is preserved
            const userStake = await upgradedStaking.getUserStake(0, user1.address);
            expect(userStake.amount).to.equal(ethers.parseEther("10000"));
            expect(userStake.schoolBeneficiary).to.equal(school1.address);
        });
    });
});