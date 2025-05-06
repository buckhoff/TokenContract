const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TokenCrowdSale Contract", function () {
    let TokenCrowdSale;
    let crowdSale;
    let TeachToken;
    let teachToken;
    let USDCMock;
    let usdcToken;
    let owner;
    let treasury;
    let addr1;
    let addr2;
    let addr3;
    let platformEcosystemAddress;
    let communityIncentivesAddress;
    let initialLiquidityAddress;
    let publicPresaleAddress;
    let teamAndDevAddress;
    let educationalPartnersAddress;
    let reserveAddress;

    // Constants for testing
    const PRICE_DECIMALS = ethers.utils.parseUnits("1", 6); // 6 decimal places for USD

    beforeEach(async function () {
        // Get contract factories
        TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
        TeachToken = await ethers.getContractFactory("TeachToken");

        // Use a simple ERC20 to mock USDC for tests
        USDCMock = await ethers.getContractFactory("TeachToken"); // Using TeachToken as a mock for USDC

        // Get signers
        [
            owner,
            treasury,
            addr1,
            addr2,
            addr3,
            platformEcosystemAddress,
            communityIncentivesAddress,
            initialLiquidityAddress,
            publicPresaleAddress,
            teamAndDevAddress,
            educationalPartnersAddress,
            reserveAddress
        ] = await ethers.getSigners();

        // Deploy mock USDC
        usdcToken = await upgrades.deployProxy(USDCMock, [], {
            initializer: "initialize",
        });
        await usdcToken.deployed();

        // Set a different name/symbol for mock USDC (optional)

        // Deploy TeachToken
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.deployed();

        // Deploy TokenCrowdSale
        crowdSale = await upgrades.deployProxy(TokenCrowdSale, [
            usdcToken.address,
            treasury.address
        ], {
            initializer: "initialize",
        });
        await crowdSale.deployed();

        // Set token address in crowd sale
        await crowdSale.setSaleToken(teachToken.address);

        // Set presale time (1 day from now, lasting 30 days)
        const currentTime = await time.latest();
        const startTime = currentTime + 86400; // Start in 1 day
        const endTime = startTime + (30 * 86400); // End in 30 days
        await crowdSale.setPresaleTimes(startTime, endTime);

        // Mint some USDC for buyers
        await usdcToken.mint(addr1.address, ethers.utils.parseUnits("10000", 6)); // 10,000 USDC
        await usdcToken.mint(addr2.address, ethers.utils.parseUnits("5000", 6)); // 5,000 USDC
        await usdcToken.mint(addr3.address, ethers.utils.parseUnits("2000", 6)); // 2,000 USDC

        // Grant crowdSale minter role on teachToken
        const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));
        await teachToken.grantRole(MINTER_ROLE, crowdSale.address);

        // Grant admin role to owner for various operations
        const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
        await crowdSale.grantRole(ADMIN_ROLE, owner.address);

        // Grant emergency role to owner
        const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));
        await crowdSale.grantRole(EMERGENCY_ROLE, owner.address);
    });

    describe("Deployment", function () {
        it("Should set the correct payment token", async function () {
            expect(await crowdSale.paymentToken()).to.equal(usdcToken.address);
        });

        it("Should set the correct treasury", async function () {
            expect(await crowdSale.treasury()).to.equal(treasury.address);
        });

        it("Should have 7 tiers initialized", async function () {
            expect(await crowdSale.tierCount()).to.equal(7);
        });

        it("Should set the correct sale token", async function () {
            expect(await crowdSale.token()).to.equal(teachToken.address);
        });
    });

    describe("Tier Management", function () {
        it("Should correctly initialize tiers with different prices", async function () {
            // Check prices for different tiers
            const tier0Details = await crowdSale.tiers(0);
            const tier1Details = await crowdSale.tiers(1);
            const tier2Details = await crowdSale.tiers(2);

            expect(tier0Details.price).to.equal(35000); // $0.035
            expect(tier1Details.price).to.equal(45000); // $0.045
            expect(tier2Details.price).to.equal(55000); // $0.055
        });

        it("Should allow admin to set tier status", async function () {
            // Initially all tiers should be inactive
            const tierBefore = await crowdSale.tiers(0);
            expect(tierBefore.isActive).to.equal(false);

            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Check tier status
            const tierAfter = await crowdSale.tiers(0);
            expect(tierAfter.isActive).to.equal(true);
        });

        it("Should allow admin to set tier deadlines", async function () {
            const currentTime = await time.latest();
            const newDeadline = currentTime + (7 * 86400); // 7 days from now

            await crowdSale.setTierDeadline(0, newDeadline);

            expect(await crowdSale.tierDeadlines(0)).to.equal(newDeadline);
        });

        it("Should allow admin to advance tier manually", async function () {
            expect(await crowdSale.currentTier()).to.equal(0);

            await crowdSale.advanceTier();

            expect(await crowdSale.currentTier()).to.equal(1);
        });

        it("Should allow admin to extend tier deadline", async function () {
            const currentTime = await time.latest();
            const initialDeadline = currentTime + (7 * 86400); // 7 days from now
            const extendedDeadline = currentTime + (14 * 86400); // 14 days from now

            await crowdSale.setTierDeadline(0, initialDeadline);
            await crowdSale.extendTier(extendedDeadline);

            expect(await crowdSale.tierDeadlines(0)).to.equal(extendedDeadline);
        });
    });

    describe("Purchase Functionality", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Approve USDC for crowdsale
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("10000", 6));
            await usdcToken.connect(addr2).approve(crowdSale.address, ethers.utils.parseUnits("5000", 6));
            await usdcToken.connect(addr3).approve(crowdSale.address, ethers.utils.parseUnits("2000", 6));
        });

        it("Should allow purchase in active tier", async function () {
            const purchaseAmount = ethers.utils.parseUnits("1000", 6); // 1,000 USDC

            // Purchase tokens
            await crowdSale.connect(addr1).purchase(0, purchaseAmount);

            // Check tier sold amount
            const tier = await crowdSale.tiers(0);
            expect(tier.sold).to.be.gt(0);

            // Check user purchase data
            const purchase = await crowdSale.purchases(addr1.address);
            expect(purchase.tokens).to.be.gt(0);
            expect(purchase.usdAmount).to.equal(purchaseAmount);

            // Verify USDC transferred to treasury
            expect(await usdcToken.balanceOf(treasury.address)).to.equal(purchaseAmount);
        });

        it("Should respect purchase limits", async function () {
            // Get min/max purchase limits
            const tier = await crowdSale.tiers(0);
            const minPurchase = tier.minPurchase;
            const maxPurchase = tier.maxPurchase;

            // Try to purchase below minimum (should fail)
            await expect(
                crowdSale.connect(addr1).purchase(0, minPurchase.sub(1))
            ).to.be.revertedWith("Below minimum purchase");

            // Try to purchase above maximum (should fail)
            await expect(
                crowdSale.connect(addr1).purchase(0, maxPurchase.add(1))
            ).to.be.revertedWith("Above maximum purchase");

            // Purchase at minimum should succeed
            await crowdSale.connect(addr1).purchase(0, minPurchase);

            // Purchase at maximum should succeed
            await crowdSale.connect(addr2).purchase(0, maxPurchase);
        });

        it("Should calculate token amount correctly based on tier price", async function () {
            const purchaseAmount = ethers.utils.parseUnits("1000", 6); // 1,000 USDC
            const tierPrice = (await crowdSale.tiers(0)).price;

            // Expected tokens = USD amount * 10^18 / tier price
            const expectedTokens = purchaseAmount.mul(ethers.utils.parseEther("1")).div(tierPrice);

            // Purchase tokens
            await crowdSale.connect(addr1).purchase(0, purchaseAmount);

            // Check user got correct token amount
            const purchase = await crowdSale.purchases(addr1.address);
            expect(purchase.tokens).to.equal(expectedTokens);
        });
    });

    describe("Token Generation Event (TGE)", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Make purchases
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("1000", 6));
            await crowdSale.connect(addr1).purchase(0, ethers.utils.parseUnits("1000", 6));
        });

        it("Should not allow completing TGE before presale ends", async function () {
            await expect(
                crowdSale.completeTGE()
            ).to.be.revertedWith("Presale still active");
        });

        it("Should allow completing TGE after presale ends", async function () {
            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            expect(await crowdSale.tgeCompleted()).to.equal(true);
        });
    });

    describe("Token Claiming", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Make purchases
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("1000", 6));
            await crowdSale.connect(addr1).purchase(0, ethers.utils.parseUnits("1000", 6));

            // Fast forward to presale end
            const presaleEnd = (await crowdSale.presaleEnd()).toNumber();
            await time.increaseTo(presaleEnd + 1);

            // Complete TGE
            await crowdSale.completeTGE();

            // Setup teachToken distribution for claiming
            await teachToken.performInitialDistribution(
                platformEcosystemAddress.address,
                communityIncentivesAddress.address,
                initialLiquidityAddress.address,
                publicPresaleAddress.address,
                teamAndDevAddress.address,
                educationalPartnersAddress.address,
                reserveAddress.address
            );

            // Transfer tokens to crowdSale contract for distribution
            const publicPresaleAmount = ethers.utils.parseEther("500000000"); // 500M tokens (10%)
            await teachToken.connect(publicPresaleAddress).transfer(crowdSale.address, publicPresaleAmount);
        });

        it("Should calculate claimable tokens correctly based on vesting schedule", async function () {
            // Tier 0 has 10% TGE release and 18 months vesting
            const tier = await crowdSale.tiers(0);
            const vestingTGE = tier.vestingTGE; // 10%

            // Get user's purchase
            const purchase = await crowdSale.purchases(addr1.address);
            const totalTokens = purchase.tokens;

            // Expected TGE release = total tokens * vestingTGE / 100
            const expectedTGERelease = totalTokens.mul(vestingTGE).div(100);

            // Check claimable amount (should be TGE release at this point)
            const claimable = await crowdSale.claimableTokens(addr1.address);
            expect(claimable).to.equal(expectedTGERelease);
        });

        it("Should allow users to withdraw available tokens", async function () {
            // Get claimable amount
            const claimable = await crowdSale.claimableTokens(addr1.address);

            // Initial token balance
            const initialBalance = await teachToken.balanceOf(addr1.address);

            // Withdraw tokens
            await crowdSale.connect(addr1).withdrawTokens();

            // Check token balance increased
            const newBalance = await teachToken.balanceOf(addr1.address);
            expect(newBalance.sub(initialBalance)).to.equal(claimable);

            // Check tokens marked as claimed in contract
            const purchaseAfter = await crowdSale.purchases(addr1.address);
            expect(purchaseAfter.tokens).to.equal(purchase.tokens.sub(claimable));
        });

        it("Should not allow claiming tokens before TGE", async function () {
            // Reset TGE completion flag for test
            // This would require a mock or redeployment in a real scenario
            // For this test, we'll skip the state change and just verify the revert

            // Simulate non-completed TGE by deploying a new contract
            const newCrowdSale = await upgrades.deployProxy(TokenCrowdSale, [
                usdcToken.address,
                treasury.address
            ], {
                initializer: "initialize",
            });
            await newCrowdSale.deployed();

            // Set token address
            await newCrowdSale.setSaleToken(teachToken.address);

            // Try to withdraw (should fail)
            await expect(
                newCrowdSale.connect(addr1).withdrawTokens()
            ).to.be.revertedWith("TGE not completed yet");
        });

        it("Should update vesting over time", async function () {
            // Initial claim
            const initialClaimable = await crowdSale.claimableTokens(addr1.address);
            await crowdSale.connect(addr1).withdrawTokens();

            // Fast forward 3 months
            await time.increase(90 * 86400);

            // Should have more tokens available now
            const newClaimable = await crowdSale.claimableTokens(addr1.address);
            expect(newClaimable).to.be.gt(0);

            // Claim again
            await crowdSale.connect(addr1).withdrawTokens();
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow admin to pause the presale", async function () {
            expect(await crowdSale.paused()).to.equal(false);

            await crowdSale.pausePresale();

            expect(await crowdSale.paused()).to.equal(true);
        });

        it("Should allow admin to resume the presale", async function () {
            // First pause
            await crowdSale.pausePresale();
            expect(await crowdSale.paused()).to.equal(true);

            // Then resume
            await crowdSale.resumePresale();
            expect(await crowdSale.paused()).to.equal(false);
        });

        it("Should prevent purchases when paused", async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);

            // Pause crowdsale
            await crowdSale.pausePresale();

            // Try to purchase (should fail)
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("1000", 6));
            await expect(
                crowdSale.connect(addr1).purchase(0, ethers.utils.parseUnits("1000", 6))
            ).to.be.revertedWith("TokenCrowdSale: contract is paused");
        });

        it("Should allow initiating emergency recovery", async function () {
            // Pause first
            await crowdSale.pausePresale();

            // Initiate recovery
            await crowdSale.initiateEmergencyRecovery();

            expect(await crowdSale.inEmergencyRecovery()).to.equal(true);
            expect(await crowdSale.emergencyState()).to.equal(2); // CRITICAL_EMERGENCY
        });

        it("Should allow completing emergency recovery", async function () {
            // Setup recovery mode
            await crowdSale.pausePresale();
            await crowdSale.initiateEmergencyRecovery();

            // Complete recovery
            await crowdSale.completeEmergencyRecovery();

            expect(await crowdSale.inEmergencyRecovery()).to.equal(false);
            expect(await crowdSale.paused()).to.equal(false);
            expect(await crowdSale.emergencyState()).to.equal(0); // NORMAL
        });
    });

    describe("Registry Integration", function () {
        it("Should allow setting registry address", async function () {
            // Deploy a mock registry
            const Registry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(Registry, [], {
                initializer: "initialize",
            });
            await registry.deployed();

            // Set registry
            await crowdSale.setRegistry(registry.address);

            // Verify registry is set
            expect(await crowdSale.registry()).to.equal(registry.address);
        });

        it("Should allow updating contract cache", async function () {
            // Deploy a mock registry
            const Registry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(Registry, [], {
                initializer: "initialize",
            });
            await registry.deployed();

            // Set registry
            await crowdSale.setRegistry(registry.address);

            // Register a mock token in the registry
            const TOKEN_NAME = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("_TEACH_TOKEN"));
            await registry.registerContract(TOKEN_NAME, teachToken.address, "0x00000000");

            // Update contract cache
            await crowdSale.updateContractCache();

            // This mainly verifies that the function doesn't revert
            // Internal state changes would need more detailed testing
        });
    });

    describe("View Functions", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = (await crowdSale.presaleStart()).toNumber();
            await time.increaseTo(presaleStart);
        });

        it("Should return correct total tokens sold", async function () {
            // Make a purchase
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("1000", 6));
            await crowdSale.connect(addr1).purchase(0, ethers.utils.parseUnits("1000", 6));

            // Get tier sold amount
            const tier = await crowdSale.tiers(0);

            // Check totalTokensSold
            expect(await crowdSale.totalTokensSold()).to.equal(tier.sold);
        });

        it("Should return tokens remaining in tier", async function () {
            // Make a purchase
            await usdcToken.connect(addr1).approve(crowdSale.address, ethers.utils.parseUnits("1000", 6));
            await crowdSale.connect(addr1).purchase(0, ethers.utils.parseUnits("1000", 6));

            // Get tier details
            const tier = await crowdSale.tiers(0);

            // Expected remaining = allocation - sold
            const expected = tier.allocation.sub(tier.sold);

            // Check tokensRemainingInTier
            expect(await crowdSale.tokensRemainingInTier(0)).to.equal(expected);
        });

        it("Should return current active tier", async function () {
            expect(await crowdSale.getCurrentTier()).to.equal(0);

            // If we advance tier
            await crowdSale.advanceTier();

            expect(await crowdSale.getCurrentTier()).to.equal(1);
        });
    });
});