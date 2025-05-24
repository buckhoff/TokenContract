const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenVesting - Part 1: Basic Functionality", function () {
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
        await mockToken.transfer(await tokenVesting.getAddress(), ethers.parseEther("1000000000"));
    });

    describe("Initialization", function () {
        it("should initialize with correct token address", async function () {
            expect(await tokenVesting.token()).to.equal(await mockToken.getAddress());
        });

        it("should set correct roles", async function () {
            expect(await tokenVesting.hasRole(await tokenVesting.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await tokenVesting.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await tokenVesting.hasRole(VESTING_MANAGER_ROLE, admin.address)).to.be.true;
            expect(await tokenVesting.hasRole(EMERGENCY_ROLE, emergency.address)).to.be.true;
        });

        it("should set registry correctly", async function () {
            expect(await tokenVesting.registry()).to.equal(await mockRegistry.getAddress());
            expect(await tokenVesting.contractName()).to.equal(TOKEN_VESTING_NAME);
        });
    });

    describe("Vesting Schedule Creation", function () {
        it("should create a linear vesting schedule", async function () {
            const beneficiary = user1.address;
            const amount = ethers.parseEther("100000");
            const cliffDuration = 90 * 24 * 60 * 60; // 90 days
            const duration = 365 * 24 * 60 * 60; // 1 year
            const tgePercentage = 20; // 20% at TGE
            const group = BeneficiaryGroup.TEAM;
            const revocable = true;

            const tx = await tokenVesting.connect(admin).createLinearVestingSchedule(
                beneficiary,
                amount,
                cliffDuration,
                duration,
                tgePercentage,
                group,
                revocable
            );

            // Check event emission
            await expect(tx).to.emit(tokenVesting, "VestingScheduleCreated");

            // Verify schedule was created (assuming it returns schedule ID 1)
            const scheduleId = 1;
            const schedule = await tokenVesting.getVestingSchedule(scheduleId);

            expect(schedule.beneficiary).to.equal(beneficiary);
            expect(schedule.amount).to.equal(amount);
            expect(schedule.cliffDuration).to.equal(cliffDuration);
            expect(schedule.duration).to.equal(duration);
            expect(schedule.tgePercentage).to.equal(tgePercentage);
            expect(schedule.group).to.equal(group);
            expect(schedule.revocable).to.equal(revocable);
            expect(schedule.revoked).to.be.false;
            expect(schedule.claimed).to.equal(0);
        });

        it("should create multiple schedules for the same beneficiary", async function () {
            const beneficiary = user1.address;
            const amount1 = ethers.parseEther("50000");
            const amount2 = ethers.parseEther("75000");

            // Create first schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                beneficiary,
                amount1,
                30 * 24 * 60 * 60, // 30 days cliff
                180 * 24 * 60 * 60, // 6 months duration
                10, // 10% TGE
                BeneficiaryGroup.ADVISORS,
                true
            );

            // Create second schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                beneficiary,
                amount2,
                60 * 24 * 60 * 60, // 60 days cliff
                365 * 24 * 60 * 60, // 1 year duration
                15, // 15% TGE
                BeneficiaryGroup.PARTNERS,
                false
            );

            // Check that beneficiary has 2 schedules
            const schedules = await tokenVesting.getSchedulesForBeneficiary(beneficiary);
            expect(schedules.length).to.equal(2);
        });

        it("should prevent creating schedule with invalid parameters", async function () {
            const beneficiary = user1.address;
            const amount = ethers.parseEther("100000");

            // Zero beneficiary address
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    ethers.ZeroAddress,
                    amount,
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("Zero beneficiary address");

            // Zero amount
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    beneficiary,
                    0,
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("Zero vesting amount");

            // Cliff longer than duration
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    beneficiary,
                    amount,
                    400 * 24 * 60 * 60, // Cliff longer than duration
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("Cliff exceeds duration");

            // Invalid TGE percentage
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    beneficiary,
                    amount,
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    101, // Over 100%
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("Invalid TGE percentage");
        });

        it("should not allow non-manager to create schedules", async function () {
            await expect(
                tokenVesting.connect(user1).createLinearVestingSchedule(
                    user2.address,
                    ethers.parseEther("100000"),
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.reverted; // Will revert due to role check
        });
    });

    describe("Vesting Calculations", function () {
        let scheduleId;

        beforeEach(async function () {
            // Create a test schedule
            const tx = await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"), // 100,000 tokens
                90 * 24 * 60 * 60, // 90 days cliff
                365 * 24 * 60 * 60, // 1 year duration
                20, // 20% TGE
                BeneficiaryGroup.TEAM,
                true
            );

            scheduleId = 1; // Assuming first schedule gets ID 1
        });

        it("should calculate TGE amount correctly", async function () {
            const tgeAmount = await tokenVesting.calculateTGEAmount(scheduleId);
            const expectedTGE = ethers.parseEther("20000"); // 20% of 100,000

            expect(tgeAmount).to.equal(expectedTGE);
        });

        it("should show no claimable amount during cliff period", async function () {
            // Should be zero during cliff period
            const claimable = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimable).to.equal(ethers.parseEther("20000")); // Only TGE amount
        });

        it("should calculate claimable amount after cliff period", async function () {
            // Fast forward past cliff period
            await ethers.provider.send("evm_increaseTime", [95 * 24 * 60 * 60]); // 95 days
            await ethers.provider.send("evm_mine");

            const claimable = await tokenVesting.calculateClaimableAmount(scheduleId);

            // Should include TGE + some vested amount
            expect(claimable).to.be.gt(ethers.parseEther("20000"));
        });

        it("should calculate full amount as claimable after vesting period", async function () {
            // Fast forward past entire vesting period
            await ethers.provider.send("evm_increaseTime", [400 * 24 * 60 * 60]); // 400 days
            await ethers.provider.send("evm_mine");

            const claimable = await tokenVesting.calculateClaimableAmount(scheduleId);

            // Should be full amount
            expect(claimable).to.equal(ethers.parseEther("100000"));
        });

        it("should calculate vested amount correctly over time", async function () {
            // Fast forward to halfway through vesting
            await ethers.provider.send("evm_increaseTime", [275 * 24 * 60 * 60]); // 275 days (halfway after cliff)
            await ethers.provider.send("evm_mine");

            const vestedAmount = await tokenVesting.calculateVestedAmount(scheduleId);

            // Should be approximately 60% vested (20% TGE + 40% of remaining 80%)
            const expectedVested = ethers.parseEther("60000");
            expect(vestedAmount).to.be.closeTo(expectedVested, ethers.parseEther("5000")); // Allow 5% variance
        });
    });

    describe("Token Claiming", function () {
        let scheduleId;

        beforeEach(async function () {
            // Create a test schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                30 * 24 * 60 * 60, // 30 days cliff
                180 * 24 * 60 * 60, // 6 months duration
                25, // 25% TGE
                BeneficiaryGroup.PUBLIC_SALE,
                true
            );

            scheduleId = 1;
        });

        it("should allow claiming TGE amount immediately", async function () {
            const initialBalance = await mockToken.balanceOf(user1.address);
            const tgeAmount = await tokenVesting.calculateTGEAmount(scheduleId);

            await tokenVesting.connect(user1).claimTokens(scheduleId);

            const finalBalance = await mockToken.balanceOf(user1.address);
            expect(finalBalance - initialBalance).to.equal(tgeAmount);

            // Check that claimed amount is tracked
            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.claimed).to.equal(tgeAmount);
        });

        it("should allow claiming additional tokens after cliff", async function () {
            // First claim TGE
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            // Fast forward past cliff
            await ethers.provider.send("evm_increaseTime", [35 * 24 * 60 * 60]); // 35 days
            await ethers.provider.send("evm_mine");

            const balanceBeforeClaim = await mockToken.balanceOf(user1.address);
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);

            await tokenVesting.connect(user1).claimTokens(scheduleId);

            const balanceAfterClaim = await mockToken.balanceOf(user1.address);
            const actualClaimed = balanceAfterClaim - balanceBeforeClaim;

            expect(actualClaimed).to.be.gt(0);
            expect(actualClaimed).to.be.lte(claimableAmount);
        });

        it("should prevent claiming more than available", async function () {
            // Claim TGE
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            // Try to claim again immediately (should be zero or very small amount)
            const claimable = await tokenVesting.calculateClaimableAmount(scheduleId);

            if (claimable == 0) {
                await expect(
                    tokenVesting.connect(user1).claimTokens(scheduleId)
                ).to.be.revertedWith("No tokens to claim");
            }
        });

        it("should prevent non-beneficiary from claiming", async function () {
            await expect(
                tokenVesting.connect(user2).claimTokens(scheduleId)
            ).to.be.revertedWith("Not the beneficiary");
        });

        it("should emit event when tokens are claimed", async function () {
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);

            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.emit(tokenVesting, "TokensClaimed")
                .withArgs(scheduleId, user1.address, claimableAmount);
        });
    });

    describe("Schedule Management", function () {
        let scheduleId;

        beforeEach(async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60, // 60 days cliff
                365 * 24 * 60 * 60, // 1 year duration
                15, // 15% TGE
                BeneficiaryGroup.TEAM,
                true // revocable
            );

            scheduleId = 1;
        });

        it("should return correct schedule information", async function () {
            const schedule = await tokenVesting.getVestingSchedule(scheduleId);

            expect(schedule.beneficiary).to.equal(user1.address);
            expect(schedule.amount).to.equal(ethers.parseEther("100000"));
            expect(schedule.group).to.equal(BeneficiaryGroup.TEAM);
            expect(schedule.revocable).to.be.true;
            expect(schedule.revoked).to.be.false;
        });

        it("should return schedules for beneficiary", async function () {
            // Create another schedule for the same user
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("50000"),
                30 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                10,
                BeneficiaryGroup.ADVISORS,
                false
            );

            const schedules = await tokenVesting.getSchedulesForBeneficiary(user1.address);
            expect(schedules.length).to.equal(2);
        });

        it("should allow admin to revoke revocable schedule", async function () {
            // Claim some tokens first
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            // Revoke the schedule
            await tokenVesting.connect(admin).revokeVestingSchedule(scheduleId);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.revoked).to.be.true;
        });

        it("should prevent revoking non-revocable schedule", async function () {
            // Create non-revocable schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.PARTNERS,
                false // non-revocable
            );

            const nonRevocableScheduleId = 2;

            await expect(
                tokenVesting.connect(admin).revokeVestingSchedule(nonRevocableScheduleId)
            ).to.be.revertedWith("Schedule not revocable");
        });

        it("should prevent claiming from revoked schedule", async function () {
            // Revoke the schedule
            await tokenVesting.connect(admin).revokeVestingSchedule(scheduleId);

            // Try to claim
            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.be.revertedWith("Schedule revoked");
        });
    });

    describe("Beneficiary Group Management", function () {
        it("should get schedules by beneficiary group", async function () {
            // Create schedules for different groups
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

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user3.address,
                ethers.parseEther("50000"),
                30 * 24 * 60 * 60,
                90 * 24 * 60 * 60,
                25,
                BeneficiaryGroup.ADVISORS,
                false
            );

            const teamSchedules = await tokenVesting.getSchedulesByGroup(BeneficiaryGroup.TEAM);
            const advisorSchedules = await tokenVesting.getSchedulesByGroup(BeneficiaryGroup.ADVISORS);

            expect(teamSchedules.length).to.equal(2);
            expect(advisorSchedules.length).to.equal(1);
        });

        it("should get total vested amount by group", async function () {
            // Create schedules for team group
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                0, // No cliff for easy calculation
                365 * 24 * 60 * 60,
                0, // No TGE
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("200000"),
                0,
                365 * 24 * 60 * 60,
                0,
                BeneficiaryGroup.TEAM,
                true
            );

            const totalAmount = await tokenVesting.getTotalAmountByGroup(BeneficiaryGroup.TEAM);
            expect(totalAmount).to.equal(ethers.parseEther("300000"));
        });
    });

    describe("Access Control", function () {
        it("should prevent unauthorized schedule creation", async function () {
            await expect(
                tokenVesting.connect(user1).createLinearVestingSchedule(
                    user2.address,
                    ethers.parseEther("100000"),
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.reverted; // Will revert due to role check
        });

        it("should prevent unauthorized schedule revocation", async function () {
            // Create a schedule first
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            // Try to revoke as non-admin
            await expect(
                tokenVesting.connect(user1).revokeVestingSchedule(1)
            ).to.be.reverted; // Will revert due to role check
        });

        it("should allow adding vesting managers", async function () {
            await tokenVesting.connect(admin).grantRole(VESTING_MANAGER_ROLE, user1.address);

            expect(await tokenVesting.hasRole(VESTING_MANAGER_ROLE, user1.address)).to.be.true;

            // User1 should now be able to create schedules
            await tokenVesting.connect(user1).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("50000"),
                60 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                true
            );
        });

        it("should allow removing vesting managers", async function () {
            // Grant role first
            await tokenVesting.connect(admin).grantRole(VESTING_MANAGER_ROLE, user1.address);

            // Remove role
            await tokenVesting.connect(admin).revokeRole(VESTING_MANAGER_ROLE, user1.address);

            expect(await tokenVesting.hasRole(VESTING_MANAGER_ROLE, user1.address)).to.be.false;

            // User1 should no longer be able to create schedules
            await expect(
                tokenVesting.connect(user1).createLinearVestingSchedule(
                    user2.address,
                    ethers.parseEther("50000"),
                    60 * 24 * 60 * 60,
                    180 * 24 * 60 * 60,
                    15,
                    BeneficiaryGroup.ADVISORS,
                    true
                )
            ).to.be.reverted;
        });
    });

    describe("Edge Cases and Error Handling", function () {
        it("should handle queries for non-existent schedules", async function () {
            const nonExistentId = 999;

            // Should return empty/default schedule data
            const schedule = await tokenVesting.getVestingSchedule(nonExistentId);
            expect(schedule.beneficiary).to.equal(ethers.ZeroAddress);
            expect(schedule.amount).to.equal(0);
        });

        it("should handle beneficiaries with no schedules", async function () {
            const schedules = await tokenVesting.getSchedulesForBeneficiary(user3.address);
            expect(schedules.length).to.equal(0);
        });

        it("should prevent creating schedules when contract has insufficient balance", async function () {
            // Try to create a schedule larger than contract balance
            const contractBalance = await mockToken.balanceOf(await tokenVesting.getAddress());
            const excessiveAmount = contractBalance + ethers.parseEther("1000000");

            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user1.address,
                    excessiveAmount,
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("Insufficient contract balance");
        });

        it("should handle zero duration vesting", async function () {
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user1.address,
                    ethers.parseEther("100000"),
                    0, // No cliff
                    0, // Zero duration
                    100, // 100% TGE (immediate vesting)
                    BeneficiaryGroup.PUBLIC_SALE,
                    false
                )
            ).to.be.revertedWith("Zero vesting duration");
        });
    });

    describe("Integration with Registry", function () {
        it("should update token address from registry", async function () {
            // Deploy new mock token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const newMockToken = await MockERC20.deploy("New Token", "NEW", ethers.parseEther("1000000"));

            // Update registry
            await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await newMockToken.getAddress(), true);

            // Update contract references
            await tokenVesting.connect(admin).updateContractReferences();

            // Verify token address updated
            expect(await tokenVesting.token()).to.equal(await newMockToken.getAddress());
        });

        it("should respect system pause from registry", async function () {
            // Set system as paused in registry
            await mockRegistry.setPaused(true);

            // Vesting operations should be paused
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user1.address,
                    ethers.parseEther("100000"),
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.be.revertedWith("SystemPaused");
        });

        it("should handle registry offline mode", async function () {
            // Enable offline mode
            await tokenVesting.connect(admin).enableRegistryOfflineMode();

            // Operations should still work
            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user1.address,
                    ethers.parseEther("100000"),
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                )
            ).to.not.be.reverted;
        });
    });

    describe("Statistics and Reporting", function () {
        beforeEach(async function () {
            // Create multiple schedules for testing statistics
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

        it("should return total number of schedules", async function () {
            const totalSchedules = await tokenVesting.getTotalSchedulesCount();
            expect(totalSchedules).to.equal(3);
        });

        it("should return total vesting amount", async function () {
            const totalAmount = await tokenVesting.getTotalVestingAmount();
            const expectedTotal = ethers.parseEther("225000"); // 100k + 75k + 50k

            expect(totalAmount).to.equal(expectedTotal);
        });

        it("should return total claimed amount", async function () {
            // Claim from one schedule
            await tokenVesting.connect(user1).claimTokens(1);

            const totalClaimed = await tokenVesting.getTotalClaimedAmount();
            expect(totalClaimed).to.be.gt(0);
        });

        it("should return vesting statistics by group", async function () {
            const teamStats = await tokenVesting.getGroupStatistics(BeneficiaryGroup.TEAM);
            const advisorStats = await tokenVesting.getGroupStatistics(BeneficiaryGroup.ADVISORS);
            const publicStats = await tokenVesting.getGroupStatistics(BeneficiaryGroup.PUBLIC_SALE);

            expect(teamStats.totalAmount).to.equal(ethers.parseEther("100000"));
            expect(teamStats.scheduleCount).to.equal(1);

            expect(advisorStats.totalAmount).to.equal(ethers.parseEther("75000"));
            expect(advisorStats.scheduleCount).to.equal(1);

            expect(publicStats.totalAmount).to.equal(ethers.parseEther("50000"));
            expect(publicStats.scheduleCount).to.equal(1);
        });

        it("should return active schedules count", async function () {
            const activeCount = await tokenVesting.getActiveSchedulesCount();
            expect(activeCount).to.equal(3);

            // Revoke one schedule
            await tokenVesting.connect(admin).revokeVestingSchedule(1);

            const newActiveCount = await tokenVesting.getActiveSchedulesCount();
            expect(newActiveCount).to.equal(2);
        });
    });
});