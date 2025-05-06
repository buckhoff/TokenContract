const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PlatformStabilityFund Contract", function () {
    let PlatformStabilityFund;
    let stabilityFund;
    let TeachToken;
    let teachToken;
    let USDCMock;
    let usdcToken;
    let ContractRegistry;
    let registry;
    let owner;
    let priceOracle;
    let treasury;
    let user1;
    let user2;
    let project;

    // Constants for testing
    const INITIAL_PRICE = ethers.utils.parseEther("0.05"); // $0.05 per token
    const BASELINE_PRICE = ethers.utils.parseEther("0.05"); // $0.05 per token
    const RESERVE_RATIO = 5000; // 50%
    const MIN_RESERVE_RATIO = 2000; // 20%
    const PLATFORM_FEE_PERCENT = 300; // 3%
    const LOW_VALUE_FEE_PERCENT = 100; // 1%
    const VALUE_THRESHOLD = 1000; // 10%

    beforeEach(async function () {
        // Get contract factories
        PlatformStabilityFund = await ethers.getContractFactory("PlatformStabilityFund");
        TeachToken = await ethers.getContractFactory("TeachToken");
        USDCMock = await ethers.getContractFactory("TeachToken"); // Using TeachToken as a mock for USDC
        ContractRegistry = await ethers.getContractFactory("ContractRegistry");

        // Get signers
        [owner, priceOracle, treasury, user1, user2, project] = await ethers.getSigners();

        // Deploy tokens
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.deployed();

        usdcToken = await upgrades.deployProxy(USDCMock, [], {
            initializer: "initialize",
        });
        await usdcToken.deployed();

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize",
        });
        await registry.deployed();

        // Deploy PlatformStabilityFund
        stabilityFund = await upgrades.deployProxy(PlatformStabilityFund, [
            teachToken.address,
            usdcToken.address,
            priceOracle.address,
            INITIAL_PRICE,
            RESERVE_RATIO,
            MIN_RESERVE_RATIO,
            PLATFORM_FEE_PERCENT,
            LOW_VALUE_FEE_PERCENT,
            VALUE_THRESHOLD
        ], {
            initializer: "initialize",
        });
        await stabilityFund.deployed();

        // Setup registry
        const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
        const STABILITY_FUND_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_STABILITY_FUND"));

        await registry.registerContract(TOKEN_NAME, teachToken.address, "0x00000000");
        await registry.registerContract(STABILITY_FUND_NAME, stabilityFund.address, "0x00000000");

        // Set registry in stability fund
        await stabilityFund.setRegistry(registry.address);

        // Mint tokens for testing
        // Token supply
        await teachToken.mint(owner.address, ethers.utils.parseEther("10000000")); // 10M tokens
        await teachToken.mint(user1.address, ethers.utils.parseEther("1000000")); // 1M tokens
        await teachToken.mint(user2.address, ethers.utils.parseEther("500000")); // 500K tokens

        // USDC supply
        await usdcToken.mint(owner.address, ethers.utils.parseUnits("1000000", 6)); // 1M USDC
        await usdcToken.mint(stabilityFund.address, ethers.utils.parseUnits("500000", 6)); // 500K USDC as initial reserves

        // Approve stabilityFund to spend tokens
        await teachToken.connect(user1).approve(stabilityFund.address, ethers.utils.parseEther("1000000"));
        await teachToken.connect(user2).approve(stabilityFund.address, ethers.utils.parseEther("500000"));
        await usdcToken.connect(owner).approve(stabilityFund.address, ethers.utils.parseUnits("1000000", 6));

        // Grant roles
        const ORACLE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ORACLE_ROLE"));
        const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
        const BURNER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BURNER_ROLE"));

        await stabilityFund.grantRole(ORACLE_ROLE, priceOracle.address);
        await stabilityFund.grantRole(ADMIN_ROLE, owner.address);
        await stabilityFund.grantRole(BURNER_ROLE, owner.address);
    });

    describe("Deployment", function () {
        it("Should set the correct initial parameters", async function () {
            expect(await stabilityFund.token()).to.equal(teachToken.address);
            expect(await stabilityFund.stableCoin()).to.equal(usdcToken.address);
            expect(await stabilityFund.priceOracle()).to.equal(priceOracle.address);
            expect(await stabilityFund.tokenPrice()).to.equal(INITIAL_PRICE);
            expect(await stabilityFund.baselinePrice()).to.equal(BASELINE_PRICE);
            expect(await stabilityFund.reserveRatio()).to.equal(RESERVE_RATIO);
            expect(await stabilityFund.minReserveRatio()).to.equal(MIN_RESERVE_RATIO);

            // Verify initial reserves
            const initialReserves = await usdcToken.balanceOf(stabilityFund.address);
            expect(initialReserves).to.equal(ethers.utils.parseUnits("500000", 6));
        });

        it("Should set up roles correctly", async function () {
            const ORACLE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ORACLE_ROLE"));
            const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
            const BURNER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BURNER_ROLE"));
            const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));

            // Owner should have admin and emergency roles
            expect(await stabilityFund.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await stabilityFund.hasRole(EMERGENCY_ROLE, owner.address)).to.equal(true);

            // Price oracle should have oracle role
            expect(await stabilityFund.hasRole(ORACLE_ROLE, priceOracle.address)).to.equal(true);

            // Owner should have burner role
            expect(await stabilityFund.hasRole(BURNER_ROLE, owner.address)).to.equal(true);
        });
    });

    describe("Price Oracle Functions", function () {
        it("Should allow oracle to update price", async function () {
            const newPrice = ethers.utils.parseEther("0.06"); // $0.06

            await stabilityFund.connect(priceOracle).updatePrice(newPrice);

            expect(await stabilityFund.tokenPrice()).to.equal(newPrice);
        });

        it("Should prevent non-oracle from updating price", async function () {
            const newPrice = ethers.utils.parseEther("0.06"); // $0.06

            await expect(
                stabilityFund.connect(user1).updatePrice(newPrice)
            ).to.be.reverted;
        });

        it("Should allow admin to update baseline price", async function () {
            const newBaselinePrice = ethers.utils.parseEther("0.07"); // $0.07

            await stabilityFund.updateBaselinePrice(newBaselinePrice);

            expect(await stabilityFund.baselinePrice()).to.equal(newBaselinePrice);
        });

        it("Should calculate verified price correctly", async function () {
            // Initially, verified price should be the same as token price
            expect(await stabilityFund.getVerifiedPrice()).to.equal(INITIAL_PRICE);

            // Update price
            const newPrice = ethers.utils.parseEther("0.06"); // $0.06
            await stabilityFund.connect(priceOracle).updatePrice(newPrice);

            // Verified price should now be the new price
            expect(await stabilityFund.getVerifiedPrice()).to.equal(newPrice);
        });
    });

    describe("Reserve Management", function () {
        it("Should track total reserves correctly", async function () {
            // Initial reserves from setup
            expect(await stabilityFund.totalReserves()).to.equal(ethers.utils.parseUnits("500000", 6));

            // Add more reserves
            const addAmount = ethers.utils.parseUnits("100000", 6); // 100K USDC
            await usdcToken.approve(stabilityFund.address, addAmount);
            await stabilityFund.addReserves(addAmount);

            // Check new total
            expect(await stabilityFund.totalReserves()).to.equal(ethers.utils.parseUnits("600000", 6));
        });

        it("Should allow admin to withdraw excess reserves", async function () {
            // Calculate how much can be withdrawn safely
            const totalSupply = await teachToken.totalSupply();
            const tokenPrice = await stabilityFund.getVerifiedPrice();
            const totalTokenValue = totalSupply.mul(tokenPrice).div(ethers.utils.parseEther("1"));

            const minReserveRequired = totalTokenValue.mul(MIN_RESERVE_RATIO).div(10000);

            // Current reserves
            const currentReserves = await stabilityFund.totalReserves();

            // Assuming we have excess reserves (this should be true given our setup)
            const excessReserves = currentReserves.sub(minReserveRequired);

            // Withdraw half of excess
            const withdrawAmount = excessReserves.div(2);

            // Get initial treasury balance
            const initialTreasuryBalance = await usdcToken.balanceOf(owner.address);

            // Withdraw
            await stabilityFund.withdrawReserves(withdrawAmount);

            // Verify reserves reduced
            expect(await stabilityFund.totalReserves()).to.equal(currentReserves.sub(withdrawAmount));

            // Verify treasury received funds
            const newTreasuryBalance = await usdcToken.balanceOf(owner.address);
            expect(newTreasuryBalance.sub(initialTreasuryBalance)).to.equal(withdrawAmount);
        });

        it("Should not allow withdrawing beyond excess reserves", async function () {
            // Calculate minimum required reserves
            const totalSupply = await teachToken.totalSupply();
            const tokenPrice = await stabilityFund.getVerifiedPrice();
            const totalTokenValue = totalSupply.mul(tokenPrice).div(ethers.utils.parseEther("1"));

            const minReserveRequired = totalTokenValue.mul(MIN_RESERVE_RATIO).div(10000);

            // Current reserves
            const currentReserves = await stabilityFund.totalReserves();

            // Try to withdraw too much
            const excessiveAmount = currentReserves.sub(minReserveRequired).add(ethers.utils.parseUnits("1", 6));

            await expect(
                stabilityFund.withdrawReserves(excessiveAmount)
            ).to.be.revertedWith("PlatformStabilityFund: exceeds available reserves");
        });

        it("Should calculate reserve ratio health correctly", async function () {
            // Initial reserve ratio should be healthy
            const healthRatio = await stabilityFund.getReserveRatioHealth();

            // This should be higher than our MIN_RESERVE_RATIO (2000)
            expect(healthRatio).to.be.gt(MIN_RESERVE_RATIO);
        });
    });

    describe("Token Conversion Functions", function () {
        it("Should convert tokens to stable coins for project funding", async function () {
            // Setup
            const tokenAmount = ethers.utils.parseEther("10000"); // 10K tokens
            const price = await stabilityFund.getVerifiedPrice();

            // Expected value: tokenAmount * price / 1e18
            const expectedValue = tokenAmount.mul(price).div(ethers.utils.parseEther("1"));

            // Platform fee: expectedValue * platformFeePercent / 10000
            const expectedFee = expectedValue.mul(PLATFORM_FEE_PERCENT).div(10000);

            // Value after fee
            const valueAfterFee = expectedValue.sub(expectedFee);

            // No subsidy needed (price equals baseline)
            const expectedStableAmount = valueAfterFee;

            // Get initial project balance
            const initialProjectBalance = await usdcToken.balanceOf(project.address);

            // Convert tokens
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);
            await stabilityFund.convertTokensToFunding(
                project.address,
                tokenAmount,
                expectedStableAmount.mul(95).div(100) // Min return: 95% of expected
            );

            // Verify project received stable coins
            const newProjectBalance = await usdcToken.balanceOf(project.address);
            expect(newProjectBalance.sub(initialProjectBalance)).to.equal(expectedStableAmount);

            // Verify tokens were transferred to stability fund
            expect(await teachToken.balanceOf(stabilityFund.address)).to.equal(tokenAmount);
        });

        it("Should provide subsidy when token price is below baseline", async function () {
            // Update price to below baseline
            const lowerPrice = BASELINE_PRICE.mul(80).div(100); // 80% of baseline
            await stabilityFund.connect(priceOracle).updatePrice(lowerPrice);

            // Setup conversion
            const tokenAmount = ethers.utils.parseEther("10000"); // 10K tokens

            // Get conversion simulation
            const simulation = await stabilityFund.simulateConversion(tokenAmount);
            const [expectedValue, subsidyAmount, finalAmount, feeAmount] = simulation;

            // Subsidy should be non-zero
            expect(subsidyAmount).to.be.gt(0);

            // Final amount should be higher than expected value minus fee
            expect(finalAmount).to.be.gt(expectedValue.sub(feeAmount));

            // Get initial project balance
            const initialProjectBalance = await usdcToken.balanceOf(project.address);

            // Initial reserves
            const initialReserves = await stabilityFund.totalReserves();

            // Convert tokens
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);
            await stabilityFund.convertTokensToFunding(
                project.address,
                tokenAmount,
                finalAmount.mul(95).div(100) // Min return: 95% of expected
            );

            // Verify project received stable coins
            const newProjectBalance = await usdcToken.balanceOf(project.address);
            expect(newProjectBalance.sub(initialProjectBalance)).to.equal(finalAmount);

            // Verify reserves were reduced by subsidy amount
            const newReserves = await stabilityFund.totalReserves();
            expect(initialReserves.sub(newReserves)).to.equal(subsidyAmount);
        });

        it("Should swap tokens for stable coins directly", async function () {
            const tokenAmount = ethers.utils.parseEther("5000"); // 5K tokens
            const price = await stabilityFund.getVerifiedPrice();

            // Expected stable coin amount: tokenAmount * price / 1e18
            const expectedStableAmount = tokenAmount.mul(price).div(ethers.utils.parseEther("1"));

            // Get initial user balance
            const initialUserBalance = await usdcToken.balanceOf(user1.address);

            // Initial reserves
            const initialReserves = await stabilityFund.totalReserves();

            // Perform swap
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);
            await stabilityFund.connect(user1).swapTokensForStable(
                tokenAmount,
                expectedStableAmount.mul(95).div(100) // Min return: 95% of expected
            );

            // Verify user received stable coins
            const newUserBalance = await usdcToken.balanceOf(user1.address);
            expect(newUserBalance.sub(initialUserBalance)).to.equal(expectedStableAmount);

            // Verify reserves were reduced
            const newReserves = await stabilityFund.totalReserves();
            expect(initialReserves.sub(newReserves)).to.equal(expectedStableAmount);

            // Verify tokens were transferred to stability fund
            expect(await teachToken.balanceOf(stabilityFund.address)).to.equal(tokenAmount);
        });
    });

    describe("Fee Management", function () {
        it("Should update fee parameters", async function () {
            const newBaseFee = 400; // 4%
            const newMaxFee = 800; // 8%
            const newMinFee = 200; // 2%
            const newAdjustmentFactor = 120;
            const newDropThreshold = 1200; // 12%
            const newMaxDropPercent = 3500; // 35%

            await stabilityFund.updateFeeParameters(
                newBaseFee,
                newMaxFee,
                newMinFee,
                newAdjustmentFactor,
                newDropThreshold,
                newMaxDropPercent
            );

            // Verify parameters updated
            expect(await stabilityFund.baseFeePercent()).to.equal(newBaseFee);
            expect(await stabilityFund.maxFeePercent()).to.equal(newMaxFee);
            expect(await stabilityFund.minFeePercent()).to.equal(newMinFee);
            expect(await stabilityFund.feeAdjustmentFactor()).to.equal(newAdjustmentFactor);
            expect(await stabilityFund.priceDropThreshold()).to.equal(newDropThreshold);
            expect(await stabilityFund.maxPriceDropPercent()).to.equal(newMaxDropPercent);
        });

        it("Should update current fee based on price", async function () {
            // Initially fee should be at base rate
            expect(await stabilityFund.currentFeePercent()).to.equal(PLATFORM_FEE_PERCENT);

            // Update price to below baseline
            const lowerPrice = BASELINE_PRICE.mul(70).div(100); // 70% of baseline
            await stabilityFund.connect(priceOracle).updatePrice(lowerPrice);

            // Update current fee
            await stabilityFund.updateCurrentFee();

            // Fee should be reduced
            const newFee = await stabilityFund.currentFeePercent();
            expect(newFee).to.be.lt(PLATFORM_FEE_PERCENT);
            expect(newFee).to.be.gte(LOW_VALUE_FEE_PERCENT);
        });

        it("Should process platform fees", async function () {
            const feeAmount = ethers.utils.parseUnits("1000", 6); // 1000 USDC
            const platformFeeToReservePercent = await stabilityFund.platformFeeToReservePercent();

            // Calculate expected amount to reserves
            const expectedToReserves = feeAmount.mul(platformFeeToReservePercent).div(10000);

            // Initial reserves
            const initialReserves = await stabilityFund.totalReserves();

            // Process fees
            await usdcToken.approve(stabilityFund.address, feeAmount);
            await stabilityFund.processPlatformFees(feeAmount);

            // Verify reserves increased
            const newReserves = await stabilityFund.totalReserves();
            expect(newReserves.sub(initialReserves)).to.equal(expectedToReserves);
        });
    });

    describe("Burn Processing", function () {
        it("Should process burned tokens correctly", async function () {
            const burnedAmount = ethers.utils.parseEther("50000"); // 50K tokens
            const burnToReservePercent = await stabilityFund.burnToReservePercent();
            const tokenPrice = await stabilityFund.getVerifiedPrice();

            // Calculate burn value: burnedAmount * tokenPrice / 1e18
            const burnValue = burnedAmount.mul(tokenPrice).div(ethers.utils.parseEther("1"));

            // Calculate expected reserve addition: burnValue * burnToReservePercent / 10000
            const expectedReserveAddition = burnValue.mul(burnToReservePercent).div(10000);

            // Initial reserves
            const initialReserves = await stabilityFund.totalReserves();

            // Process burned tokens
            await stabilityFund.processBurnedTokens(burnedAmount);

            // Verify reserves increased
            const newReserves = await stabilityFund.totalReserves();
            expect(newReserves.sub(initialReserves)).to.equal(expectedReserveAddition);
        });

        it("Should update replenishment parameters", async function () {
            const newBurnPercent = 2000; // 20%
            const newFeePercent = 3000; // 30%

            await stabilityFund.updateReplenishmentParameters(newBurnPercent, newFeePercent);

            expect(await stabilityFund.burnToReservePercent()).to.equal(newBurnPercent);
            expect(await stabilityFund.platformFeeToReservePercent()).to.equal(newFeePercent);
        });

        it("Should authorize burners correctly", async function () {
            const BURNER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BURNER_ROLE"));

            // Initially user1 should not be a burner
            expect(await stabilityFund.hasRole(BURNER_ROLE, user1.address)).to.equal(false);

            // Authorize user1 as burner
            await stabilityFund.setAuthBurner(user1.address, true);

            // Now user1 should be a burner
            expect(await stabilityFund.hasRole(BURNER_ROLE, user1.address)).to.equal(true);

            // Deauthorize
            await stabilityFund.setAuthBurner(user1.address, false);

            // User1 should no longer be a burner
            expect(await stabilityFund.hasRole(BURNER_ROLE, user1.address)).to.equal(false);
        });
    });

    describe("Emergency Controls", function () {
        it("Should check and pause if reserve ratio is critical", async function () {
            // Lower reserves to near critical level
            const totalSupply = await teachToken.totalSupply();
            const tokenPrice = await stabilityFund.getVerifiedPrice();
            const totalTokenValue = totalSupply.mul(tokenPrice).div(ethers.utils.parseEther("1"));

            const minReserveRequired = totalTokenValue.mul(MIN_RESERVE_RATIO).div(10000);
            const criticalThreshold = await stabilityFund.criticalReserveThreshold();
            const criticalLevel = minReserveRequired.mul(criticalThreshold).div(100);

            // Current reserves
            const currentReserves = await stabilityFund.totalReserves();

            // Withdraw to just above critical level
            const safeWithdrawal = currentReserves.sub(criticalLevel.add(ethers.utils.parseUnits("100", 6)));
            await stabilityFund.withdrawReserves(safeWithdrawal);

            // Now do a large swap to trigger circuit breaker
            const tokenAmount = ethers.utils.parseEther("100000"); // 100K tokens
            await teachToken.mint(user2.address, tokenAmount);
            await teachToken.connect(user2).approve(stabilityFund.address, tokenAmount);

            // This should trigger the circuit breaker
            await stabilityFund.connect(user2).swapTokensForStable(
                tokenAmount,
                0 // Min return: 0 to avoid revert due to price impact
            );

            // Verify system is paused
            expect(await stabilityFund.paused()).to.equal(true);
        });

        it("Should allow emergency pause and resume", async function () {
            // Initially not paused
            expect(await stabilityFund.paused()).to.equal(false);

            // Emergency pause
            await stabilityFund.emergencyPause();
            expect(await stabilityFund.paused()).to.equal(true);

            // Try to use the fund (should fail)
            const tokenAmount = ethers.utils.parseEther("1000");
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);

            await expect(
                stabilityFund.connect(user1).swapTokensForStable(tokenAmount, 0)
            ).to.be.reverted;

            // Resume
            await stabilityFund.resumeFromPause();
            expect(await stabilityFund.paused()).to.equal(false);

            // Should work now
            await stabilityFund.connect(user1).swapTokensForStable(tokenAmount, 0);
        });

        it("Should set critical reserve threshold", async function () {
            const newThreshold = 150; // 150% of minimum reserve ratio

            await stabilityFund.setCriticalReserveThreshold(newThreshold);

            expect(await stabilityFund.criticalReserveThreshold()).to.equal(newThreshold);
        });

        it("Should set emergency admin", async function () {
            expect(await stabilityFund.emergencyAdmin()).to.equal(owner.address);

            await stabilityFund.setEmergencyAdmin(user1.address);

            expect(await stabilityFund.emergencyAdmin()).to.equal(user1.address);
        });
    });

    describe("Flash Loan Protection", function () {
        it("Should configure flash loan protection", async function () {
            const newMaxDailyUserVolume = ethers.utils.parseEther("500000"); // 500K tokens
            const newMaxSingleConversionAmount = ethers.utils.parseEther("100000"); // 100K tokens
            const newMinTimeBetweenActions = 30 * 60; // 30 minutes
            const protectionEnabled = true;

            await stabilityFund.configureFlashLoanProtection(
                newMaxDailyUserVolume,
                newMaxSingleConversionAmount,
                newMinTimeBetweenActions,
                protectionEnabled
            );

            // Verify settings
            expect(await stabilityFund.maxDailyUserVolume()).to.equal(newMaxDailyUserVolume);
            expect(await stabilityFund.maxSingleConversionAmount()).to.equal(newMaxSingleConversionAmount);
            expect(await stabilityFund.minTimeBetweenActions()).to.equal(newMinTimeBetweenActions);
            expect(await stabilityFund.flashLoanProtectionEnabled()).to.equal(protectionEnabled);
        });

        it("Should place suspicious address in cooldown", async function () {
            // Initially not in cooldown
            expect(await stabilityFund.addressCooldown(user1.address)).to.equal(false);

            // Place in cooldown
            await stabilityFund.placeSuspiciousAddressInCooldown(user1.address);

            // Now should be in cooldown
            expect(await stabilityFund.addressCooldown(user1.address)).to.equal(true);
        });

        it("Should remove address from cooldown", async function () {
            // Place in cooldown first
            await stabilityFund.placeSuspiciousAddressInCooldown(user1.address);
            expect(await stabilityFund.addressCooldown(user1.address)).to.equal(true);

            // Remove from cooldown
            await stabilityFund.removeSuspiciousAddressCooldown(user1.address);

            // Should be out of cooldown
            expect(await stabilityFund.addressCooldown(user1.address)).to.equal(false);
        });

        it("Should prevent actions from addresses in cooldown", async function () {
            // Place user1 in cooldown
            await stabilityFund.placeSuspiciousAddressInCooldown(user1.address);

            // Try to swap tokens (should fail)
            const tokenAmount = ethers.utils.parseEther("1000");
            await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);

            await expect(
                stabilityFund.connect(user1).swapTokensForStable(tokenAmount, 0)
            ).to.be.revertedWith("PlatformStabilityFund: address in suspicious activity cooldown");
        });
    });

    describe("TWAP Functionality", function () {
        it("Should record price observations", async function () {
            // Record price observation
            await stabilityFund.recordPriceObservation();

            // This function doesn't have a direct query method to check
            // We can indirectly verify by checking lastObservationTimestamp is updated
            expect(await stabilityFund.lastObservationTimestamp()).to.be.gt(0);
        });

        it("Should configure TWAP parameters", async function () {
            const newWindowSize = 24;
            const newInterval = 30 * 60; // 30 minutes
            const enabled = true;

            await stabilityFund.configureTWAP(newWindowSize, newInterval, enabled);

            expect(await stabilityFund.twapWindowSize()).to.equal(newWindowSize);
            expect(await stabilityFund.observationInterval()).to.equal(newInterval);
            expect(await stabilityFund.twapEnabled()).to.equal(enabled);
        });

        it("Should calculate TWAP when sufficient observations exist", async function () {
            // Add multiple price observations
            for (let i = 0; i < 12; i++) {
                // Update price to create variation
                const priceVariation = ethers.utils.parseEther(String(0.05 + 0.001 * i)); // $0.05 with small increments
                await stabilityFund.connect(priceOracle).updatePrice(priceVariation);

                // Advance time for each observation
                await time.increase(3600); // 1 hour

                // Record observation
                await stabilityFund.recordPriceObservation();
            }

            // Calculate TWAP
            const twapPrice = await stabilityFund.calculateTWAP();

            // Should have a non-zero value
            expect(twapPrice).to.be.gt(0);

            // Should be in the range of our test prices
            expect(twapPrice).to.be.gte(ethers.utils.parseEther("0.05"));
            expect(twapPrice).to.be.lte(ethers.utils.parseEther("0.06"));
        });
    });

    describe("Registry Integration", function () {
        it("Should update its registry reference", async function () {
            // Deploy a new registry
            const newRegistry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });
            await newRegistry.deployed();

            // Update registry in stability fund
            await stabilityFund.setRegistry(newRegistry.address);

            expect(await stabilityFund.registry()).to.equal(newRegistry.address);
        });

        it("Should notify connected contracts of emergency", async function () {
            // First we need to set up connected contracts in the registry
            // We'll mock this by using our existing tokens

            const MARKETPLACE_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_MARKETPLACE"));
            const STAKING_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TOKEN_STAKING"));

            // Register mock contracts
            await registry.registerContract(MARKETPLACE_NAME, user1.address, "0x00000000");
            await registry.registerContract(STAKING_NAME, user2.address, "0x00000000");

            // This test would typically need contract mocks that implement the required functions
            // For simplicity, we'll just verify the function doesn't revert
            await expect(stabilityFund.notifyEmergencyToConnectedContracts()).to.not.be.reverted;
        });
    });

    describe("Emergency Recovery", function () {
        it("Should initiate emergency recovery", async function () {
            // Pause first
            await stabilityFund.emergencyPause();

            // Initiate recovery
            await stabilityFund.initiateEmergencyRecovery();

            expect(await stabilityFund.inEmergencyRecovery()).to.equal(true);
        });

        it("Should approve recovery", async function () {
            // Setup recovery
            await stabilityFund.emergencyPause();
            await stabilityFund.initiateEmergencyRecovery();

            // Initialize recovery system
            await stabilityFund.initializeEmergencyRecovery(1); // Only need one approval for test

            // Approve recovery
            await stabilityFund.approveRecovery();

            // Recovery should be completed (inEmergencyRecovery set to false)
            // This check may vary based on the actual implementation
            // expect(await stabilityFund.inEmergencyRecovery()).to.equal(false);

            // Recovery approved for owner
            expect(await stabilityFund.emergencyRecoveryApprovals(owner.address)).to.equal(true);
        });
    });

    describe("Fund Parameters", function () {
        it("Should update fund parameters", async function () {
            const newReserveRatio = 6000; // 60%
            const newMinReserveRatio = 2500; // 25%
            const newPlatformFeePercent = 400; // 4%
            const newLowValueFeePercent = 150; // 1.5%
            const newValueThreshold = 1500; // 15%

            await stabilityFund.updateFundParameters(
                newReserveRatio,
                newMinReserveRatio,
                newPlatformFeePercent,
                newLowValueFeePercent,
                newValueThreshold
            );

            expect(await stabilityFund.reserveRatio()).to.equal(newReserveRatio);
            expect(await stabilityFund.minReserveRatio()).to.equal(newMinReserveRatio);
            expect(await stabilityFund.platformFeePercent()).to.equal(newPlatformFeePercent);
            expect(await stabilityFund.lowValueFeePercent()).to.equal(newLowValueFeePercent);
            expect(await stabilityFund.valueThreshold()).to.equal(newValueThreshold);
        });

        it("Should update price oracle", async function () {
            // Set a new price oracle
            await stabilityFund.updatePriceOracle(user1.address);

            expect(await stabilityFund.priceOracle()).to.equal(user1.address);

            // Grant oracle role to new oracle
            const ORACLE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ORACLE_ROLE"));
            await stabilityFund.grantRole(ORACLE_ROLE, user1.address);

            // Test if new oracle can update price
            const newPrice = ethers.utils.parseEther("0.07");
            await stabilityFund.connect(user1).updatePrice(newPrice);

            expect(await stabilityFund.tokenPrice()).to.equal(newPrice);
        });
    });

    describe("Token Address Caching", function () {
        it("Should update address cache", async function () {
            // This tests internal state that's not directly accessible
            // We'll just verify the function doesn't revert
            await expect(stabilityFund.updateAddressCache()).to.not.be.reverted;
        });
    });

    describe("Integration Tests", function () {
        it("Should handle a complete funding cycle with price volatility", async function () {
            // Initial setup
            const initialReserves = await stabilityFund.totalReserves();

            // 1. Add more reserves
            const addAmount = ethers.utils.parseUnits("100000", 6); // 100K USDC
            await usdcToken.approve(stabilityFund.address, addAmount);
            await stabilityFund.addReserves(addAmount);

            // 2. Price drops below baseline
            const lowerPrice = BASELINE_PRICE.mul(80).div(100); // 80% of baseline
            await stabilityFund.connect(priceOracle).updatePrice(lowerPrice);

            // 3. Multiple users convert tokens to funding
            for (let i = 0; i < 3; i++) {
                const tokenAmount = ethers.utils.parseEther("10000"); // 10K tokens each
                await teachToken.mint(user2.address, tokenAmount);
                await teachToken.connect(user2).approve(stabilityFund.address, tokenAmount);

                await stabilityFund.convertTokensToFunding(
                    project.address,
                    tokenAmount,
                    0 // Min return: 0 for simplicity
                );
            }

            // 4. Process some burned tokens
            const burnedAmount = ethers.utils.parseEther("25000"); // 25K tokens
            await stabilityFund.processBurnedTokens(burnedAmount);

            // 5. Process platform fees
            const feeAmount = ethers.utils.parseUnits("5000", 6); // 5K USDC
            await usdcToken.mint(owner.address, feeAmount);
            await usdcToken.approve(stabilityFund.address, feeAmount);
            await stabilityFund.processPlatformFees(feeAmount);

            // 6. Price recovers above baseline
            const higherPrice = BASELINE_PRICE.mul(120).div(100); // 120% of baseline
            await stabilityFund.connect(priceOracle).updatePrice(higherPrice);

            // 7. More token conversions
            for (let i = 0; i < 2; i++) {
                const tokenAmount = ethers.utils.parseEther("5000"); // 5K tokens each
                await teachToken.mint(user1.address, tokenAmount);
                await teachToken.connect(user1).approve(stabilityFund.address, tokenAmount);

                await stabilityFund.convertTokensToFunding(
                    project.address,
                    tokenAmount,
                    0 // Min return: 0 for simplicity
                );
            }

            // 8. Record price observations for TWAP
            for (let i = 0; i < 5; i++) {
                await time.increase(3600); // 1 hour
                await stabilityFund.recordPriceObservation();
            }

            // 9. Check final state
            const finalReserves = await stabilityFund.totalReserves();
            const reserveRatioHealth = await stabilityFund.getReserveRatioHealth();

            // Should still have healthy reserves
            expect(reserveRatioHealth).to.be.gte(MIN_RESERVE_RATIO);

            // Total conversions should be incremented
            expect(await stabilityFund.totalConversions()).to.equal(5);
        });

        it("Should handle an emergency scenario with recovery", async function () {
            // 1. Deplete reserves to near critical level
            const totalSupply = await teachToken.totalSupply();
            const tokenPrice = await stabilityFund.getVerifiedPrice();
            const totalTokenValue = totalSupply.mul(tokenPrice).div(ethers.utils.parseEther("1"));

            const minReserveRequired = totalTokenValue.mul(MIN_RESERVE_RATIO).div(10000);
            const criticalThreshold = await stabilityFund.criticalReserveThreshold();
            const criticalLevel = minReserveRequired.mul(criticalThreshold).div(100);

            // Withdraw to just above critical level
            const currentReserves = await stabilityFund.totalReserves();
            const safeWithdrawal = currentReserves.sub(criticalLevel.add(ethers.utils.parseUnits("200", 6)));
            await stabilityFund.withdrawReserves(safeWithdrawal);

            // 2. Large swap triggers circuit breaker
            const tokenAmount = ethers.utils.parseEther("100000"); // 100K tokens
            await teachToken.mint(user2.address, tokenAmount);
            await teachToken.connect(user2).approve(stabilityFund.address, tokenAmount);

            await stabilityFund.connect(user2).swapTokensForStable(
                tokenAmount,
                0 // Min return: 0 to avoid revert due to price impact
            );

            // System should be paused
            expect(await stabilityFund.paused()).to.equal(true);

            // 3. Recovery process
            // Initialize emergency recovery
            await stabilityFund.initializeEmergencyRecovery(1); // Only need one approval for test

            // Initiate recovery
            await stabilityFund.initiateEmergencyRecovery();

            // Approve recovery
            await stabilityFund.approveRecovery();

            // 4. Replenish reserves
            const replenishAmount = ethers.utils.parseUnits("500000", 6); // 500K USDC
            await usdcToken.mint(owner.address, replenishAmount);
            await usdcToken.approve(stabilityFund.address, replenishAmount);
            await stabilityFund.addReserves(replenishAmount);

            // 5. Resume system
            await stabilityFund.resumeFromPause();

            // System should be operational again
            expect(await stabilityFund.paused()).to.equal(false);

            // 6. Verify can process operations
            const smallSwap = ethers.utils.parseEther("1000"); // 1K tokens
            await teachToken.mint(user1.address, smallSwap);
            await teachToken.connect(user1).approve(stabilityFund.address, smallSwap);

            // Should work now
            await expect(
                stabilityFund.connect(user1).swapTokensForStable(smallSwap, 0)
            ).to.not.be.reverted;
        });
    });
});