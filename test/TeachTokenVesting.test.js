const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TeachTokenVesting Contract", function () {
    let teachToken;
    let vesting;
    let owner;
    let beneficiary1;
    let beneficiary2;
    let teamMember;
    let advisor;

    const initialSupply = ethers.parseEther("10000000"); // 10M tokens for testing

    // Enum definitions to match contract
    const VestingType = {
        LINEAR: 0,
        QUARTERLY: 1,
        MILESTONE: 2
    };

    const BeneficiaryGroup = {
        TEAM: 0,
        ADVISORS: 1,
        PARTNERS: 2,
        PUBLIC_SALE: 3,
        ECOSYSTEM: 4
    };

    beforeEach(async function () {
        // Get the contract factories and signers
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const TeachTokenVesting = await ethers.getContractFactory("TeachTokenVesting");
        [owner, beneficiary1, beneficiary2, teamMember, advisor] = await ethers.getSigners();

        // Deploy token
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.waitForDeployment();

        // Mint tokens to owner for vesting distribution
        await teachToken.mint(owner.address, initialSupply);

        // Deploy vesting contract
        vesting = await upgrades.deployProxy(TeachTokenVesting, [await teachToken.getAddress()], {
            initializer: "initialize",
        });
        await vesting.waitForDeployment();

        // Transfer tokens to vesting contract
        await teachToken.transfer(await vesting.getAddress(), initialSupply);
    });

    describe("Deployment", function () {
        it("Should set the right token", async function () {
            expect(await vesting.token()).to.equal(await teachToken.getAddress());
        });

        it("Should set the right owner", async function () {
            expect(await vesting.owner()).to.equal(owner.address);
        });

        it("Should have correct token balance", async function () {
            expect(await teachToken.balanceOf(await vesting.getAddress())).to.equal(initialSupply);
        });
    });

    describe("Linear Vesting", function () {
        let scheduleId;
        const vestAmount = ethers.parseEther("1000"); // 1000 tokens
        const cliffDuration = 90 * 24 * 60 * 60; // 90 days
        const vestingDuration = 365 * 24 * 60 * 60; // 1 year
        const tgePercentage = 10; // 10% at TGE

        beforeEach(async function () {
            // Create a linear vesting schedule
            const tx = await vesting.createLinearVestingSchedule(
                beneficiary1.address,
                vestAmount,
                cliffDuration,
                vestingDuration,
                tgePercentage,
                BeneficiaryGroup.TEAM,
                true // revocable
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ScheduleCreated');
            scheduleId = event ? event.args[0] : 1; // Fallback to ID 1 if event not found
        });

        it("Should create a linear vesting schedule correctly", async function () {
            const schedule = await vesting.getScheduleDetails(scheduleId);

            expect(schedule.beneficiary).to.equal(beneficiary1.address);
            expect(schedule.totalAmount).to.equal(vestAmount);
            expect(schedule.cliffDuration).to.equal(cliffDuration);
            expect(schedule.duration).to.equal(vestingDuration);
            expect(schedule.tgePercentage).to.equal(tgePercentage);
            expect(schedule.vestingType).to.equal(VestingType.LINEAR);
            expect(schedule.group).to.equal(BeneficiaryGroup.TEAM);
            expect(schedule.revocable).to.equal(true);
        });

        it("Should not allow claiming before TGE", async function () {
            await expect(
                vesting.connect(beneficiary1).claimTokens(scheduleId)
            ).to.be.revertedWith("TGE not occurred yet");
        });

        it("Should allow claiming TGE tokens after TGE", async function () {
            // Set TGE
            await vesting.setTGE(Math.floor(Date.now() / 1000));

            // Expect TGE percentage to be claimable
            const expectedClaimable = vestAmount * BigInt(tgePercentage) / 100n;
            expect(await vesting.calculateClaimableAmount(scheduleId)).to.equal(expectedClaimable);

            // Claim tokens
            await vesting.connect(beneficiary1).claimTokens(scheduleId);

            // Check balance
            expect(await teachToken.balanceOf(beneficiary1.address)).to.equal(expectedClaimable);
        });

        it("Should vest tokens gradually over time", async function () {
            // Set TGE
            const tgeTime = Math.floor(Date.now() / 1000);
            await vesting.setTGE(tgeTime);

            // Claim TGE tokens
            await vesting.connect(beneficiary1).claimTokens(scheduleId);

            // Fast forward to the middle of vesting period (after cliff)
            await time.increaseTo(tgeTime + cliffDuration + vestingDuration / 2);

            // Calculate expected vested tokens (50% of remaining 90% after cliff + initial 10%)
            const tgeAmount = vestAmount * BigInt(tgePercentage) / 100n;
            const remainingAmount = vestAmount - tgeAmount;
            const vestedAmount = remainingAmount / 2n;

            // We've already claimed TGE amount, so only additional vested tokens should be claimable
            expect(await vesting.calculateClaimableAmount(scheduleId)).to.be.approximately(
                vestedAmount,
                ethers.parseEther("0.1") // Allow small rounding difference
            );
        });

        it("Should allow revoking a vesting schedule", async function () {
            // Set TGE
            const tgeTime = Math.floor(Date.now() / 1000);
            await vesting.setTGE(tgeTime);

            // Fast forward to the middle of vesting period
            await time.increaseTo(tgeTime + cliffDuration + vestingDuration / 2);

            // Record balances before revocation
            const ownerBalanceBefore = await teachToken.balanceOf(owner.address);

            // Revoke the schedule
            await vesting.revokeSchedule(scheduleId);

            // Check schedule is revoked
            const schedule = await vesting.getScheduleDetails(scheduleId);
            expect(schedule.revoked).to.equal(true);

            // Owner should receive unvested tokens
            const ownerBalanceAfter = await teachToken.balanceOf(owner.address);
            expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);
        });
    });

    describe("Quarterly Vesting", function () {
        let scheduleId;
        const totalAmount = ethers.parseEther("1000"); // 1000 tokens
        const initialAmount = ethers.parseEther("200"); // 200 tokens (20% initial)
        const releasesCount = 4; // Quarterly for 1 year
        const firstReleaseTime = Math.floor(Date.now() / 1000) + 90 * 24 * 60 * 60; // 90 days from now

        beforeEach(async function () {
            // Create a quarterly vesting schedule
            const tx = await vesting.createQuarterlyVestingSchedule(
                beneficiary2.address,
                totalAmount,
                initialAmount,
                releasesCount,
                firstReleaseTime,
                BeneficiaryGroup.ADVISORS,
                true // revocable
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ScheduleCreated');
            scheduleId = event ? event.args[0] : 1; // Fallback to ID 1 if event not found
        });

        it("Should create a quarterly vesting schedule correctly", async function () {
            const schedule = await vesting.getScheduleDetails(scheduleId);

            expect(schedule.beneficiary).to.equal(beneficiary2.address);
            expect(schedule.totalAmount).to.equal(totalAmount);
            expect(schedule.vestingType).to.equal(VestingType.QUARTERLY);
            expect(schedule.group).to.equal(BeneficiaryGroup.ADVISORS);
            expect(schedule.revocable).to.equal(true);

            // Check TGE percentage was calculated correctly (20%)
            expect(schedule.tgePercentage).to.equal(20);
        });

        it("Should allow quarterly releases", async function () {
            // Set TGE
            await vesting.setTGE(Math.floor(Date.now() / 1000));

            // Claim initial amount
            await vesting.connect(beneficiary2).claimTokens(scheduleId);
            expect(await teachToken.balanceOf(beneficiary2.address)).to.equal(initialAmount);

            // Fast forward to first quarterly release
            await time.increaseTo(firstReleaseTime + 1);

            // Calculate expected release amount (25% of remaining 80%)
            const remainingAmount = totalAmount - initialAmount;
            const quarterlyAmount = remainingAmount / BigInt(releasesCount);

            // First quarterly release should be available
            const claimableAmount = await vesting.calculateClaimableAmount(scheduleId);
            expect(claimableAmount).to.be.approximately(
                quarterlyAmount,
                ethers.parseEther("0.1") // Allow small rounding difference
            );

            // Claim first quarterly release
            await vesting.connect(beneficiary2).claimTokens(scheduleId);
            expect(await teachToken.balanceOf(beneficiary2.address)).to.be.approximately(
                initialAmount + quarterlyAmount,
                ethers.parseEther("0.1") // Allow small rounding difference
            );
        });
    });

    describe("Milestone Vesting", function () {
        let scheduleId;
        const totalAmount = ethers.parseEther("1000"); // 1000 tokens
        const tgePercentage = 10; // 10% at TGE

        beforeEach(async function () {
            // Create a milestone-based vesting schedule
            const tx = await vesting.createMilestoneVestingSchedule(
                advisor.address,
                totalAmount,
                tgePercentage,
                BeneficiaryGroup.PARTNERS,
                true // revocable
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ScheduleCreated');
            scheduleId = event ? event.args[0] : 1; // Fallback to ID 1 if event not found

            // Add milestones
            await vesting.addMilestone(scheduleId, "Product Launch", 30);
            await vesting.addMilestone(scheduleId, "1000 Users", 30);
            await vesting.addMilestone(scheduleId, "First Revenue", 30);
        });

        it("Should create a milestone vesting schedule correctly", async function () {
            const schedule = await vesting.getScheduleDetails(scheduleId);

            expect(schedule.beneficiary).to.equal(advisor.address);
            expect(schedule.totalAmount).to.equal(totalAmount);
            expect(schedule.tgePercentage).to.equal(tgePercentage);
            expect(schedule.vestingType).to.equal(VestingType.MILESTONE);
            expect(schedule.group).to.equal(BeneficiaryGroup.PARTNERS);
            expect(schedule.revocable).to.equal(true);
        });

        it("Should release tokens on milestone achievement", async function () {
            // Set TGE
            await vesting.setTGE(Math.floor(Date.now() / 1000));

            // Claim TGE tokens
            await vesting.connect(advisor).claimTokens(scheduleId);
            expect(await teachToken.balanceOf(advisor.address)).to.equal(totalAmount * BigInt(tgePercentage) / 100n);

            // Mark first milestone as achieved
            await vesting.achieveMilestone(scheduleId, 0);

            // Check claimable amount (30% of total)
            const milestoneAmount = totalAmount * 30n / 100n;
            expect(await vesting.calculateClaimableAmount(scheduleId)).to.equal(milestoneAmount);

            // Claim milestone tokens
            await vesting.connect(advisor).claimTokens(scheduleId);
            expect(await teachToken.balanceOf(advisor.address)).to.equal(
                (totalAmount * BigInt(tgePercentage) / 100n) + milestoneAmount
            );
        });
    });

    describe("Batch Operations", function () {
        it("Should create batch linear vesting schedules", async function () {
            const beneficiaries = [beneficiary1.address, beneficiary2.address];
            const amounts = [ethers.parseEther("500"), ethers.parseEther("700")];
            const cliffDuration = 90 * 24 * 60 * 60; // 90 days
            const duration = 365 * 24 * 60 * 60; // 1 year
            const tgePercentage = 10;

            await vesting.batchCreateLinearVestingSchedules(
                beneficiaries,
                amounts,
                cliffDuration,
                duration,
                tgePercentage,
                BeneficiaryGroup.TEAM,
                true // revocable
            );

            // Check schedules were created
            const schedule1 = await vesting.getScheduleDetails(1);
            const schedule2 = await vesting.getScheduleDetails(2);

            expect(schedule1.beneficiary).to.equal(beneficiary1.address);
            expect(schedule1.totalAmount).to.equal(amounts[0]);
            expect(schedule2.beneficiary).to.equal(beneficiary2.address);
            expect(schedule2.totalAmount).to.equal(amounts[1]);
        });

        it("Should create batch public sale vesting schedules", async function () {
            const beneficiaries = [beneficiary1.address, beneficiary2.address];
            const amounts = [ethers.parseEther("500"), ethers.parseEther("700")];

            await vesting.batchCreatePublicSaleVestingSchedules(beneficiaries, amounts);

            // Check schedules were created
            const schedule1 = await vesting.getScheduleDetails(1);
            const schedule2 = await vesting.getScheduleDetails(2);

            expect(schedule1.beneficiary).to.equal(beneficiary1.address);
            expect(schedule1.totalAmount).to.equal(amounts[0]);
            expect(schedule1.group).to.equal(BeneficiaryGroup.PUBLIC_SALE);
            expect(schedule1.tgePercentage).to.equal(20); // Default for public sale
            expect(schedule1.revocable).to.equal(false); // Public sale not revocable
        });
    });

    describe("Administrative Functions", function () {
        it("Should allow setting registry", async function () {
            // Deploy a mock registry
            const mockRegistry = await ethers.deployContract("ContractRegistry");
            await mockRegistry.initialize();

            await vesting.setRegistry(await mockRegistry.getAddress());
            expect(await vesting.registry()).to.equal(await mockRegistry.getAddress());
        });

        it("Should allow updating token address", async function () {
            // Deploy a new token
            const newToken = await upgrades.deployProxy(
                await ethers.getContractFactory("TeachToken"),
                [],
                { initializer: "initialize" }
            );

            // Set new token
            await vesting.setToken(await newToken.getAddress());
            expect(await vesting.token()).to.equal(await newToken.getAddress());
        });

        it("Should allow pausing and unpausing", async function () {
            // Set TGE to enable claims
            await vesting.setTGE(Math.floor(Date.now() / 1000));

            // Create a schedule
            await vesting.createLinearVestingSchedule(
                beneficiary1.address,
                ethers.parseEther("1000"),
                0,
                365 * 24 * 60 * 60,
                10,
                BeneficiaryGroup.TEAM,
                true
            );

            // Pause the contract
            await vesting.pause();

            // Attempt to claim (should fail)
            await expect(
                vesting.connect(beneficiary1).claimTokens(1)
            ).to.be.revertedWith("TeachTokenVesting: paused");

            // Unpause
            await vesting.unpause();

            // Now claiming should work
            await vesting.connect(beneficiary1).claimTokens(1);
            expect(await teachToken.balanceOf(beneficiary1.address)).to.be.gt(0);
        });
    });

    describe("Upgradeability", function() {
        it("Should be upgradeable using the UUPS pattern", async function() {
            // Create a schedule before upgrade
            await vesting.createLinearVestingSchedule(
                beneficiary1.address,
                ethers.parseEther("1000"),
                90 * 24 * 60 * 60,
                365 * 24 * 60 * 60,
                10,
                BeneficiaryGroup.TEAM,
                true
            );

            // Deploy a new implementation
            const VestingV2 = await ethers.getContractFactory("TeachTokenVesting");

            // Upgrade to new implementation
            const upgradedVesting = await upgrades.upgradeProxy(
                await vesting.getAddress(),
                VestingV2
            );

            // Check that the address stayed the same
            expect(await upgradedVesting.getAddress()).to.equal(await vesting.getAddress());

            // Verify state is preserved
            const schedule = await upgradedVesting.getScheduleDetails(1);
            expect(schedule.beneficiary).to.equal(beneficiary1.address);
            expect(schedule.totalAmount).to.equal(ethers.parseEther("1000"));
        });
    });
});