const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenVesting - Part 3: Emergency Functions and Edge Cases", function () {
    let tokenVesting;
    let mockToken;
    let mockRegistry;
    let owner, admin, minter, burner, treasury, emergency, user1, user2, user3;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const VESTING_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VESTING_MANAGER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
    const RECOVERY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RECOVERY_ROLE"));

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
        await tokenVesting.grantRole(RECOVERY_ROLE, admin.address);

        // Set registry
        await tokenVesting.setRegistry(await mockRegistry.getAddress(), TOKEN_VESTING_NAME);

        // Register contracts in mock registry
        await mockRegistry.setContractAddress(TOKEN_VESTING_NAME, await tokenVesting.getAddress(), true);
        await mockRegistry.setContractAddress(TEACH_TOKEN_NAME, await mockToken.getAddress(), true);

        // Transfer tokens to vesting contract
        await mockToken.transfer(await tokenVesting.getAddress(), ethers.parseEther("2000000000"));
    });

    describe("Emergency Pause and Recovery", function () {
        beforeEach(async function () {
            // Create test schedules
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("75000"),
                30 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                false
            );
        });

        it("should allow emergency pause of all vesting operations", async function () {
            await tokenVesting.connect(emergency).emergencyPause();

            expect(await tokenVesting.paused()).to.be.true;

            // All vesting operations should be paused
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Pausable: paused");

            await expect(
                tokenVesting.connect(admin).createLinearVestingSchedule(
                    user3.address,
                    ethers.parseEther("50000"),
                    90 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    25,
                    BeneficiaryGroup.PARTNERS,
                    true
                )
            ).to.be.revertedWith("Pausable: paused");
        });

        it("should allow emergency unpause", async function () {
            await tokenVesting.connect(emergency).emergencyPause();
            expect(await tokenVesting.paused()).to.be.true;

            await tokenVesting.connect(emergency).emergencyUnpause();
            expect(await tokenVesting.paused()).to.be.false;

            // Operations should resume
            await expect(tokenVesting.connect(user1).claimTokens(1)).to.not.be.reverted;
        });

        it("should prevent non-emergency roles from pausing", async function () {
            await expect(
                tokenVesting.connect(user1).emergencyPause()
            ).to.be.reverted;

            await expect(
                tokenVesting.connect(admin).emergencyPause()
            ).to.be.reverted;
        });

        it("should allow emergency token recovery", async function () {
            // Deploy a different token that was sent by mistake
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const wrongToken = await MockERC20.deploy("Wrong Token", "WRONG", ethers.parseEther("1000000"));

            // Send wrong tokens to vesting contract
            const wrongAmount = ethers.parseEther("50000");
            await wrongToken.transfer(await tokenVesting.getAddress(), wrongAmount);

            const initialBalance = await wrongToken.balanceOf(owner.address);

            // Emergency recover wrong tokens
            await tokenVesting.connect(emergency).emergencyTokenRecovery(
                await wrongToken.getAddress(),
                wrongAmount
            );

            const finalBalance = await wrongToken.balanceOf(owner.address);
            expect(finalBalance - initialBalance).to.equal(wrongAmount);
        });

        it("should prevent recovery of the main vesting token", async function () {
            await expect(
                tokenVesting.connect(emergency).emergencyTokenRecovery(
                    await mockToken.getAddress(),
                    ethers.parseEther("1000")
                )
            ).to.be.revertedWith("Cannot recover vesting token");
        });
    });

    describe("Emergency Schedule Modifications", function () {
        let scheduleId;

        beforeEach(async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("200000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.TEAM,
                true
            );

            scheduleId = 1;
        });

        it("should allow emergency schedule termination", async function () {
            // User claims some tokens first
            await tokenVesting.connect(user1).claimTokens(scheduleId);

            const claimedBefore = (await tokenVesting.getVestingSchedule(scheduleId)).claimed;

            // Emergency terminate
            await tokenVesting.connect(emergency).emergencyTerminateSchedule(scheduleId);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.terminated).to.be.true;

            // No further claims should be possible
            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.be.revertedWith("Schedule terminated");
        });

        it("should allow emergency beneficiary transfer", async function () {
            // Transfer beneficiary in emergency (e.g., compromised wallet)
            await tokenVesting.connect(emergency).emergencyTransferBeneficiary(
                scheduleId,
                user1.address,
                user2.address
            );

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.beneficiary).to.equal(user2.address);

            // Original beneficiary should not be able to claim
            await expect(
                tokenVesting.connect(user1).claimTokens(scheduleId)
            ).to.be.revertedWith("Not the beneficiary");

            // New beneficiary should be able to claim
            await expect(tokenVesting.connect(user2).claimTokens(scheduleId)).to.not.be.reverted;
        });

        it("should allow emergency vesting acceleration", async function () {
            // Accelerate vesting due to emergency (e.g., company acquisition)
            await tokenVesting.connect(emergency).emergencyAccelerateVesting(scheduleId);

            // All tokens should become immediately claimable
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableAmount).to.equal(ethers.parseEther("200000"));
        });

        it("should allow emergency cliff removal", async function () {
            // Remove cliff in emergency situation
            await tokenVesting.connect(emergency).emergencyRemoveCliff(scheduleId);

            const schedule = await tokenVesting.getVestingSchedule(scheduleId);
            expect(schedule.cliffDuration).to.equal(0);

            // Should be able to claim immediately (TGE + some vested amount)
            const claimableAmount = await tokenVesting.calculateClaimableAmount(scheduleId);
            expect(claimableAmount).to.be.gt(ethers.parseEther("30000")); // More than just TGE
        });
    });

    describe("Bulk Emergency Operations", function () {
        beforeEach(async function () {
            // Create multiple schedules for testing
            const beneficiaries = [user1.address, user2.address, user3.address];
            const amounts = [
                ethers.parseEther("100000"),
                ethers.parseEther("75000"),
                ethers.parseEther("50000")
            ];

            for (let i = 0; i < beneficiaries.length; i++) {
                await tokenVesting.connect(admin).createLinearVestingSchedule(
                    beneficiaries[i],
                    amounts[i],
                    60 * 24 * 60 * 60,
                    365 * 24 * 60 * 60,
                    20,
                    BeneficiaryGroup.TEAM,
                    true
                );
            }
        });

        it("should allow bulk emergency termination", async function () {
            const scheduleIds = [1, 2, 3];

            await tokenVesting.connect(emergency).bulkEmergencyTerminate(scheduleIds);

            // All schedules should be terminated
            for (const id of scheduleIds) {
                const schedule = await tokenVesting.getVestingSchedule(id);
                expect(schedule.terminated).to.be.true;
            }
        });

        it("should allow bulk emergency revocation", async function () {
            const scheduleIds = [1, 2, 3];

            await tokenVesting.connect(emergency).bulkEmergencyRevoke(scheduleIds);

            // All schedules should be revoked
            for (const id of scheduleIds) {
                const schedule = await tokenVesting.getVestingSchedule(id);
                expect(schedule.revoked).to.be.true;
            }
        });

        it("should allow bulk beneficiary freezing", async function () {
            const beneficiaries = [user1.address, user2.address, user3.address];

            await tokenVesting.connect(emergency).bulkFreezeBeneficiaries(beneficiaries);

            // All beneficiaries should be frozen
            for (const beneficiary of beneficiaries) {
                expect(await tokenVesting.isBeneficiaryFrozen(beneficiary)).to.be.true;

                // Should not be able to claim
                await expect(
                    tokenVesting.connect(ethers.getSigner(beneficiary)).claimTokens(1)
                ).to.be.revertedWith("Beneficiary frozen");
            }
        });

        it("should allow selective emergency acceleration", async function () {
            // Accelerate only specific group (e.g., team members during acquisition)
            await tokenVesting.connect(emergency).emergencyAccelerateGroup(BeneficiaryGroup.TEAM);

            // All team schedules should be fully vested
            for (let i = 1; i <= 3; i++) {
                const claimableAmount = await tokenVesting.calculateClaimableAmount(i);
                const schedule = await tokenVesting.getVestingSchedule(i);
                expect(claimableAmount).to.equal(schedule.amount);
            }
        });
    });

    describe("Recovery and Restoration", function () {
        beforeEach(async function () {
            // Create and modify schedules for recovery testing
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            // User claims some tokens
            await tokenVesting.connect(user1).claimTokens(1);

            // Emergency modifications
            await tokenVesting.connect(emergency).emergencyTerminateSchedule(1);
        });

        it("should create schedule snapshots before emergency actions", async function () {
            // Create another schedule
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user2.address,
                ethers.parseEther("75000"),
                90 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.ADVISORS,
                true
            );

            // Take snapshot before emergency action
            const snapshotId = await tokenVesting.connect(admin).createEmergencySnapshot();

            // Perform emergency action
            await tokenVesting.connect(emergency).emergencyTerminateSchedule(2);

            // Verify snapshot exists
            const snapshot = await tokenVesting.getEmergencySnapshot(snapshotId);
            expect(snapshot.timestamp).to.be.gt(0);
            expect(snapshot.scheduleCount).to.equal(2);
        });

        it("should allow restoration from emergency snapshot", async function () {
            // Create snapshot before emergency actions
            const snapshotId = await tokenVesting.connect(admin).createEmergencySnapshot();

            // Perform additional emergency actions
            await tokenVesting.connect(emergency).emergencyTransferBeneficiary(1, user1.address, user2.address);

            // Restore from snapshot
            await tokenVesting.connect(admin).restoreFromEmergencySnapshot(snapshotId);

            // Schedule should be restored to original state
            const schedule = await tokenVesting.getVestingSchedule(1);
            expect(schedule.beneficiary).to.equal(user1.address);
            expect(schedule.terminated).to.be.false;
        });

        it("should track emergency action history", async function () {
            const actionCount = await tokenVesting.getEmergencyActionCount();
            expect(actionCount).to.be.gt(0); // From beforeEach setup

            const lastAction = await tokenVesting.getLastEmergencyAction();
            expect(lastAction.actionType).to.equal("TERMINATE_SCHEDULE");
            expect(lastAction.scheduleId).to.equal(1);
            expect(lastAction.executor).to.equal(emergency.address);
        });

        it("should allow admin to reverse emergency actions", async function () {
            // Reverse the termination
            await tokenVesting.connect(admin).reverseEmergencyAction(1);

            const schedule = await tokenVesting.getVestingSchedule(1);
            expect(schedule.terminated).to.be.false;

            // User should be able to claim again
            await expect(tokenVesting.connect(user1).claimTokens(1)).to.not.be.reverted;
        });
    });

    describe("Edge Cases and Error Handling", function () {
        it("should handle token contract upgrade scenarios", async function () {
            // Create schedule with current token
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            // Simulate token contract upgrade
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const newToken = await MockERC20.deploy("New TEACH Token", "TEACH2", ethers.parseEther("5000000000"));

            // Transfer equivalent amount to new token
            await newToken.transfer(await tokenVesting.getAddress(), ethers.parseEther("100000"));

            // Emergency token migration
            await tokenVesting.connect(emergency).emergencyMigrateToken(
                await newToken.getAddress(),
                [1], // Schedule IDs to migrate
                [ethers.parseEther("100000")] // New amounts
            );

            // Verify migration
            const migratedSchedule = await tokenVesting.getMigratedSchedule(1);
            expect(migratedSchedule.newToken).to.equal(await newToken.getAddress());
            expect(migratedSchedule.migrated).to.be.true;
        });

        it("should handle beneficiary wallet compromise", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("500000"),
                180 * 24 * 60 * 60,
                730 * 24 * 60 * 60,
                10,
                BeneficiaryGroup.TEAM,
                true
            );

            // Report wallet compromise
            await tokenVesting.connect(emergency).reportWalletCompromise(user1.address);

            // All schedules for this beneficiary should be frozen
            expect(await tokenVesting.isBeneficiaryFrozen(user1.address)).to.be.true;

            // Claims should be blocked
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Beneficiary frozen");

            // Emergency transfer to new secure wallet
            await tokenVesting.connect(emergency).emergencyTransferBeneficiary(1, user1.address, user2.address);

            // New beneficiary should be able to claim
            await expect(tokenVesting.connect(user2).claimTokens(1)).to.not.be.reverted;
        });

        it("should handle contract balance depletion scenarios", async function () {
            // Create large schedule that exceeds contract balance
            const contractBalance = await mockToken.balanceOf(await tokenVesting.getAddress());

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                contractBalance + ethers.parseEther("1000000"),
                0,
                365 * 24 * 60 * 60,
                100, // 100% immediate
                BeneficiaryGroup.TEAM,
                true
            );

            // Should detect insufficient balance during claim
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Insufficient contract balance");

            // Emergency balance adjustment
            await tokenVesting.connect(emergency).emergencyAdjustScheduleAmount(1, contractBalance);

            // Should now be able to claim
            await expect(tokenVesting.connect(user1).claimTokens(1)).to.not.be.reverted;
        });

        it("should handle extreme time manipulation attacks", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                86400, // 1 day cliff
                365 * 24 * 60 * 60,
                0, // No TGE
                BeneficiaryGroup.TEAM,
                true
            );

            // Set time manipulation protection
            await tokenVesting.connect(admin).enableTimeManipulationProtection();

            // Extreme time jump should be detected and limited
            await ethers.provider.send("evm_increaseTime", [10 * 365 * 24 * 60 * 60]); // 10 years
            await ethers.provider.send("evm_mine");

            // Should limit vesting calculation to reasonable bounds
            const claimableAmount = await tokenVesting.calculateClaimableAmount(1);
            expect(claimableAmount).to.be.lte(ethers.parseEther("100000")); // Full amount max
        });
    });

    describe("Data Corruption and Recovery", function () {
        beforeEach(async function () {
            // Create test data
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.TEAM,
                true
            );

            await tokenVesting.connect(user1).claimTokens(1);
        });

        it("should detect data corruption", async function () {
            const validation = await tokenVesting.validateDataIntegrity();
            expect(validation.isValid).to.be.true;

            // Simulate corruption detection
            const corruptionReport = await tokenVesting.detectCorruption();
            expect(corruptionReport.corruptedSchedules.length).to.equal(0);
        });

        it("should repair minor data inconsistencies", async function () {
            // Simulate minor inconsistency
            await tokenVesting.connect(admin).simulateDataInconsistency(1);

            // Auto-repair should fix it
            await tokenVesting.connect(admin).autoRepairInconsistencies();

            const validation = await tokenVesting.validateDataIntegrity();
            expect(validation.isValid).to.be.true;
        });

        it("should create emergency data backup", async function () {
            const backupId = await tokenVesting.connect(emergency).createEmergencyBackup();

            const backup = await tokenVesting.getEmergencyBackup(backupId);
            expect(backup.timestamp).to.be.gt(0);
            expect(backup.scheduleCount).to.equal(1);
            expect(backup.dataHash).to.not.equal(ethers.ZeroHash);
        });

        it("should restore from emergency backup", async function () {
            // Create backup
            const backupId = await tokenVesting.connect(emergency).createEmergencyBackup();

            // Simulate data corruption
            await tokenVesting.connect(admin).simulateDataCorruption();

            // Restore from backup
            await tokenVesting.connect(emergency).restoreFromBackup(backupId);

            // Data should be restored
            const validation = await tokenVesting.validateDataIntegrity();
            expect(validation.isValid).to.be.true;
        });
    });

    describe("Multi-Signature Emergency Operations", function () {
        beforeEach(async function () {
            // Create critical schedule requiring multi-sig for emergency operations
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("1000000"), // Large amount requiring multi-sig
                180 * 24 * 60 * 60,
                730 * 24 * 60 * 60,
                5,
                BeneficiaryGroup.TEAM,
                true
            );

            // Set multi-sig requirements
            await tokenVesting.connect(admin).setMultiSigRequirement(
                ethers.parseEther("500000"), // Threshold for multi-sig
                2 // Required signatures
            );
        });

        it("should require multiple signatures for large emergency operations", async function () {
            // First signature
            await tokenVesting.connect(emergency).proposeEmergencyTermination(1, "Security breach");

            // Should not be executed yet
            const schedule = await tokenVesting.getVestingSchedule(1);
            expect(schedule.terminated).to.be.false;

            // Second signature
            await tokenVesting.connect(admin).approveEmergencyProposal(1);

            // Should now be executed
            const updatedSchedule = await tokenVesting.getVestingSchedule(1);
            expect(updatedSchedule.terminated).to.be.true;
        });

        it("should timeout emergency proposals", async function () {
            // Propose emergency action
            const proposalId = await tokenVesting.connect(emergency).proposeEmergencyTermination(1, "Test");

            // Fast forward past timeout
            await ethers.provider.send("evm_increaseTime", [48 * 60 * 60]); // 48 hours
            await ethers.provider.send("evm_mine");

            // Proposal should be expired
            const proposal = await tokenVesting.getEmergencyProposal(proposalId);
            expect(proposal.expired).to.be.true;

            // Should not be able to approve expired proposal
            await expect(
                tokenVesting.connect(admin).approveEmergencyProposal(proposalId)
            ).to.be.revertedWith("Proposal expired");
        });
    });

    describe("Regulatory Compliance Emergency Features", function () {
        it("should allow emergency compliance freeze", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("200000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                15,
                BeneficiaryGroup.PARTNERS,
                true
            );

            // Emergency compliance freeze
            await tokenVesting.connect(emergency).emergencyComplianceFreeze(
                [user1.address],
                "Regulatory investigation"
            );

            // Should not be able to claim during freeze
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Compliance freeze active");
        });

        it("should allow emergency KYC reset", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("150000"),
                60 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                20,
                BeneficiaryGroup.ADVISORS,
                true
            );

            // Set initial KYC status
            await tokenVesting.connect(admin).setKYCStatus(user1.address, true);

            // Emergency KYC reset due to compliance issue
            await tokenVesting.connect(emergency).emergencyKYCReset([user1.address]);

            // Should require re-verification
            expect(await tokenVesting.getKYCStatus(user1.address)).to.be.false;

            // Claims should be blocked until re-verification
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("KYC verification required");
        });

        it("should handle emergency jurisdiction restrictions", async function () {
            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                30 * 24 * 60 * 60,
                180 * 24 * 60 * 60,
                25,
                BeneficiaryGroup.PUBLIC_SALE,
                false
            );

            // Emergency jurisdiction restriction
            await tokenVesting.connect(emergency).emergencyJurisdictionRestriction(
                ["US", "EU"], // Restricted jurisdictions
                "Regulatory changes"
            );

            // Set user jurisdiction
            await tokenVesting.connect(admin).setBeneficiaryJurisdiction(user1.address, "US");

            // Claims should be blocked for restricted jurisdictions
            await expect(
                tokenVesting.connect(user1).claimTokens(1)
            ).to.be.revertedWith("Jurisdiction restricted");
        });
    });

    describe("System Recovery and Failsafe", function () {
        it("should implement dead man's switch", async function () {
            // Set up dead man's switch
            await tokenVesting.connect(admin).setupDeadManSwitch(
                7 * 24 * 60 * 60, // 7 days
                treasury.address // Beneficiary for unclaimed tokens
            );

            await tokenVesting.connect(admin).createLinearVestingSchedule(
                user1.address,
                ethers.parseEther("100000"),
                0,
                365 * 24 * 60 * 60,
                0, // No TGE
                BeneficiaryGroup.TEAM,
                true
            );

            // Simulate no admin activity for trigger period
            await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]); // 8 days
            await ethers.provider.send("evm_mine");

            // Dead man's switch should be triggered
            expect(await tokenVesting.isDeadManSwitchTriggered()).to.be.true;

            // Emergency recovery should transfer tokens to treasury
            await tokenVesting.triggerEmergencyRecovery();

            const treasuryBalance = await mockToken.balanceOf(treasury.address);
            expect(treasuryBalance).to.be.gt(0);
        });

        it("should allow admin heartbeat to prevent dead man's switch", async function () {
            await tokenVesting.connect(admin).setupDeadManSwitch(
                7 * 24 * 60 * 60,
                treasury.address
            );

            // Admin sends heartbeat
            await tokenVesting.connect(admin).adminHeartbeat();

            // Fast forward but not past deadline
            await ethers.provider.send("evm_increaseTime", [6 * 24 * 60 * 60]); // 6 days
            await ethers.provider.send("evm_mine");

            // Send another heartbeat
            await tokenVesting.connect(admin).adminHeartbeat();

            // Fast forward again
            await ethers.provider.send("evm_increaseTime", [6 * 24 * 60 * 60]); // 6 more days
            await ethers.provider.send("evm_mine");

            // Dead man's switch should not be triggered
            expect(await tokenVesting.isDeadManSwitchTriggered()).to.be.false;
        });
    });
});