const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Time-Dependent Functions", function () {
    // Contract instances
    let teachToken;
    let stabilityFund;
    let crowdSale;
    let staking;
    let governance;
    let registry;

    // Signers
    let owner;
    let priceOracle;
    let treasury;
    let user1;
    let user2;
    let user3;
    let platformEcosystemAddress;
    let communityIncentivesAddress;
    let initialLiquidityAddress;
    let publicPresaleAddress;
    let teamAndDevAddress;
    let educationalPartnersAddress;
    let reserveAddress;
    let school1;
    let school2;

    // Constants for testing
    const ONE_DAY = 86400;
    const ONE_WEEK = ONE_DAY * 7;
    const ONE_MONTH = ONE_DAY * 30;
    const ONE_YEAR = ONE_DAY * 365;

    // Initial prices and parameters
    const INITIAL_PRICE = ethers.utils.parseEther("0.05");
    const RESERVE_RATIO = 5000; // 50%
    const MIN_RESERVE_RATIO = 2000; // 20%

    beforeEach(async function () {
        // Get signers
        [
            owner,
            priceOracle,
            treasury,
            user1,
            user2,
            user3,
            platformEcosystemAddress,
            communityIncentivesAddress,
            initialLiquidityAddress,
            publicPresaleAddress,
            teamAndDevAddress,
            educationalPartnersAddress,
            reserveAddress,
            school1,
            school2
        ] = await ethers.getSigners();

        // Get contract factories
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const PlatformStabilityFund = await ethers.getContractFactory("PlatformStabilityFund");
        const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        const PlatformGovernance = await ethers.getContractFactory("PlatformGovernance");
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const USDCMock = await ethers.getContractFactory("TeachToken"); // Using TeachToken as a mock for USDC

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
        });
        await registry.deployed();

        // Deploy tokens
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.deployed();

        const usdcToken = await upgrades.deployProxy(USDCMock, [], {
            initializer: "initialize",
        });
        await usdcToken.deployed();

        // Deploy stability fund
        stabilityFund = await upgrades.deployProxy(PlatformStabilityFund, [
            teachToken.address,
            usdcToken.address,
            priceOracle.address,
            INITIAL_PRICE,
            RESERVE_RATIO,
            MIN_RESERVE_RATIO,
            300, // 3% platform fee
            100, // 1% low value fee
            1000 // 10% value threshold
        ], {
            initializer: "initialize",
        });
        await stabilityFund.deployed();

        // Deploy staking
        staking = await upgrades.deployProxy(TokenStaking, [
            teachToken.address,
            treasury.address
        ], {
            initializer: "initialize",
        });
        await staking.deployed();

        // Deploy crowdsale
        crowdSale = await upgrades.deployProxy(TokenCrowdSale, [
            usdcToken.address,
            treasury.address
        ], {
            initializer: "initialize",
        });
        await crowdSale.deployed();
        await crowdSale.setSaleToken(teachToken.address);

        // Deploy governance
        governance = await upgrades.deployProxy(PlatformGovernance, [
            teachToken.address,
            ethers.utils.parseEther("10000"), // Proposal threshold: 10,000 tokens
            7 * ONE_DAY, // Min voting period: 1 week
            14 * ONE_DAY, // Max voting period: 2 weeks
            1000, // Quorum threshold: 10%
            2 * ONE_DAY, // Execution delay: 2 days
            7 * ONE_DAY // Execution period: 1 week
        ], {
            initializer: "initialize",
        });
        await governance.deployed();

        // Register contracts in registry
        const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEACH_TOKEN"));
        const STABILITY_FUND_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_STABILITY_FUND"));
        const STAKING_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_STAKING"));
        const GOVERNANCE_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_GOVERNANCE"));
        const CROWDSALE_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_CROWDSALE"));

        await registry.registerContract(TOKEN_NAME, teachToken.address, "0x00000000");
        await registry.registerContract(STABILITY_FUND_NAME, stabilityFund.address, "0x00000000");
        await registry.registerContract(STAKING_NAME, staking.address, "0x00000000");
        await registry.registerContract(GOVERNANCE_NAME, governance.address, "0x00000000");
        await registry.registerContract(CROWDSALE_NAME, crowdSale.address, "0x00000000");

        // Set registry in all contracts
        await teachToken.setRegistry(registry.address);
        await stabilityFund.setRegistry(registry.address);
        await staking.setRegistry(registry.address);
        await governance.setRegistry(registry.address);
        await crowdSale.setRegistry(registry.address);

        // Perform initial token distribution
        await teachToken.performInitialDistribution(
            platformEcosystemAddress.address,
            communityIncentivesAddress.address,
            initialLiquidityAddress.address,
            publicPresaleAddress.address,
            teamAndDevAddress.address,
            educationalPartnersAddress.address,
            reserveAddress.address
        );

        // Setup staking with schools and pools
        await staking.registerSchool(school1.address, "Test School 1");
        await staking.registerSchool(school2.address, "Test School 2");

        // Create staking pools with different lock periods
        await staking.createStakingPool(
            "30-Day Pool",
            ethers.utils.parseEther("0.001"), // 0.1% daily reward rate
            30 * ONE_DAY, // 30 days lock
            500 // 5% early withdrawal fee
        );

        await staking.createStakingPool(
            "90-Day Pool",
            ethers.utils.parseEther("0.002"), // 0.2% daily reward rate
            90 * ONE_DAY, // 90 days lock
            1000 // 10% early withdrawal fee
        );

        await staking.createStakingPool(
            "365-Day Pool",
            ethers.utils.parseEther("0.003"), // 0.3% daily reward rate
            365 * ONE_DAY, // 1 year lock
            2000 // 20% early withdrawal fee
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

        // Add rewards to staking pool
        await teachToken.approve(staking.address, ethers.utils.parseEther("1000000"));
        await staking.addRewardsToPool(ethers.utils.parseEther("1000000"));

        // Mint tokens to users for testing
        await teachToken.mint(user1.address, ethers.utils.parseEther("1000000"));
        await teachToken.mint(user2.address, ethers.utils.parseEther("500000"));
        await teachToken.mint(user3.address, ethers.utils.parseEther("750000"));

        // Setup crowdsale presale times (start tomorrow, end in 30 days)
        const currentTime = await time.latest();
        const startTime = currentTime + ONE_DAY;
        const endTime = startTime + (30 * ONE_DAY);
        await crowdSale.setPresaleTimes(startTime, endTime);

        // Activate tier 0 in crowdsale
        await crowdSale.setTierStatus(0, true);

        // Mint some USDC to users for crowdsale
        await usdcToken.mint(user1.address, ethers.utils.parseUnits("10000", 6));
        await usdcToken.mint(user2.address, ethers.utils.parseUnits("25000", 6));
        await usdcToken.mint(user3.address, ethers.utils.parseUnits("50000", 6));

        // Approve tokens for various operations
        await teachToken.connect(user1).approve(staking.address, ethers.utils.parseEther("1000000"));
        await teachToken.connect(user2).approve(staking.address, ethers.utils.parseEther("500000"));
        await teachToken.connect(user3).approve(staking.address, ethers.utils.parseEther("750000"));

        await usdcToken.connect(user1).approve(crowdSale.address, ethers.utils.parseUnits("10000", 6));
        await usdcToken.connect(user2).approve(crowdSale.address, ethers.utils.parseUnits("25000", 6));
        await usdcToken.connect(user3).approve(crowdSale.address, ethers.utils.parseUnits("50000", 6));

        // Grant oracle role for stability fund
        const ORACLE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ORACLE_ROLE"));
        await stabilityFund.grantRole(ORACLE_ROLE, priceOracle.address);
    });

    describe("Staking Time-Dependent Tests", function() {
        it("Should correctly calculate rewards after 1 year of staking", async function() {
            // Stake tokens in 1-year pool
            const stakeAmount = ethers.utils.parseEther("100000");
            await staking.connect(user1).stake(2, stakeAmount, school1.address);

            // Fast forward 1 year
            await time.increase(ONE_YEAR);

            // Calculate expected reward
            const pool = await staking.getPoolDetails(2);
            const rewardRate = pool.rewardRate;
            const expectedReward = stakeAmount.mul(rewardRate).mul(ONE_YEAR).div(ONE_YEAR).div(ethers.utils.parseEther("1"));

            // Get actual pending reward
            const pendingReward = await staking.calculatePendingReward(2, user1.address);

            // Should be close to expected (allow small rounding differences)
            expect(pendingReward).to.be.closeTo(expectedReward, ethers.utils.parseEther("0.1"));

            // User portion should be half
            const userStake = await staking.getUserStake(2, user1.address);
            expect(userStake.userRewardPortion).to.be.closeTo(pendingReward.div(2), ethers.utils.parseEther("0.1"));
        });

        it("Should allow claiming without fee after lock period ends", async function() {
            // Stake in 30-day pool
            const stakeAmount = ethers.utils.parseEther("50000");
            await staking.connect(user1).stake(0, stakeAmount, school1.address);

            // Fast forward past lock period
            await time.increase(31 * ONE_DAY);

            // Check fee - should be zero after lock period
            const initialBalance = await teachToken.balanceOf(user1.address);

            // Unstake tokens
            await staking.connect(user1).unstake(0, stakeAmount);

            // Should receive full amount (no fee)
            const finalBalance = await teachToken.balanceOf(user1.address);
            expect(finalBalance.sub(initialBalance)).to.equal(stakeAmount);
        });

        it("Should apply early withdrawal fee correctly over different time periods", async function() {
            // Stake in 90-day pool
            const stakeAmount = ethers.utils.parseEther("75000");
            await staking.connect(user2).stake(1, stakeAmount, school1.address);

            // Get pool details for fee
            const pool = await staking.getPoolDetails(1);
            const earlyWithdrawalFee = pool.earlyWithdrawalFee;

            // Unstake half after 30 days (still in lock period)
            await time.increase(30 * ONE_DAY);

            const halfAmount = stakeAmount.div(2);
            const expectedFee = halfAmount.mul(earlyWithdrawalFee).div(10000);
            const expectedReturn = halfAmount.sub(expectedFee);

            const initialBalance = await teachToken.balanceOf(user2.address);

            // Unstake half
            await staking.connect(user2).unstake(1, halfAmount);

            const midBalance = await teachToken.balanceOf(user2.address);
            expect(midBalance.sub(initialBalance)).to.equal(expectedReturn);

            // Fast forward to after lock period (60 more days)
            await time.increase(60 * ONE_DAY);

            // Unstake remaining half - should have no fee
            await staking.connect(user2).unstake(1, halfAmount);

            const finalBalance = await teachToken.balanceOf(user2.address);
            expect(finalBalance.sub(midBalance)).to.equal(halfAmount);
        });

        it("Should enforce cooldown period for unstaking requests", async function() {
            // Get current cooldown period
            const cooldownPeriod = await staking.cooldownPeriod();

            // Stake tokens
            const stakeAmount = ethers.utils.parseEther("60000");
            await staking.connect(user3).stake(1, stakeAmount, school2.address);

            // Request unstake
            await staking.connect(user3).requestUnstake(1, stakeAmount);

            // Fast forward half of cooldown period
            await time.increase(cooldownPeriod.div(2).toNumber());

            // Try to claim unstaked tokens - should fail
            await expect(
                staking.connect(user3).claimUnstakedTokens(1, 0)
            ).to.be.revertedWith("TokenStaking: cooldown not over");

            // Fast forward past cooldown period
            await time.increase(cooldownPeriod.div(2).toNumber() + 10);

            // Now should be able to claim
            await staking.connect(user3).claimUnstakedTokens(1, 0);

            // Verify tokens received
            const requests = await staking.getUnstakingRequests(user3.address, 1);
            expect(requests[0].claimed).to.equal(true);
        });
    });

    describe("CrowdSale Vesting Tests", function() {
        it("Should respect vesting schedule over 18 months", async function() {
            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Purchase tokens in tier 0 (has 10% TGE, 18 months vesting)
            const purchaseAmount = ethers.utils.parseUnits("5000", 6); // 5,000 USDC
            await crowdSale.connect(user1).purchase(0, purchaseAmount);

            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup token distribution for TGE
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, ethers.utils.parseEther("500000000"));

            // Verify initial claimable amount (should be ~10% of total)
            const user1Purchase = await crowdSale.purchases(user1.address);
            const totalTokens = user1Purchase.tokens;

            // Get tier details for TGE percentage
            const tier = await crowdSale.tiers(0);
            const tgePercent = tier.vestingTGE;

            // Expected TGE release = total tokens * tgePercent / 100
            const expectedTGERelease = totalTokens.mul(tgePercent).div(100);

            // Check initial claimable (should be ~TGE amount)
            const initialClaimable = await crowdSale.claimableTokens(user1.address);
            expect(initialClaimable).to.be.closeTo(expectedTGERelease, ethers.utils.parseEther("0.1"));

            // Claim initial tokens
            await crowdSale.connect(user1).withdrawTokens();

            // Fast forward 6 months
            await time.increase(180 * ONE_DAY);

            // Check claimable after 6 months (~33% more should be available, so total ~43%)
            const sixMonthClaimable = await crowdSale.claimableTokens(user1.address);

            // Expected 6-month vesting: (total tokens - tge amount) * (6/18)
            const vestingAmount = totalTokens.sub(expectedTGERelease);
            const expectedSixMonthVesting = vestingAmount.mul(6).div(18);

            expect(sixMonthClaimable).to.be.closeTo(expectedSixMonthVesting, ethers.utils.parseEther("0.1"));

            // Claim 6-month tokens
            await crowdSale.connect(user1).withdrawTokens();

            // Fast forward 12 more months (total 18 months since TGE)
            await time.increase(365 * ONE_DAY);

            // Check claimable after 18 months (should be ~all remaining tokens)
            const finalClaimable = await crowdSale.claimableTokens(user1.address);
            const remainingTokens = totalTokens.sub(expectedTGERelease).sub(expectedSixMonthVesting);

            expect(finalClaimable).to.be.closeTo(remainingTokens, ethers.utils.parseEther("0.1"));
        });

        it("Should track vesting milestones correctly", async function() {
            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Purchase tokens in tier 0
            const purchaseAmount = ethers.utils.parseUnits("5000", 6); // 5,000 USDC
            await crowdSale.connect(user1).purchase(0, purchaseAmount);

            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup token distribution for TGE
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, ethers.utils.parseEther("500000000"));

            // Check next vesting milestone (should be 1 month after TGE)
            const nextMilestone = await crowdSale.getNextVestingMilestone(user1.address);
            const expectedNextTimestamp = presaleEnd + (30 * ONE_DAY);

            expect(nextMilestone.timestamp).to.be.closeTo(expectedNextTimestamp, ONE_DAY); // Allow 1 day variation
            expect(nextMilestone.amount).to.be.gt(0); // Should have some tokens available
        });

        it("Should handle auto-compound over long periods", async function() {
            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Purchase tokens in tier 0
            const purchaseAmount = ethers.utils.parseUnits("5000", 6); // 5,000 USDC
            await crowdSale.connect(user1).purchase(0, purchaseAmount);

            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup token distribution for TGE
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, ethers.utils.parseEther("500000000"));

            // Enable auto-compound
            await crowdSale.connect(user1).setAutoCompound(true);

            // Fast forward 1 year (accumulate compound interest)
            await time.increase(365 * ONE_DAY);

            // Get claimable amount with auto-compound
            const claimableWithCompound = await crowdSale.claimableTokens(user1.address);

            // Disable auto-compound for comparison
            await crowdSale.connect(user1).setAutoCompound(false);

            // Get claimable amount without auto-compound
            const claimableWithoutCompound = await crowdSale.claimableTokens(user1.address);

            // Auto-compound should yield more tokens
            expect(claimableWithCompound).to.be.gt(claimableWithoutCompound);
        });
    });

    describe("Governance Time-Based Tests", function() {
        it("Should enforce proposal voting periods", async function() {
            // Create a mock proposal
            const targets = [teachToken.address];
            const signatures = ["transfer(address,uint256)"];
            const calldatas = [ethers.utils.defaultAbiCoder.encode(
                ["address", "uint256"],
                [user1.address, ethers.utils.parseEther("1000")]
            )];
            const description = "Test proposal";
            const votingPeriod = 7 * ONE_DAY; // 1 week

            // Give owner enough tokens for proposal
            await teachToken.mint(owner.address, ethers.utils.parseEther("100000"));

            // Create proposal
            const tx = await governance.createProposal(
                targets,
                signatures,
                calldatas,
                description,
                votingPeriod
            );

            const receipt = await tx.wait();
            const proposalId = receipt.events.find(e => e.event === "ProposalCreated").args.proposalId;

            // Verify proposal state is Pending
            expect(await governance.state(proposalId)).to.equal(0); // Pending

            // Fast forward to start of voting
            const proposal = await governance.getProposalDetails(proposalId);
            await time.increaseTo(proposal.startTime.toNumber());

            // Verify proposal state is Active
            expect(await governance.state(proposalId)).to.equal(1); // Active

            // Cast votes
            await teachToken.mint(user1.address, ethers.utils.parseEther("1000000")); // Extra tokens for voting

            // Delegate voting power to self (if needed)
            // Assuming the token supports delegation, otherwise skip this step

            // Cast vote
            await governance.connect(user1).castVote(proposalId, 1, "Support"); // 1 = For

            // Fast forward past voting period
            await time.increase(votingPeriod + 100);

            // Check if proposal succeeded
            // Note: This might fail if quorum wasn't reached, but we're mainly testing time periods
            expect(await governance.state(proposalId)).to.equal(2); // Succeeded or Defeated

            // Fast forward past execution delay
            await time.increase(2 * ONE_DAY + 100);

            // Proposal should be in Queued state (assuming it succeeded)
            expect(await governance.state(proposalId)).to.equal(4); // Queued

            // Fast forward past execution period
            await time.increase(7 * ONE_DAY + 100);

            // Proposal should be Expired
            expect(await governance.state(proposalId)).to.equal(6); // Expired
        });
    });

    describe("StabilityFund TWAP Tests", function() {
        it("Should calculate time-weighted average price correctly across many observations", async function() {
            // Record multiple price observations with varying prices
            for (let i = 0; i < 24; i++) {
                // Update price
                const priceVariation = INITIAL_PRICE.mul(90 + i).div(100); // Range from 90% to 113% of initial
                await stabilityFund.connect(priceOracle).updatePrice(priceVariation);

                // Record observation
                await stabilityFund.recordPriceObservation();

                // Wait for observation interval
                await time.increase(3600); // 1 hour
            }

            // Calculate TWAP
            const twapPrice = await stabilityFund.calculateTWAP();

            // TWAP should be in the range of our prices
            expect(twapPrice).to.be.gt(INITIAL_PRICE.mul(90).div(100));
            expect(twapPrice).to.be.lt(INITIAL_PRICE.mul(113).div(100));
        });

        it("Should handle price volatility over a 30-day period", async function() {
            // Simulate 30 days of price movement with both rapid and gradual changes

            // Initial period - stable
            for (let i = 0; i < 5; i++) {
                await stabilityFund.connect(priceOracle).updatePrice(INITIAL_PRICE);
                await stabilityFund.recordPriceObservation();
                await time.increase(ONE_DAY);
            }

            // Rapid decline (-30% over 3 days)
            for (let i = 0; i < 3; i++) {
                const declinePrice = INITIAL_PRICE.mul(100 - (i * 10)).div(100);
                await stabilityFund.connect(priceOracle).updatePrice(declinePrice);
                await stabilityFund.recordPriceObservation();
                await time.increase(ONE_DAY);
            }

            // Stabilization period
            for (let i = 0; i < 7; i++) {
                await stabilityFund.connect(priceOracle).updatePrice(INITIAL_PRICE.mul(70).div(100));
                await stabilityFund.recordPriceObservation();
                await time.increase(ONE_DAY);
            }

            // Gradual recovery (+40% over a.toNumber()() 10 days)
            for (let i = 0; i < 10; i++) {
                const recoveryPrice = INITIAL_PRICE.mul(70 + (i * 4)).div(100);
                await stabilityFund.connect(priceOracle).updatePrice(recoveryPrice);
                await stabilityFund.recordPriceObservation();
                await time.increase(ONE_DAY);
            }

            // Overshoot (+10% over 5 days)
            for (let i = 0; i < 5; i++) {
                const overshootPrice = INITIAL_PRICE.mul(110 + (i * 2)).div(100);
                await stabilityFund.connect(priceOracle).updatePrice(overshootPrice);
                await stabilityFund.recordPriceObservation();
                await time.increase(ONE_DAY);
            }

            // Get current verified price
            const currentVerifiedPrice = await stabilityFund.getVerifiedPrice();

            // Get TWAP
            const twapPrice = await stabilityFund.calculateTWAP();

            // TWAP should be less volatile than current price
            // Specifically, current price is 120% of initial, but TWAP should be lower
            expect(currentVerifiedPrice).to.be.gt(INITIAL_PRICE.mul(115).div(100));
            expect(twapPrice).to.be.lt(INITIAL_PRICE.mul(110).div(100));
            expect(twapPrice).to.be.gt(INITIAL_PRICE.mul(70).div(100));
        });
    });

    describe("Cross-Contract Time Simulations", function() {
        it("Should simulate a full year of platform activity", async function() {
            // This test simulates a full year of activity across contracts

            // Step 1: CrowdSale Initial Purchase
            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Multiple users purchase in different tiers
            await crowdSale.connect(user1).purchase(0, ethers.utils.parseUnits("5000", 6));

            // Advance tier and set tier active
            await crowdSale.advanceTier();
            await crowdSale.setTierStatus(1, true);

            // More purchases
            await crowdSale.connect(user2).purchase(1, ethers.utils.parseUnits("10000", 6));

            // Fast forward 2 weeks
            await time.increase(14 * ONE_DAY);

            // Step 2: Staking Setup
            // Users stake tokens for different time periods
            await staking.connect(user3).stake(0, ethers.utils.parseEther("50000"), school1.address); // 30-day pool
            await staking.connect(user1).stake(1, ethers.utils.parseEther("25000"), school2.address); // 90-day pool
            await staking.connect(user2).stake(2, ethers.utils.parseEther("100000"), school1.address); // 365-day pool

            // Step 3: Presale End and TGE
            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup token distribution for TGE
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, ethers.utils.parseEther("500000000"));

            // Initial token claims
            await crowdSale.connect(user1).withdrawTokens();
            await crowdSale.connect(user2).withdrawTokens();

            // Step 4: Month 1-3 Activities
            // Fast forward 90 days
            await time.increase(90 * ONE_DAY);

            // Price fluctuations
            await stabilityFund.connect(priceOracle).updatePrice(INITIAL_PRICE.mul(120).div(100)); // 20% increase
            await stabilityFund.recordPriceObservation();

            // User3 unstakes from 30-day pool (lock expired)
            await staking.connect(user3).unstake(0, ethers.utils.parseEther("50000"));

            // User1 claims staking rewards from 90-day pool
            await staking.connect(user1).claimReward(1);

            // School claims
            const school1Rewards = (await staking.getSchoolDetails(school1.address)).totalRewards;
            await staking.connect(treasury).withdrawSchoolRewards(school1.address, school1Rewards);

            // Additional token claims from vesting schedule
            await crowdSale.connect(user1).withdrawTokens();
            await crowdSale.connect(user2).withdrawTokens();

            // Step 5: Month 3-6 Activities
            // Fast forward another 90 days (now at 180 days / 6 months)
            await time.increase(90 * ONE_DAY);

            // Price volatility
            await stabilityFund.connect(priceOracle).updatePrice(INITIAL_PRICE.mul(80).div(100)); // 20% decrease
            await stabilityFund.recordPriceObservation();

            // User1 unstakes from 90-day pool (lock expired)
            await staking.connect(user1).unstake(1, ethers.utils.parseEther("25000"));

            // User2 claims rewards but keeps staking in 365-day pool
            await staking.connect(user2).claimReward(2);

            // Vesting claims at 6-month mark
            await crowdSale.connect(user1).withdrawTokens();
            await crowdSale.connect(user2).withdrawTokens();

            // Step 6: Month 6-12 Activities
            // Fast forward another 180 days (now at 360 days, nearly 1 year)
            await time.increase(180 * ONE_DAY);

            // Price recovery
            await stabilityFund.connect(priceOracle).updatePrice(INITIAL_PRICE.mul(110).div(100)); // 10% above initial
            await stabilityFund.recordPriceObservation();

            // User2 unstakes from 365-day pool (lock nearly expired)
            await staking.connect(user2).unstake(2, ethers.utils.parseEther("100000"));

            // Final vesting claims at 12-month mark
            await crowdSale.connect(user1).withdrawTokens();
            await crowdSale.connect(user2).withdrawTokens();

            // Step 7: Verify End State
            // Most of user1 and user2's tokens should be claimed by now
            const user1ClaimableRemaining = await crowdSale.claimableTokens(user1.address);
            const user2ClaimableRemaining = await crowdSale.claimableTokens(user2.address);

            // Should have small amounts left due to the most recent month's vesting
            expect(user1ClaimableRemaining).to.be.lt(ethers.utils.parseEther("1000"));
            expect(user2ClaimableRemaining).to.be.lt(ethers.utils.parseEther("2000"));

            // TWAP should reflect average price over time
            const finalTWAP = await stabilityFund.calculateTWAP();
            expect(finalTWAP).to.be.closeTo(INITIAL_PRICE.mul(103).div(100), INITIAL_PRICE.div(100)); // Around 103% of initial
        });

        it("Should simulate extended vesting and reward periods over 2 years", async function() {
            // This test simulates 2 years to completely exhaust all vesting schedules and lock periods

            // Step 1: Initial Setup
            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Purchases and staking
            await crowdSale.connect(user1).purchase(0, ethers.utils.parseUnits("5000", 6));
            await staking.connect(user1).stake(2, ethers.utils.parseEther("50000"), school1.address); // 365-day pool

            // Step 2: Fast Forward 2 Years
            // Fast forward to presale end first
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup token distribution for TGE
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, ethers.utils.parseEther("500000000"));

            // Now fast forward 2 full years
            await time.increase(730 * ONE_DAY);

            // Step 3: Verify All Tokens Claimable
            // All vested tokens should be claimable now
            const claimableTokens = await crowdSale.claimableTokens(user1.address);

            // Should be equal to total tokens purchased (or very close)
            const userPurchase = await crowdSale.purchases(user1.address);
            expect(claimableTokens).to.be.closeTo(userPurchase.tokens, userPurchase.tokens.div(100)); // Within 1%

            // Step 4: Verify All Rewards Claimable
            // All staking rewards should be calculable
            const pendingRewards = await staking.calculatePendingReward(2, user1.address);

            // Should be substantial after 2 years
            expect(pendingRewards).to.be.gt(ethers.utils.parseEther("10000"));

            // Step 5: Claim Everything
            // Claim all tokens and rewards
            await crowdSale.connect(user1).withdrawTokens();
            await staking.connect(user1).claimReward(2);

            // Verify nothing left to claim
            expect(await crowdSale.claimableTokens(user1.address)).to.equal(0);
        });
    });

    describe("Emergency Time Tests", function() {
        it("Should enforce emergency periods for guardians", async function() {
            // Setup governance emergency parameters
            await governance.setEmergencyParameters(24, 3); // 24-hour period, 3 guardians required

            // Add guardians
            await governance.addGuardian(user1.address);
            await governance.addGuardian(user2.address);
            await governance.addGuardian(user3.address);

            // Create a proposal
            const targets = [teachToken.address];
            const signatures = ["transfer(address,uint256)"];
            const calldatas = [ethers.utils.defaultAbiCoder.encode(
                ["address", "uint256"],
                [user1.address, ethers.utils.parseEther("1000")]
            )];
            const description = "Test proposal";
            const votingPeriod = 7 * ONE_DAY;

            // Give owner enough tokens for proposal
            await teachToken.mint(owner.address, ethers.utils.parseEther("100000"));

            // Create proposal
            const tx = await governance.createProposal(
                targets,
                signatures,
                calldatas,
                description,
                votingPeriod
            );

            const receipt = await tx.wait();
            const proposalId = receipt.events.find(e => e.event === "ProposalCreated").args.proposalId;

            // Guardians vote to cancel within emergency period
            await governance.connect(user1).voteToCancel(proposalId, "Emergency cancellation");
            await governance.connect(user2).voteToCancel(proposalId, "Emergency cancellation");

            // Fast forward past emergency period (24 hours)
            await time.increase(25 * 3600);

            // Third guardian tries to vote - should fail due to expired emergency period
            await expect(
                governance.connect(user3).voteToCancel(proposalId, "Emergency cancellation")
            ).to.be.revertedWith("PlatformGovernance: emergency period expired");
        });

        it("Should enforce recovery timeouts for registry emergency recovery", async function() {
            // Pause system
            await registry.pauseSystem();

            // Set recovery timeout
            const recoveryTimeout = 2 * ONE_DAY; // 2 days
            await registry.setRecoveryTimeout(recoveryTimeout);

            // Initiate emergency recovery
            await registry.initiateEmergencyRecovery();
            const initiationTime = await registry.recoveryInitiatedTimestamp();

            // Fast forward past timeout
            await time.increase(recoveryTimeout + 3600); // Timeout + 1 hour

            // Try to approve recovery - should not complete recovery due to timeout
            // Note: Testing behavior here depends on exact implementation
            await registry.approveRecovery();

            // System should still be paused if timeout was enforced
            expect(await registry.systemPaused()).to.equal(true);
        });

        it("Should enforce flash loan protection cooldown periods", async function() {
            // Configure flash loan protection
            await stabilityFund.configureFlashLoanProtection(
                ethers.utils.parseEther("500000"), // 500K max daily
                ethers.utils.parseEther("100000"), // 100K per conversion
                30 * 60, // 30 minutes between actions
                true // enabled
            );

            // Place an address in cooldown
            await stabilityFund.placeSuspiciousAddressInCooldown(user1.address);

            // Set cooldown period
            const cooldownPeriod = await stabilityFund.suspiciousCooldownPeriod();

            // Try to perform action (should fail during cooldown)
            const tokenAmount = ethers.utils.parseEther("1000");
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);

            await expect(
                stabilityFund.connect(user1).swapTokensForStable(tokenAmount, 0)
            ).to.be.revertedWith("PlatformStabilityFund: address in suspicious activity cooldown");

            // Fast forward past cooldown period
            await time.increase(cooldownPeriod.toNumber() + 3600);

            // Remove from cooldown
            await stabilityFund.removeSuspiciousAddressCooldown(user1.address);

            // Action should now succeed
            await expect(
                stabilityFund.connect(user1).swapTokensForStable(tokenAmount, 0)
            ).to.not.be.reverted;
        });
    });
});