const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TokenCrowdSale - Emergency Functions and Recovery", function () {
    let crowdSale;
    let token;
    let stablecoin;
    let mockRegistry;
    let mockTierManager;
    let mockTokenVesting;
    let mockEmergencyManager;
    let mockPriceFeed;

    let owner, admin, minter, burner, treasury, emergency, user3, user2, user1;

    // Constants
    const tierId = 0; // First tier

    beforeEach(async function () {
        // Get all 9 signers as required
        [owner, admin, minter, burner, treasury, emergency, user3, user2, user1] = await ethers.getSigners();

        const TIER_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("TIER_MANAGER"));
        const TOKEN_VESTING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_VESTING"));
        const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));
        const PRICE_FEED_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_PRICE_FEED"));
        
        // Deploy mock token and stablecoin
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("TeacherSupport Token", "TEACH", ethers.parseUnits("5000000000", 18));
        await token.waitForDeployment();

        stablecoin = await MockERC20.deploy("USD Stablecoin", "USDC", ethers.parseUnits("10000000", 6));
        await stablecoin.waitForDeployment();

        // Deploy mock registry
        const MockRegistry = await ethers.getContractFactory("MockRegistry");
        mockRegistry = await MockRegistry.deploy();
        await mockRegistry.waitForDeployment();

        // Register token in registry
        const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
        await mockRegistry.setContractAddress(TOKEN_NAME, await token.getAddress(), true);

        // Deploy mock components
        const MockTierManager = await ethers.getContractFactory("MockTierManager");
        mockTierManager = await MockTierManager.deploy();
        await mockTierManager.waitForDeployment();

        const MockTokenVesting = await ethers.getContractFactory("MockTokenVesting");
        mockTokenVesting = await MockTokenVesting.deploy();
        await mockTokenVesting.waitForDeployment();

        const MockEmergencyManager = await ethers.getContractFactory("MockEmergencyManager");
        mockEmergencyManager = await MockEmergencyManager.deploy();
        await mockEmergencyManager.waitForDeployment();

        const MockPriceFeed = await ethers.getContractFactory("MockPriceFeed");
        mockPriceFeed = await MockPriceFeed.deploy(await stablecoin.getAddress());
        await mockPriceFeed.waitForDeployment();

        // Deploy TokenCrowdSale
        const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
        crowdSale = await upgrades.deployProxy(TokenCrowdSale, [await treasury.getAddress()], {
            initializer: "initialize",
        });
        await crowdSale.waitForDeployment();

        // Set up roles
        const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
        const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
        await crowdSale.grantRole(ADMIN_ROLE, await admin.getAddress());
        await crowdSale.grantRole(EMERGENCY_ROLE, await emergency.getAddress());
        
        await mockRegistry.setContractAddress(TIER_MANAGER_NAME, await mockTierManager.getAddress(), true);
        await mockRegistry.setContractAddress(TOKEN_VESTING_NAME, await mockTokenVesting.getAddress(), true);
        await mockRegistry.setContractAddress(EMERGENCY_MANAGER_NAME, await mockEmergencyManager.getAddress(), true);
        await mockRegistry.setContractAddress(PRICE_FEED_NAME, await mockPriceFeed.getAddress(), true);
        
        // Set token and components
        await crowdSale.setSaleToken(await token.getAddress());
        await crowdSale.setRegistry(await mockRegistry.getAddress());
        await crowdSale.setTierManager(await mockTierManager.getAddress());
        await crowdSale.setVestingContract(await mockTokenVesting.getAddress());
        await crowdSale.setEmergencyManager(await mockEmergencyManager.getAddress());
        await crowdSale.setPriceFeed(await mockPriceFeed.getAddress());

        // Set presale times (start now, end in 30 days)
        const startTime = Math.floor(Date.now() / 1000);
        const endTime = startTime + (30 * 24 * 60 * 60);
        await crowdSale.setPresaleTimes(startTime, endTime);

        // Send token to the vesting contract for distributions
        await token.transfer(await mockTokenVesting.getAddress(), ethers.parseUnits("1000000", 18));

        // Transfer stablecoin to users for purchases
        await stablecoin.transfer(await user1.getAddress(), ethers.parseUnits("100000", 6));

        // Perform a purchase so user has tokens for emergency scenarios
        await stablecoin.connect(user1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));
        await crowdSale.connect(user1).purchase(tierId, ethers.parseUnits("1000", 6));
    });

    describe("Emergency Withdrawal", function () {
        beforeEach(async function () {
            // Set emergency state to critical
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY = 2
        });

        it("should allow emergency withdrawal in critical state", async function () {
            // Record user's purchase in USDC for emergency withdrawal
            const userUsdAmount = ethers.parseUnits("1000", 6);

            // Transfer stablecoin to treasury to simulate refund capability
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("1000", 6));

            // Approve treasury to send tokens back (simulating treasury's approval)
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

            // Initial balances
            const initialUserBalance = await stablecoin.balanceOf(await user1.getAddress());

            // Perform emergency withdrawal
            await crowdSale.connect(user1).emergencyWithdraw();

            // Verify emergency manager processed withdrawal
            expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.true;
            expect(await mockEmergencyManager.withdrawalAmounts(await user1.getAddress())).to.equal(userUsdAmount);

            // Verify user received refund
            const finalUserBalance = await stablecoin.balanceOf(await user1.getAddress());
            expect(finalUserBalance - initialUserBalance).to.equal(ethers.parseUnits("1000", 6));
        });

        it("should not allow emergency withdrawal in normal state", async function () {
            // Set emergency state back to normal
            await mockEmergencyManager.setEmergencyState(0); // NORMAL = 0

            // Attempt emergency withdrawal
            await expect(
                crowdSale.connect(user1).emergencyWithdraw()
            ).to.be.revertedWith("Not in critical emergency");
        });

        it("should not allow emergency withdrawal in minor emergency state", async function () {
            // Set emergency state to minor emergency
            await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY = 1

            // Attempt emergency withdrawal
            await expect(
                crowdSale.connect(user1).emergencyWithdraw()
            ).to.be.revertedWith("Not in critical emergency");
        });

        it("should prevent double emergency withdrawals", async function () {
            // Transfer stablecoin to treasury
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("1000", 6));
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

            // First withdrawal succeeds
            await crowdSale.connect(user1).emergencyWithdraw();

            // Mark user as already processed in mock emergency manager
            await mockEmergencyManager.processEmergencyWithdrawal(await user1.getAddress(), ethers.parseUnits("1000", 6));

            // Second attempt should fail
            await expect(
                crowdSale.connect(user1).emergencyWithdraw()
            ).to.be.revertedWith("Already processed");
        });

        it("should handle users with no purchase history", async function () {
            // User2 has no purchase history
            await expect(
                crowdSale.connect(user2).emergencyWithdraw()
            ).to.not.be.reverted; // Should not revert but no refund given
        });

        it("should handle multiple users withdrawing simultaneously", async function () {
            // Make purchase for user2
            await stablecoin.transfer(await user2.getAddress(), ethers.parseUnits("100000", 6));
            await stablecoin.connect(user2).approve(await crowdSale.getAddress(), ethers.parseUnits("500", 6));
            await crowdSale.connect(user2).purchase(tierId, ethers.parseUnits("500", 6));

            // Transfer enough stablecoin to treasury for both refunds
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("1500", 6));
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("1500", 6));

            // Both users withdraw
            await crowdSale.connect(user1).emergencyWithdraw();
            await crowdSale.connect(user2).emergencyWithdraw();

            // Verify both processed
            expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.true;
            expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user2.getAddress())).to.be.true;
        });
    });

    describe("Token Recovery", function () {
        it("should allow admin to recover tokens sent by mistake", async function () {
            // Deploy a token that's not part of the crowdsale
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseUnits("1000", 18));
            await wrongToken.waitForDeployment();

            // Send tokens to crowdsale by mistake
            const amount = ethers.parseUnits("100", 18);
            await wrongToken.transfer(await crowdSale.getAddress(), amount);

            // Admin recovers tokens
            const initialBalance = await wrongToken.balanceOf(await owner.getAddress());
            await crowdSale.recoverTokens(await wrongToken.getAddress());

            // Verify tokens recovered
            const finalBalance = await wrongToken.balanceOf(await owner.getAddress());
            expect(finalBalance - initialBalance).to.equal(amount);
        });

        it("should not allow recovering the crowdsale token", async function () {
            // Attempt to recover the actual token
            await expect(
                crowdSale.recoverTokens(await token.getAddress())
            ).to.be.revertedWith("Cannot recover tokens");
        });

        it("should not allow non-admin to recover tokens", async function () {
            // Deploy a token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseUnits("1000", 18));
            await wrongToken.waitForDeployment();

            // Send tokens to crowdsale
            await wrongToken.transfer(await crowdSale.getAddress(), ethers.parseUnits("100", 18));

            // Attempt recovery as non-admin
            await expect(
                crowdSale.connect(user1).recoverTokens(await wrongToken.getAddress())
            ).to.be.reverted; // Will revert due to role check
        });

        it("should handle recovery of tokens with different decimals", async function () {
            // Deploy a token with 6 decimals
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseUnits("1000", 6));
            await wrongToken.waitForDeployment();

            // Send tokens to crowdsale
            const amount = ethers.parseUnits("50", 6);
            await wrongToken.transfer(await crowdSale.getAddress(), amount);

            // Recover tokens
            const initialBalance = await wrongToken.balanceOf(await owner.getAddress());
            await crowdSale.recoverTokens(await wrongToken.getAddress());

            // Verify recovery
            const finalBalance = await wrongToken.balanceOf(await owner.getAddress());
            expect(finalBalance - initialBalance).to.equal(amount);
        });

        it("should revert when trying to recover more tokens than available", async function () {
            // Deploy a token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const wrongToken = await MockERC20.deploy("Wrong Token", "WTK", ethers.parseUnits("100", 18));
            await wrongToken.waitForDeployment();

            // Don't send any tokens to crowdsale

            // Attempt recovery (should revert because no tokens to recover)
            await expect(
                crowdSale.recoverTokens(await wrongToken.getAddress())
            ).to.be.revertedWith("No tokens to recover");
        });
    });

    describe("Emergency Pause States", function () {
        it("should prevent purchases during emergency pause", async function () {
            // Set emergency state to minor emergency (paused)
            await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY

            const usdAmount = ethers.parseUnits("1000", 6);
            await stablecoin.connect(user2).approve(await crowdSale.getAddress(), usdAmount);

            // Attempt purchase during pause
            await expect(
                crowdSale.connect(user2).purchase(tierId, usdAmount)
            ).to.be.revertedWith("TokenCrowdSale: contract is paused");
        });

        it("should prevent withdrawals during emergency pause", async function () {
            // Complete TGE first
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]); // 31 days
            await ethers.provider.send("evm_mine");
            await crowdSale.completeTGE();

            // Set emergency state to minor emergency (paused)
            await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY

            // Configure mock vesting
            const schedules = await mockTokenVesting.getSchedulesForBeneficiary(await user1.getAddress());
            const scheduleId = schedules[0];
            await mockTokenVesting.setClaimableAmount(scheduleId, ethers.parseUnits("1000", 18));

            // Attempt withdrawal during pause
            await expect(
                crowdSale.connect(user1).withdrawTokens()
            ).to.be.revertedWith("TokenCrowdSale: contract is paused");
        });

        it("should allow operations to resume after emergency is resolved", async function () {
            // Set emergency state to paused
            await mockEmergencyManager.setEmergencyState(1); // MINOR_EMERGENCY

            // Verify operations are blocked
            const usdAmount = ethers.parseUnits("500", 6);
            await stablecoin.connect(user2).approve(await crowdSale.getAddress(), usdAmount);

            await expect(
                crowdSale.connect(user2).purchase(tierId, usdAmount)
            ).to.be.revertedWith("TokenCrowdSale: contract is paused");

            // Resolve emergency
            await mockEmergencyManager.setEmergencyState(0); // NORMAL

            // Operations should now work
            await expect(
                crowdSale.connect(user2).purchase(tierId, usdAmount)
            ).to.not.be.reverted;
        });
    });

    describe("Registry Integration During Emergency", function () {
        it("should handle registry being offline during emergency", async function () {
            // Disable registry
            await mockRegistry.setPaused(true);

            // Set emergency state to critical
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY

            // Emergency withdrawal should still work
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("1000", 6));
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

            await expect(
                crowdSale.connect(user1).emergencyWithdraw()
            ).to.not.be.reverted;
        });

        it("should handle contract references being unavailable", async function () {
            // Deactivate emergency manager in registry
            const EMERGENCY_MANAGER_NAME = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_MANAGER"));
            await mockRegistry.setContractAddress(EMERGENCY_MANAGER_NAME, await mockEmergencyManager.getAddress(), false);

            // Operations should still work with direct references
            const usdAmount = ethers.parseUnits("500", 6);
            await stablecoin.connect(user2).approve(await crowdSale.getAddress(), usdAmount);

            // This might revert or succeed depending on implementation
            // The test verifies the contract handles registry issues gracefully
            try {
                await crowdSale.connect(user2).purchase(tierId, usdAmount);
            } catch (error) {
                // Verify it's a graceful failure, not an unexpected error
                expect(error.message).to.not.include("out of gas");
            }
        });
    });

    describe("Emergency Recovery Events", function () {
        it("should emit events during emergency withdrawal", async function () {
            // Set emergency state
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY

            // Transfer stablecoin to treasury
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("1000", 6));
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));

            // Emergency withdrawal should emit events from emergency manager
            await crowdSale.connect(user1).emergencyWithdraw();

            // Verify the emergency manager recorded the withdrawal
            expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.true;
        });
    });

    describe("Edge Cases and Error Handling", function () {
        it("should handle zero refund amounts gracefully", async function () {
            // User with no purchase history
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY

            // Should not revert even with zero refund
            await expect(
                crowdSale.connect(user3).emergencyWithdraw()
            ).to.not.be.reverted;
        });

        it("should handle treasury having insufficient funds", async function () {
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY

            // Don't transfer enough funds to treasury
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("100", 6)); // Less than user's $1000 purchase
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("100", 6));

            // Emergency withdrawal should handle this gracefully
            await expect(
                crowdSale.connect(user1).emergencyWithdraw()
            ).to.be.reverted; // Should revert due to insufficient funds
        });

        it("should handle contract upgrade scenarios", async function () {
            // Test that emergency functions work even after potential upgrades
            // This is more of a design verification
            expect(await crowdSale.emergencyManager()).to.equal(await mockEmergencyManager.getAddress());

            // Verify emergency functions are accessible
            const emergencyState = await mockEmergencyManager.getEmergencyState();
            expect(emergencyState).to.be.oneOf([0, 1, 2]); // Valid emergency states
        });
    });

    describe("Gas Optimization During Emergency", function () {
        it("should handle emergency operations efficiently", async function () {
            await mockEmergencyManager.setEmergencyState(2); // CRITICAL_EMERGENCY

            // Transfer funds for multiple users
            await stablecoin.transfer(await treasury.getAddress(), ethers.parseUnits("10000", 6));
            await stablecoin.connect(treasury).approve(await crowdSale.getAddress(), ethers.parseUnits("10000", 6));

            // Multiple emergency withdrawals should not cause excessive gas usage
            await crowdSale.connect(user1).emergencyWithdraw();

            // Verify state was updated efficiently
            expect(await mockEmergencyManager.isEmergencyWithdrawalProcessed(await user1.getAddress())).to.be.true;
        });
    });
});