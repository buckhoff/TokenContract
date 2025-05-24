describe("TokenStaking - Part 3: Advanced Features and Emergency Functions", function () {
    let tokenStaking;
    let mockToken;
    let mockRewardsPool;
    let mockGovernance;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const STAKING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("STAKING_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
    const SLASHER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SLASHER_ROLE"));

    beforeEach(async function () {
        [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockToken = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));

        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();

        const MockRewardsPool = await ethers.getContractFactory("MockRewardsPool");
        mockRewardsPool = await MockRewardsPool.deploy();

        const MockGovernance = await ethers.getContractFactory("MockGovernance");
        mockGovernance = await MockGovernance.deploy();

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
        await tokenStaking.grantRole(SLASHER_ROLE, admin.address);

        const TOKEN_STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));
        const GOVERNANCE_NAME = ethers.keccak256(ethers.toUtf8Bytes("GOVERNANCE"));

        await tokenStaking.setRegistry(await mockRegistry.getAddress(), TOKEN_STAKING_NAME);
        await mockRegistry.setContractAddress(TOKEN_STAKING_NAME, await tokenStaking.getAddress(), true);
        await mockRegistry.setContractAddress(GOVERNANCE_NAME, await mockGovernance.getAddress(), true);

        // Transfer tokens to users
        await mockToken.transfer(user1.address, ethers.parseEther("100000"));
        await mockToken.transfer(user2.address, ethers.parseEther("75000"));
        await mockToken.transfer(user3.address, ethers.parseEther("50000"));

        // Transfer tokens to rewards pool
        await mockToken.transfer(await mockRewardsPool.getAddress(), ethers.parseEther("2000000"));
    });

    describe("Governance Integration", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1500, // 15% APY
                180 * 24 * 60 * 60, // 180 days lock
                ethers.parseEther("5000"),
                ethers.parseEther("500000"),
                true
            );

            poolId = 1;

            const stakeAmount = ethers.parseEther("25000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);
            stakeId = 0;
        });

        it("should calculate voting power based on staked amount and duration", async function () {
            // Fast forward 90 days
            await ethers.provider.send("evm_increaseTime", [90 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const votingPower = await tokenStaking.calculateVotingPower(user1.address);

            // Voting power should be base stake + time multiplier
            expect(votingPower).to.be.gt(ethers.parseEther("25000"));
        });

        it("should create governance proposals for staking parameters", async function () {
            const proposalData = ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint256", "uint256"],
                [poolId, 2000] // Increase APY to 20%
            );

            const proposalId = await tokenStaking.connect(user1).createStakingProposal(
                "Increase Pool APY",
                "Proposal to increase staking pool APY from 15% to 20%",
                proposalData
            );

            expect(proposalId).to.be.gt(0);

            // Should be able to vote on the proposal
            await mockGovernance.setVotingPower(user1.address, ethers.parseEther("25000"));
            await mockGovernance.castVote(proposalId, 0); // Vote FOR
        });

        it("should delegate voting power while maintaining staking rewards", async function () {
            // User1 delegates voting power to user2
            await tokenStaking.connect(user1).delegateVotingPower(user2.address);

            expect(await tokenStaking.getDelegate(user1.address)).to.equal(user2.address);

            // User2 should receive delegated voting power
            const delegatedPower = await tokenStaking.getDelegatedVotingPower(user2.address);
            expect(delegatedPower).to.be.gt(0);

            // User1 should still earn staking rewards
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const pendingRewards = await tokenStaking.calculatePendingRewards(user1.address, stakeId);
            expect(pendingRewards).to.be.gt(0);
        });

        it("should handle governance-driven parameter changes", async function () {
            // Simulate governance proposal execution
            await tokenStaking.connect(admin).executeGovernanceProposal(
                poolId,
                "updateRewardRate",
                ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [1800]) // 18% APY
            );

            const updatedPool = await tokenStaking.getPoolInfo(poolId);
            expect(updatedPool.rewardRate).to.equal(1800);
        });
    });

    describe("Slashing Mechanisms", function () {
        let poolId, stakeId;

        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200,
                120 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("100000"),
                true
            );

            poolId = 1;

            // Enable slashing for this pool
            await tokenStaking.connect(admin).enableSlashing(poolId, 1000); // 10% max slash

            const stakeAmount = ethers.parseEther("20000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(poolId, stakeAmount);
            stakeId = 0;
        });

        it("should allow authorized slashing for governance violations", async function () {
            const originalStake = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;
            const slashPercentage = 500; // 5%

            const tx = await tokenStaking.connect(admin).slashStake(
                user1.address,
                stakeId,
                slashPercentage,
                "Governance violation"
            );

            await expect(tx).to.emit(tokenStaking, "StakeSlashed")
                .withArgs(user1.address, stakeId, originalStake * BigInt(slashPercentage) / BigInt(10000));

            const newStake = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;
            const expectedSlash = originalStake * BigInt(slashPercentage) / BigInt(10000);

            expect(newStake).to.equal(originalStake - expectedSlash);

            // Slashed tokens should go to treasury
            const slashedAmount = await tokenStaking.getTotalSlashed(user1.address);
            expect(slashedAmount).to.equal(expectedSlash);
        });

        it("should implement progressive slashing for repeat offenses", async function () {
            // First offense: 3%
            await tokenStaking.connect(admin).slashStake(user1.address, stakeId, 300, "First offense");

            // Second offense: 6% (doubled)
            await tokenStaking.connect(admin).slashStake(user1.address, stakeId, 600, "Second offense");

            const offenseHistory = await tokenStaking.getOffenseHistory(user1.address);
            expect(offenseHistory.offenseCount).to.equal(2);
            expect(offenseHistory.totalSlashed).to.be.gt(0);
        });

        it("should allow appeals for slashing decisions", async function () {
            await tokenStaking.connect(admin).slashStake(user1.address, stakeId, 500, "Disputed action");

            // User appeals the slashing
            const appealId = await tokenStaking.connect(user1).appealSlashing(
                stakeId,
                "This was an error, I did not violate governance rules"
            );

            expect(appealId).to.be.gt(0);

            // Admin can approve appeal
            await tokenStaking.connect(admin).approveSlashingAppeal(appealId);

            // Stake should be restored
            const restoredStake = (await tokenStaking.getUserStake(user1.address, stakeId)).amount;
            expect(restoredStake).to.equal(ethers.parseEther("20000")); // Back to original
        });

        it("should prevent slashing above maximum threshold", async function () {
            const maxSlash = 1000; // 10% set in beforeEach
            const excessiveSlash = 1500; // 15%

            await expect(
                tokenStaking.connect(admin).slashStake(user1.address, stakeId, excessiveSlash, "Excessive slash")
            ).to.be.revertedWith("Slash exceeds maximum allowed");
        });
    });

    describe("Emergency Functions", function () {
        beforeEach(async function () {
            // Create multiple pools and stakes for emergency testing
            await tokenStaking.connect(admin).createStakingPool(1000, 60 * 24 * 60 * 60, ethers.parseEther("500"), ethers.parseEther("25000"), true);
            await tokenStaking.connect(admin).createStakingPool(1500, 120 * 24 * 60 * 60, ethers.parseEther("2000"), ethers.parseEther("100000"), false);

            const stakes = [
                { user: user1, amount: ethers.parseEther("8000"), pool: 1 },
                { user: user2, amount: ethers.parseEther("15000"), pool: 2 },
                { user: user3, amount: ethers.parseEther("5000"), pool: 1 }
            ];

            for (const stake of stakes) {
                await mockToken.connect(stake.user).approve(await tokenStaking.getAddress(), stake.amount);
                await tokenStaking.connect(stake.user).stake(stake.pool, stake.amount);
            }
        });

        it("should allow emergency pause of all staking operations", async function () {
            await tokenStaking.connect(emergency).emergencyPause();

            expect(await tokenStaking.paused()).to.be.true;

            // All staking operations should be paused
            await expect(
                tokenStaking.connect(user1).claimRewards(0)
            ).to.be.revertedWith("Pausable: paused");

            const stakeAmount = ethers.parseEther("1000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            await expect(
                tokenStaking.connect(user1).stake(1, stakeAmount)
            ).to.be.revertedWith("Pausable: paused");
        });

        it("should allow emergency unstaking without penalties", async function () {
            // Enable emergency unstaking
            await tokenStaking.connect(emergency).enableEmergencyUnstaking();

            const originalStake = (await tokenStaking.getUserStake(user1.address, 0)).amount;
            const initialBalance = await mockToken.balanceOf(user1.address);

            await tokenStaking.connect(user1).emergencyUnstake(0);

            const finalBalance = await mockToken.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(originalStake); // No penalty

            // Stake should be cleared
            const clearedStake = (await tokenStaking.getUserStake(user1.address, 0)).amount;
            expect(clearedStake).to.equal(0);
        });

        it("should handle emergency reward distribution", async function () {
            // Simulate emergency where rewards need immediate distribution
            await ethers.provider.send("evm_increaseTime", [45 * 24 * 60 * 60]); // 45 days
            await ethers.provider.send("evm_mine");

            const users = [user1.address, user2.address, user3.address];
            const stakeIds = [0, 0, 0];

            await tokenStaking.connect(emergency).emergencyDistributeRewards(users, stakeIds);

            // All users should have received their rewards
            for (let i = 0; i < users.length; i++) {
                const pendingRewards = await tokenStaking.calculatePendingRewards(users[i], stakeIds[i]);
                expect(pendingRewards).to.equal(0); // Should be zero after distribution
            }
        });

        it("should allow emergency pool closure", async function () {
            const poolId = 1;

            await tokenStaking.connect(emergency).emergencyClosePool(poolId, "Security vulnerability found");

            const pool = await tokenStaking.getPoolInfo(poolId);
            expect(pool.isActive).to.be.false;

            // No new stakes should be allowed
            const stakeAmount = ethers.parseEther("1000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);

            await expect(
                tokenStaking.connect(user1).stake(poolId, stakeAmount)
            ).to.be.revertedWith("Pool not active");
        });
    });

    describe("Liquidation and Recovery", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                2000, // 20% APY
                365 * 24 * 60 * 60, // 1 year lock
                ethers.parseEther("10000"),
                ethers.parseEther("1000000"),
                true
            );

            const stakeAmount = ethers.parseEther("50000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(1, stakeAmount);
        });

        it("should handle forced liquidation for system health", async function () {
            // Set liquidation threshold
            await tokenStaking.connect(admin).setLiquidationThreshold(user1.address, ethers.parseEther("40000"));

            // Trigger liquidation
            await tokenStaking.connect(admin).forceLiquidation(
                user1.address,
                0,
                "System health preservation"
            );

            const liquidationEvent = await tokenStaking.getLiquidationEvent(user1.address, 0);
            expect(liquidationEvent.executed).to.be.true;
            expect(liquidationEvent.reason).to.include("System health");
        });

        it("should implement automatic liquidation triggers", async function () {
            // Set up automatic liquidation conditions
            await tokenStaking.connect(admin).setAutoLiquidationRules(
                ethers.parseEther("100000"), // Pool threshold
                5000 // 50% liquidation ratio
            );

            // Simulate condition that triggers auto-liquidation
            await tokenStaking.connect(admin).simulateSystemStress();

            const autoLiquidations = await tokenStaking.getAutoLiquidationCount();
            expect(autoLiquidations).to.be.gt(0);
        });

        it("should allow partial liquidation to maintain system stability", async function () {
            const partialAmount = ethers.parseEther("20000"); // 40% of stake

            await tokenStaking.connect(admin).partialLiquidation(
                user1.address,
                0,
                partialAmount,
                "Partial liquidation for stability"
            );

            const remainingStake = (await tokenStaking.getUserStake(user1.address, 0)).amount;
            expect(remainingStake).to.equal(ethers.parseEther("30000")); // 60% remaining
        });
    });

    describe("Advanced Pool Mechanics", function () {
        it("should implement dynamic pool caps", async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200,
                90 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("50000"), // Initial cap
                true
            );

            // Enable dynamic caps
            await tokenStaking.connect(admin).enableDynamicCaps(1);

            // High demand should increase cap
            for (let i = 0; i < 5; i++) {
                const stakeAmount = ethers.parseEther("10000");
                const user = [user1, user2, user3][i % 3];
                await mockToken.connect(user).approve(await tokenStaking.getAddress(), stakeAmount);
                await tokenStaking.connect(user).stake(1, stakeAmount);
            }

            const updatedPool = await tokenStaking.getPoolInfo(1);
            expect(updatedPool.maxStake).to.be.gt(ethers.parseEther("50000"));
        });

        it("should implement pool graduation mechanism", async function () {
            // Create starter pool
            await tokenStaking.connect(admin).createStakingPool(
                800, // Lower APY
                30 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("5000"),
                false
            );

            // Create advanced pool
            await tokenStaking.connect(admin).createStakingPool(
                1500, // Higher APY
                180 * 24 * 60 * 60,
                ethers.parseEther("5000"),
                ethers.parseEther("100000"),
                true
            );

            // Set graduation requirements
            await tokenStaking.connect(admin).setGraduationRequirements(
                1, // From pool 1
                2, // To pool 2
                90 * 24 * 60 * 60, // Minimum time
                ethers.parseEther("3000") // Minimum stake amount
            );

            // User stakes in starter pool
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), ethers.parseEther("4000"));
            await tokenStaking.connect(user1).stake(1, ethers.parseEther("4000"));

            // Fast forward
            await ethers.provider.send("evm_increaseTime", [95 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            // Should be eligible for graduation
            const eligible = await tokenStaking.isEligibleForGraduation(user1.address, 0);
            expect(eligible).to.be.true;

            // Graduate to advanced pool
            await tokenStaking.connect(user1).graduateToPool(0, 2);

            // Should now be in advanced pool with better terms
            const newStake = await tokenStaking.getUserStake(user1.address, 1); // New stake ID
            expect(newStake.poolId).to.equal(2);
        });
    });

    describe("Insurance and Protection Mechanisms", function () {
        beforeEach(async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1800,
                180 * 24 * 60 * 60,
                ethers.parseEther("5000"),
                ethers.parseEther("200000"),
                true
            );

            // Enable insurance fund
            await tokenStaking.connect(admin).setupInsuranceFund(ethers.parseEther("100000"));
        });

        it("should provide stake insurance against slashing", async function () {
            const stakeAmount = ethers.parseEther("30000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(1, stakeAmount);

            // Purchase insurance
            const insuranceFee = ethers.parseEther("300"); // 1% of stake
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), insuranceFee);
            await tokenStaking.connect(user1).purchaseStakeInsurance(0, 5000); // 50% coverage

            // Simulate slashing event
            await tokenStaking.connect(admin).slashStake(user1.address, 0, 1000, "Governance violation");

            // Insurance should cover part of the loss
            const insurancePayout = await tokenStaking.calculateInsurancePayout(user1.address, 0);
            expect(insurancePayout).to.be.gt(0);

            await tokenStaking.connect(user1).claimInsurance(0);

            // User should receive insurance compensation
            const compensation = await tokenStaking.getInsuranceCompensation(user1.address);
            expect(compensation).to.equal(insurancePayout);
        });

        it("should implement stake protection mechanisms", async function () {
            const stakeAmount = ethers.parseEther("25000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(1, stakeAmount);

            // Enable protection mode
            await tokenStaking.connect(user1).enableStakeProtection(0);

            // Set protection parameters
            await tokenStaking.connect(admin).setProtectionParameters(
                500, // 5% max loss before protection kicks in
                86400 // 24 hour cooldown
            );

            // Simulate market crash scenario
            await tokenStaking.connect(admin).simulateMarketCrash(3000); // 30% market drop

            // Protection should activate
            const protectionStatus = await tokenStaking.getProtectionStatus(user1.address, 0);
            expect(protectionStatus.active).to.be.true;
            expect(protectionStatus.protectedAmount).to.be.gt(0);
        });
    });

    describe("Cross-Chain Staking Features", function () {
        it("should support cross-chain stake bridging", async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1400,
                120 * 24 * 60 * 60,
                ethers.parseEther("2000"),
                ethers.parseEther("150000"),
                true
            );

            const stakeAmount = ethers.parseEther("20000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), stakeAmount);
            await tokenStaking.connect(user1).stake(1, stakeAmount);

            // Setup cross-chain bridge
            await tokenStaking.connect(admin).setupCrossChainBridge(
                "Ethereum", // Target chain
                "0x1234567890123456789012345678901234567890" // Bridge address
            );

            // Bridge stake to another chain
            const bridgeId = await tokenStaking.connect(user1).bridgeStakeToChain(
                0, // Stake ID
                "Ethereum",
                ethers.parseEther("10000") // Amount to bridge
            );

            expect(bridgeId).to.be.gt(0);

            const bridgeInfo = await tokenStaking.getBridgeInfo(bridgeId);
            expect(bridgeInfo.sourceStakeId).to.equal(0);
            expect(bridgeInfo.targetChain).to.equal("Ethereum");
            expect(bridgeInfo.amount).to.equal(ethers.parseEther("10000"));
        });

        it("should handle cross-chain reward synchronization", async function () {
            // Setup reward sync between chains
            await tokenStaking.connect(admin).enableCrossChainRewardSync(
                ["Ethereum", "BSC", "Polygon"],
                3600 // 1 hour sync interval
            );

            // Simulate rewards from multiple chains
            await tokenStaking.connect(admin).syncCrossChainRewards(
                user1.address,
                [
                    { chain: "Ethereum", amount: ethers.parseEther("500") },
                    { chain: "BSC", amount: ethers.parseEther("300") },
                    { chain: "Polygon", amount: ethers.parseEther("200") }
                ]
            );

            const totalCrossChainRewards = await tokenStaking.getCrossChainRewards(user1.address);
            expect(totalCrossChainRewards).to.equal(ethers.parseEther("1000"));
        });
    });

    describe("Advanced Analytics and Reporting", function () {
        beforeEach(async function () {
            // Create multiple pools and stakes for analytics
            await tokenStaking.connect(admin).createStakingPool(1000, 60 * 24 * 60 * 60, ethers.parseEther("500"), ethers.parseEther("25000"), true);
            await tokenStaking.connect(admin).createStakingPool(1500, 120 * 24 * 60 * 60, ethers.parseEther("2000"), ethers.parseEther("100000"), false);

            const stakes = [
                { user: user1, amount: ethers.parseEther("8000"), pool: 1 },
                { user: user2, amount: ethers.parseEther("15000"), pool: 2 },
                { user: user3, amount: ethers.parseEther("6000"), pool: 1 }
            ];

            for (const stake of stakes) {
                await mockToken.connect(stake.user).approve(await tokenStaking.getAddress(), stake.amount);
                await tokenStaking.connect(stake.user).stake(stake.pool, stake.amount);
            }

            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
        });

        it("should provide comprehensive staking analytics", async function () {
            const analytics = await tokenStaking.getStakingAnalytics();

            expect(analytics.totalValueLocked).to.equal(ethers.parseEther("29000"));
            expect(analytics.activeStakers).to.equal(3);
            expect(analytics.averageStakeDuration).to.be.gt(0);
            expect(analytics.totalRewardsDistributed).to.be.gt(0);
        });

        it("should calculate risk metrics", async function () {
            const riskMetrics = await tokenStaking.calculateRiskMetrics();

            expect(riskMetrics.concentrationRisk).to.be.gte(0);
            expect(riskMetrics.liquidityRisk).to.be.gte(0);
            expect(riskMetrics.slashingRisk).to.be.gte(0);
            expect(riskMetrics.overallRiskScore).to.be.gte(0);
        });

        it("should generate performance reports", async function () {
            const report = await tokenStaking.generatePerformanceReport(
                1, // Pool ID
                30 * 24 * 60 * 60 // Last 30 days
            );

            expect(report.averageAPY).to.be.gt(0);
            expect(report.totalStaked).to.equal(ethers.parseEther("14000")); // user1 + user3
            expect(report.rewardEfficiency).to.be.gt(0);
            expect(report.userRetention).to.be.gt(0);
        });
    });

    describe("System Resilience and Recovery", function () {
        it("should handle oracle failures gracefully", async function () {
            // Simulate oracle failure
            await tokenStaking.connect(admin).simulateOracleFailure();

            // System should switch to fallback mechanisms
            const fallbackMode = await tokenStaking.isFallbackModeActive();
            expect(fallbackMode).to.be.true;

            // Basic operations should still work
            await tokenStaking.connect(admin).createStakingPool(
                1000,
                60 * 24 * 60 * 60,
                ethers.parseEther("100"),
                ethers.parseEther("10000"),
                false
            );

            const poolCount = await tokenStaking.getPoolCount();
            expect(poolCount).to.be.gt(0);
        });

        it("should implement circuit breakers for system protection", async function () {
            await tokenStaking.connect(admin).createStakingPool(
                1200,
                90 * 24 * 60 * 60,
                ethers.parseEther("1000"),
                ethers.parseEther("50000"),
                true
            );

            // Set circuit breaker thresholds
            await tokenStaking.connect(admin).setCircuitBreakerThresholds(
                ethers.parseEther("100000"), // Max stake per block
                1000, // Max stakers per block
                ethers.parseEther("50000") // Max rewards per block
            );

            // Attempt to trigger circuit breaker with massive stake
            const massiveStake = ethers.parseEther("200000");
            await mockToken.connect(user1).approve(await tokenStaking.getAddress(), massiveStake);

            await expect(
                tokenStaking.connectconst { expect } = require("chai");
            const { ethers, upgrades } = require("hardhat");

            describe("TokenStaking - Part 3: Advanced Features and Emergency Functions", function () {
                let tokenStaking;
                let mockToken;
                let mockRewardsPool;
                let mockGovernance;
                let mockRegistry;
                let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

                const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
                const STAKING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("STAKING_MANAGER_ROLE"));
                const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
                const SLASHER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SLASHER_ROLE"));

                beforeEach(async function () {
                    [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

                    const MockERC20 = await ethers.getContractFactory("MockERC20");
                    mockToken = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));

                    const MockRegistry = await ethers.getContractFactory("MockRegistry");
                    mockRegistry = await MockRegistry.deploy();

                    const MockRewardsPool = await ethers.getContractFactory("MockRewardsPool");
                    mockRewardsPool = await MockRewardsPool.deploy();

                    const MockGovernance = await ethers.getContractFactory("MockGovernance");
                    mockGovernance = await MockGovernance.deploy();

                    const TokenStaking = await ethers.getContractFactory("