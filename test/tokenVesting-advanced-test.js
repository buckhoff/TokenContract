const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenVesting - Part 2: Advanced Features", function () {
    let tokenVesting;
    let mockToken;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const VESTING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VESTING_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    // Registry contract names
    const TOKEN_VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));
    const TEACH_TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));

    // Beneficiary groups enum
    const BeneficiaryGroup = {
        TEAM: 0,
        ADVISORS: 1,
        PARTNERS: 2,
        PUBLIC_SALE: 3,
        ECOSYSTEM: 4
    };

    beforeEach(async function () {
        // Get signers
        [owner, admin, minter, burner, treasury, emergency, user1, user2, user3] = await ethers.getSigners();

        // Deploy mock token
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockToken = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseEther("5000000000"));

        // Deploy mock registry
        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();

        // Deploy TokenVesting
        const TokenVesting = await ethers.getContractFactory("TokenVesting");
        tokenVesting = await upgrades.deployProxy(TokenVesting, [await mockToken.getAddress()], {
            initializer: "initialize",
        });

        // Set up roles
        await tokenVesting.grantRole(ADMIN_ROLE, admin.address);
        await tokenVesting.grantRole(VESTING_MANAGER_ROLE, admin.address);
        await tokenVesting.grantRole(EMERGENCY_ROLE, emergency.address);

        // Set registry
        await tokenVesting.setRegistry(await mockRegistry.getAddress(), TOKEN_VESTING_NAME);

        // Register contracts in mock registry
        await mockRegistry.setContractAddress(TOKEN_VESTING_NAME, await tokenVesting.getAddress(), true);
        await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await mockToken.getAddress(), true);

        // Transfer tokens to vesting contract
        await mockToken.transfer(await tokenVesting.getAddress(), ethers.parseEther("2000000000"));
    });

    describe("Batch Operations", function () {
        it("should create multiple vesting schedules in batch", async function () {
            const beneficiaries = [user1.address, user2.address, user3.address];
            const amounts = [
                ethers.parseEther("100000"),
                ethers.parseEther("75000"),
                ethers.parseEther("50000")
            ];
            const cliffDurations = [
                90 * 24 * 60 * 60, // 90 days
                60 * 24 * 60 * 60, // 60 days
                30 * 24 * 60 * 60  // 30 days
            ];
            const durations = [
                365 * 24 * 60 * 60, // 1 year
                180 * 24 * 60 * 60, // 6 months
                90 * 24 * 60 * 60   // 3 months
            ];
            const tgePercentages = [20, 15, 25];
            const groups = [BeneficiaryGroup.TEAM, BeneficiaryGroup.ADVISORS, BeneficiaryGroup.PARTNERS];
            const revocable = [true, true, false];

            const tx = await tokenVesting.connect(admin).createBatchVestingSchedules(
                beneficiaries,
                amounts,
                cliffDurations,
                durations,
                tgePercentages,
                groups,
                revocable
            );

            // Check that all schedules were created
            await expect(tx).to.emit(tokenVesting, "BatchSchedulesCreated").withArgs(3);

            // Verify each schedule
            for (let i = 0; i < beneficiaries.length; i++) {
                const schedules = await tokenVesting.getSchedulesForBeneficiary(beneficiaries[i]);
                expect(schedules.length).to.equal(1);

                const schedule = await tokenVesting.getVestingSchedule(schedules[0]);
                expect(schedule.amount).to.equal(amounts[i]);
                expect(schedule.group).to.equal(groups[i]);
            }
        });

        it("should batch claim tokens for multiple schedules", async function () {
            // Create multiple schedules for user1
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                30 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("50000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                true
            );

            const scheduleIds = [1, 2];
            const initialBalance = await mockToken.balanceOf(user1.address);

            // Batch claim
            await tokenVesting.connect(user1).batchClaimTokens(scheduleIds);

            const finalBalance = await mockToken.balanceOf(user1.address);
            const totalClaimed = finalBalance - initialBalance;

            // Should have claimed TGE amounts from both schedules
            const expectedClaim = ethers.parseEther("20000") + ethers.parseEther("7500"); // 20% + 15%
            expect(totalClaimed).to.equal(expectedClaim);
        });

        it("should batch revoke multiple schedules", async function () {
            // Create multiple revocable schedules
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("75000"),
                60 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleIds = [1, 2];

            // Batch revoke
            await tokenVesting.connect(admin).batchRevokeSchedules(scheduleIds);

            // Verify both schedules are revoked
            const schedule1 = await tokenVesting.getVestingSchedule(1);
            const schedule2 = await tokenVesting.getVestingSchedule(2);

            expect(schedule1.revoked).to.be.true;
            expect(schedule2.revoked).to.be.true;
        });
    });

    describe("Milestone-Based Vesting", function () {
        it("should create milestone-based vesting schedule", async function () {
            const beneficiary = user1.address;
            const totalAmount = ethers.parseEther("200000");
            const milestones = [
                { percentage: 25, description: "Product Launch" },
                { percentage: 25, description: "First Revenue" },
                { percentage: 25, description: "Break Even" },
                { percentage: 25, description: "Profitability" }
            ];

            const tx = await tokenVesting.connect(admin).createMilestoneVestingSchedule(
                beneficiary,
                totalAmount,
                milestones,
                BeneficiaryGroup.TEAM,
                true
            );

            await expect(tx).to.emit(tokenVesting, "MilestoneScheduleCreated");

            const scheduleId = 1;
            const schedule = await tokenVesting.getMilestoneSchedule(scheduleId);

            expect(schedule.beneficiary).to.equal(beneficiary);
            expect(schedule.totalAmount).to.equal(totalAmount);
            expect(schedule.milestonesCount).to.equal(4);
        });

        it("should allow admin to complete milestones", async function () {
            // Create milestone schedule
            const totalAmount = ethers.parseEther("200000");
            const milestones = [
                { percentage: 50, description: "Development Complete" },
                { percentage: 50, description: "Launch Success" }
            ];

            await tokenVesting.connect(admin).createMilestoneVestingSchedule(
                user1.address,
                totalAmount,
                milestones,
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleId = 1;

            // Complete first milestone
            await tokenVesting.connect(admin).completeMilestone(scheduleId, 0);

            // User should be able to claim 50% of tokens
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableAmount).to.equal(ethers.parseEther("100000"));

            // Claim tokens
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            // Complete second milestone
            await tokenVesting.connect(admin).completeMilestone(scheduleId, 1);

            // User should be able to claim remaining 50%
            const remainingClaimable = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(remainingClaimable).to.equal(ethers.parseEther("100000"));
        });

        it("should prevent claiming from incomplete milestones", async function () {
            const totalAmount = ethers.parseEther("100000");
            const milestones = [
                { percentage: 100, description: "Full Completion" }
            ];

            await tokenVesting.connect(admin).createMilestoneVestingSchedule(
                user1.address,
                totalAmount,
                milestones,
                BeneficiaryGroup.PARTNERS,
                true
            );

            const scheduleId = 1;

            // Should have no claimable amount initially
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableAmount).to.equal(0);

            // Attempting to claim should fail
            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.be.revertedWith("No tokens to claim");
        });
    });

    describe("Dynamic Vesting Adjustments", function () {
        let scheduleId;

        beforeEach(async function () {
            // Create a base schedule for testing adjustments
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60, // 60 days cliff
                365 * 24 * 60 * 60, // 1 year duration
                20, // 20% TGE
                BeneficiaryGroup.TEAM,
                true
            );

            scheduleId = 1;
        });

        it("should allow admin to extend vesting duration", async function () {
            const newDuration = 730 * 24 * 60 * 60; // 2 years

            await tokenVesting.connect(admin).extendVestingDuration(scheduleId, newDuration);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.duration).to.equal(newDuration);
        });

        it("should allow admin to adjust cliff period", async function () {
            const newCliff = 120 * 24 * 60 * 60; // 120 days

            await tokenVesting.connect(admin).adjustCliffPeriod(scheduleId, newCliff);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.cliffDuration).to.equal(newCliff);
        });

        it("should allow admin to modify TGE percentage", async function () {
            const newTGE = 30; // 30%

            await tokenVesting.connect(admin).modifyTGEPercentage(scheduleId, newTGE);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.tgePercentage).to.equal(newTGE);

            // Recalculate TGE amount
            const tgeAmount = await tokenVesting.calculateTGEAmount(scheduleId);
            expect(tgeAmount).to.equal(ethers.parseEther("30000")); // 30% of 100k
        });

        it("should prevent adjustments that would disadvantage beneficiary", async function () {
            // User claims some tokens first
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            // Try to reduce TGE percentage below what was already claimed
            await expect(
                tokenVesting.connect(admin).modifyTGEPercentage(scheduleId, 10) // Reduce from 20% to 10%
            ).to.be.revertedWith("Cannot reduce below claimed amount");
        });

        it("should allow increasing vesting amount", async function () {
            const additionalAmount = ethers.parseEther("50000");

            await tokenVesting.connect(admin).increaseVestingAmount(scheduleId, additionalAmount);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.amount).to.equal(ethers.parseEther("150000")); // 100k + 50k
        });
    });

    describe("Vesting Templates", function () {
        it("should create and use vesting templates", async function () {
            // Create a template for team members
            const templateId = await tokenVesting.connect(admin).createVestingTemplate(
                "Team Template",
                90 * 24 * 60 * 60, // 90 days cliff
                365 * 24 * 60 * 60, // 1 year duration
                15, // 15% TGE
                BeneficiaryGroup.TEAM,
                true // revocable
            );

            // Use template to create schedule
            await tokenVesting.connect(admin).createScheduleFromTemplate(
                templateId,
                user1.address,
                ethers.parseEther("80000")
            );

            const schedule = await tokenVesting.getVestingSchedule(1);
            expect(schedule.cliffDuration).to.equal(90 * 24 * 60 * 60);
            expect(schedule.duration).to.equal(365 * 24 * 60 * 60);
            expect(schedule.tgePercentage).to.equal(15);
            expect(schedule.group).to.equal(BeneficiaryGroup.TEAM);
        });

        it("should batch create schedules from template", async function () {
            // Create advisor template
            const templateId = await tokenVesting.connect(admin).createVestingTemplate(
                "Advisor Template",
                30 * 24 * 60 * 60, // 30 days cliff
                180 * 24 * 60 * 60, // 6 months duration
                25, // 25% TGE
                BeneficiaryGroup.ADVISORS,
                false // non-revocable
            );

            const beneficiaries = [user1.address, user2.address, user3.address];
            const amounts = [
                ethers.parseEther("25000"),
                ethers.parseEther("30000"),
                ethers.parseEther("20000")
            ];

            await tokenVesting.connect(admin).batchCreateFromTemplate(
                templateId,
                beneficiaries,
                amounts
            );

            // Verify all schedules were created with template parameters
            for (let i = 0; i < beneficiaries.length; i++) {
                const schedules = await tokenVesting.getSchedulesForBeneficiary(beneficiaries[i]);
                expect(schedules.length).to.be.gte(1);

                const schedule = await tokenVesting.getVestingSchedule(schedules[0]);
                expect(schedule.group).to.equal(BeneficiaryGroup.ADVISORS);
                expect(schedule.tgePercentage).to.equal(25);
                expect(schedule.revocable).to.be.false;
            }
        });
    });

    describe("Vesting Analytics and Reporting", function () {
        beforeEach(async function () {
            // Create various schedules for analytics testing
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("75000"),
                60 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user3.address,
                ethers.parseEther("50000"),
                30 * 24 * 60 * 60,
                90 * 24 * 60 * 60,
                25,
                BeneficiaryGroup.PUBLIC_SALE,
                false
            );
        });

        it("should provide comprehensive vesting analytics", async function () {
            const analytics = await tokenVesting.getVestingAnalytics();

            expect(analytics.totalSchedules).to.equal(3);
            expect(analytics.totalAmount).to.equal(ethers.parseEther("225000"));
            expect(analytics.totalClaimed).to.equal(0);
            expect(analytics.activeSchedules).to.equal(3);
            expect(analytics.revokedSchedules).to.equal(0);
        });

        it("should calculate projected vesting releases", async function () {
            const timeframe = 365 * 24 * 60 * 60; // 1 year projection
            const projection = await tokenVesting.getVestingProjection(timeframe);

            expect(projection.totalToVest).to.be.gt(0);
            expect(projection.monthlyReleases.length).to.equal(12);
        });

        it("should provide beneficiary performance metrics", async function () {
            // Claim some tokens
            await tokenVesting.connect(user1).claimTokens(1);
            await tokenVesting.connect(user2).claimTokens(2);

            const metrics = await tokenVesting.getBeneficiaryMetrics(user1.address);

            expect(metrics.totalAllocated).to.equal(ethers.parseEther("100000"));
            expect(metrics.totalClaimed).to.be.gt(0);
            expect(metrics.scheduleCount).to.equal(1);
            expect(metrics.claimHistory.length).to.be.gt(0);
        });

        it("should generate vesting compliance report", async function () {
            const report = await tokenVesting.generateComplianceReport();

            expect(report.totalBeneficiaries).to.equal(3);
            expect(report.groupDistribution.length).to.equal(5); // All beneficiary groups
            expect(report.scheduleTypes.linear).to.equal(3);
            expect(report.scheduleTypes.milestone).to.equal(0);
        });

        it("should track vesting velocity over time", async function () {
            // Fast forward and claim tokens
            await ethers.provider.send("evm_increaseTime", [95 * 24 * 60 * 60]); // 95 days
            await ethers.provider.send("evm_mine");

            await tokenVesting.connect(user1).claimTokens(1);
            await tokenVesting.connect(user2).claimTokens(2);
            await tokenVesting.connect(user3).claimTokens(3);

            const velocity = await tokenVesting.getVestingVelocity(30); // Last 30 days
            expect(velocity.tokensVested).to.be.gt(0);
            expect(velocity.claimCount).to.equal(3);
        });
    });

    describe("Advanced Schedule Types", function () {
        it("should create accelerated vesting schedule", async function () {
            // Schedule that accelerates based on performance metrics
            const beneficiary = user1.address;
            const baseAmount = ethers.parseEther("100000");
            const accelerationTriggers = [
                { metric: "revenue_target", threshold: ethers.parseEther("1000000"), multiplier: 150 }, // 1.5x
                { metric: "user_growth", threshold: 10000, multiplier: 125 } // 1.25x
            ];

            await tokenVesting.connect(admin).createAcceleratedVestingSchedule(
                beneficiary,
                baseAmount,
                180 * 24 * 60 * 60, // 6 months base duration
                accelerationTriggers,
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleId = 1;
            const schedule = await tokenVesting.getAcceleratedSchedule(scheduleId);

            expect(schedule.baseAmount).to.equal(baseAmount);
            expect(schedule.accelerationTriggers.length).to.equal(2);
        });

        it("should create performance-based vesting", async function () {
            const beneficiary = user1.address;
            const maxAmount = ethers.parseEther("200000");
            const performanceMetrics = [
                { name: "revenue", weight: 40, target: ethers.parseEther("5000000") },
                { name: "users", weight: 30, target: 50000 },
                { name: "retention", weight: 30, target: 80 } // 80%
            ];

            await tokenVesting.connect(admin).createPerformanceVestingSchedule(
                beneficiary,
                maxAmount,
                365 * 24 * 60 * 60, // 1 year evaluation period
                performanceMetrics,
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleId = 1;
            const schedule = await tokenVesting.getPerformanceSchedule(scheduleId);

            expect(schedule.maxAmount).to.equal(maxAmount);
            expect(schedule.metrics.length).to.equal(3);
        });

        it("should create variable rate vesting", async function () {
            // Vesting rate changes over time
            const beneficiary = user1.address;
            const totalAmount = ethers.parseEther("120000");
            const vestingRates = [
                { period: 90 * 24 * 60 * 60, rate: 10 }, // 10% in first 3 months
                { period: 90 * 24 * 60 * 60, rate: 20 }, // 20% in next 3 months
                { period: 90 * 24 * 60 * 60, rate: 30 }, // 30% in next 3 months
                { period: 90 * 24 * 60 * 60, rate: 40 }  // 40% in final 3 months
            ];

            await tokenVesting.connect(admin).createVariableRateVestingSchedule(
                beneficiary,
                totalAmount,
                vestingRates,
                BeneficiaryGroup.ADVISORS,
                true
            );

            const scheduleId = 1;

            // Test vesting calculation at different periods
            await ethers.provider.send("evm_increaseTime", [95 * 24 * 60 * 60]); // After first period
            await ethers.provider.send("evm_mine");

            const claimableFirst = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableFirst).to.equal(ethers.parseEther("12000")); // 10% of 120k

            await ethers.provider.send("evm_increaseTime", [90 * 24 * 60 * 60]); // After second period
            await ethers.provider.send("evm_mine");

            const claimableSecond = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableSecond).to.equal(ethers.parseEther("36000")); // 10% + 20% = 30%
        });
    });

    describe("Integration Features", function () {
        it("should integrate with governance for schedule approvals", async function () {
            // Large schedules require governance approval
            const largeAmount = ethers.parseEther("1000000"); // 1M tokens

            // Create governance proposal for large vesting schedule
            const proposalData = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "uint256", "uint256", "uint256", "uint8", "uint8", "bool"],
                [
                    user1.address,
                    largeAmount,
                    90 * 24 * 60 * 60, // cliff
                    365 * 24 * 60 * 60, // duration
                    10, // TGE
                    BeneficiaryGroup.TEAM,
                    true // revocable
                ]
            );

            const proposalId = await tokenVesting.connect(admin).createGovernanceProposal(
                "Large Team Vesting Schedule",
                "Approve 1M token vesting for key team member",
                proposalData
            );

            expect(proposalId).to.be.gt(0);

            // Simulate governance approval
            await tokenVesting.connect(admin).executeGovernanceProposal(proposalId);

            // Schedule should now exist
            const schedules = await tokenVesting.getSchedulesForBeneficiary(user1.address);
            expect(schedules.length).to.equal(1);
        });

        it("should integrate with compliance monitoring", async function () {
            // Create schedule with compliance requirements
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("500000"),
                180 * 24 * 60 * 60, // 6 months cliff
                730 * 24 * 60 * 60, // 2 years duration
                5, // 5% TGE
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleId = 1;

            // Set compliance requirements
            await tokenVesting.connect(admin).setComplianceRequirements(
                scheduleId,
                true, // KYC required
                true, // AML check required
                ["employment_verification", "tax_compliance"] // Additional requirements
            );

            // Attempt to claim without compliance
            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.be.revertedWith("Compliance requirements not met");

            // Mark compliance as satisfied
            await tokenVesting.connect(admin).markComplianceSatisfied(scheduleId, user1.address);

            // Now claiming should work
            await expect(tokenVesting.connect(user1).claimTokens(scheduleId)).to.not.be.reverted;
        });

        it("should support multi-token vesting", async function () {
            // Deploy additional token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const secondToken = await MockERC20.deploy("Bonus Token", "BONUS", ethers.parseEther("1000000"));

            await secondToken.transfer(await tokenVesting.getAddress(), ethers.parseEther("100000"));

            // Create multi-token vesting schedule
            const tokens = [await mockToken.getAddress(), await secondToken.getAddress()];
            const amounts = [ethers.parseEther("50000"), ethers.parseEther("25000")];

            await tokenVesting.connect(admin).createMultiTokenVestingSchedule(
                user1.address,
                tokens,
                amounts,
                90 * 24 * 60 * 60, // cliff
                365 * 24 * 60 * 60, // duration
                20, // TGE
                BeneficiaryGroup.TEAM,
                true
            );

            const scheduleId = 1;

            // Claim should distribute both tokens
            const initialBalance1 = await mockToken.balanceOf(user1.address);
            const initialBalance2 = await secondToken.balanceOf(user1.address);

            await tokenVesting.connect(user1).claimTokens(scheduleId);

            const finalBalance1 = await mockToken.balanceOf(user1.address);
            const finalBalance2 = await secondToken.balanceOf(user1.address);

            expect(finalBalance1 - initialBalance1).to.equal(ethers.parseEther("10000")); // 20% of 50k
            expect(finalBalance2 - initialBalance2).to.equal(ethers.parseEther("5000")); // 20% of 25k
        });
    });

    describe("Security and Risk Management", function () {
        it("should implement circuit breakers for large claims", async function () {
            // Set daily claim limit
            await tokenVesting.connect(admin).setDailyClaimLimit(ethers.parseEther("100000"));

            // Create large vesting schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("1000000"),
                0, // No cliff
                365 * 24 * 60 * 60,
                100, // 100% TGE (immediate)
                BeneficiaryGroup.TEAM,
                true
            );

            // Should be limited by daily claim limit
            const claimableAmount = await tokenVesting.calculateClaimableAmount(1);
            expect(claimableAmount).to.equal(ethers.parseEther("100000")); // Limited to daily max
        });

        it("should detect and prevent suspicious claiming patterns", async function () {
            // Create multiple schedules
            const schedules = [];
            for (let i = 0; i < 5; i++) {
                await tokenVesting.connect(admin).createLinearVestingSchedule(
                    user1.address,
                    ethers.parseEther("20000"),
                    0,
                    30 * 24 * 60 * 60,
                    50,
                    BeneficiaryGroup.TEAM,
                    true
                );
                schedules.push(i + 1);
            }

            // Rapid claiming should trigger suspicious activity detection
            for (let i = 0; i < 3; i++) {
                await tokenVesting.connect(user1).claimTokens(schedules[i]);
            }

            // Further claims should be temporarily blocked
            await expect(
                tokenVesting.connect(user1).claimTokens(schedules[3])
            ).to.be.revertedWith("Suspicious activity detected");
        });

        it("should implement emergency pause functionality", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                30 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            // Emergency pause
            await tokenVesting.connect(emergency).emergencyPause();

            // All operations should be paused
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Contract paused");

            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user2.address,
                    ethers.parseEther("50000"),
                    60 * 24 * 60 * 60,
                    180 * 24 * 60 * 60,
                    15,
                    BeneficiaryGroup.ADVISORS,
                    true
                )
            ).to.be.revertedWith("Contract paused");

            // Unpause
            await tokenVesting.connect(emergency).emergencyUnpause();

            // Operations should resume
            await expect(tokenVesting.connect(user1).claimTokens(1)).to.not.be.reverted;
        });
    });

    describe("Upgrade and Migration", function () {
        it("should handle vesting data export for migration", async function () {
            // Create various schedules
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("75000"),
                60 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                false
            );

            // Export data
            const exportData = await tokenVesting.exportVestingData();

            expect(exportData.version).to.be.gt(0);
            expect(exportData.schedules.length).to.equal(2);
            expect(exportData.totalAmount).to.equal(ethers.parseEther("175000"));
            expect(exportData.checksum).to.not.equal(ethers.ZeroHash);
        });

        it("should validate data integrity before migration", async function () {
            // Create test data
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            // User claims some tokens
            await tokenVesting.connect(user1).claimTokens(1);

            // Validate data integrity
            const validation = await tokenVesting.validateDataIntegrity();

            expect(validation.isValid).to.be.true;
            expect(validation.totalSchedules).to.equal(1);
            expect(validation.totalClaimed).to.be.gt(0);
            expect(validation.contractBalance).to.be.gt(0);
        });
    });
});