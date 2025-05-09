const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TokenCrowdSale Contract", function () {
    let teachToken;
    let crowdSale;
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
    let vestingContract;

    beforeEach(async function () {
        // Get contract factories and deploy contracts
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const TokenCrowdSale = await ethers.getContractFactory("TokenCrowdSale");
        const USDCMock = await ethers.getContractFactory("TeachToken"); // Using TeachToken as USDC mock
        const TeachTokenVesting = await ethers.getContractFactory("TeachTokenVesting");

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

        // Deploy mock USDC using deployProxy
        usdcToken = await upgrades.deployProxy(USDCMock, [], {
            initializer: "initialize",
            kind: "uups"
        });

        // Deploy TeachToken 
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
            kind: "uups"
        });

        // Deploy vesting contract
        vestingContract = await upgrades.deployProxy(TeachTokenVesting, [await teachToken.getAddress()], {
            initializer: "initialize",
            kind: "uups"
        });

        // Deploy CrowdSale
        crowdSale = await upgrades.deployProxy(TokenCrowdSale, [
            await usdcToken.getAddress(),
            treasury.address
        ], {
            initializer: "initialize",
            kind: "uups"
        });
        
        await vestingContract.addCreator(crowdSale.getAddress());
        await vestingContract.addCreator(teachToken.getAddress());

        // Set token address in crowd sale
        await crowdSale.setSaleToken(await teachToken.getAddress());

        // Set vesting contract
        await crowdSale.setVestingContract(await vestingContract.getAddress());

        // Set presale time (1 day from now, lasting 30 days)
        const currentTime = (await ethers.provider.getBlock("latest")).timestamp;
        const startTime = currentTime + 86400; // Start in 1 day
        const endTime = startTime + (30 * 86400); // End in 30 days
        await crowdSale.setPresaleTimes(startTime, endTime);

        // Mint some USDC for buyers
        await usdcToken.mint(addr1.address, ethers.parseUnits("10000", 6)); // 10,000 USDC
        await usdcToken.mint(addr2.address, ethers.parseUnits("50000", 6)); // 50,000 USDC
        await usdcToken.mint(addr3.address, ethers.parseUnits("2000", 6)); // 2,000 USDC

        // Grant crowdSale minter role on teachToken
        const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
        await teachToken.grantRole(MINTER_ROLE, await crowdSale.getAddress());

        // Grant admin role to owner for various operations
        const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
        await crowdSale.grantRole(ADMIN_ROLE, owner.address);

        // Grant emergency role to owner
        const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
        await crowdSale.grantRole(EMERGENCY_ROLE, owner.address);

        // Grant recorder role to owner
        const RECORDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RECORDER_ROLE"));
        await crowdSale.grantRole(RECORDER_ROLE, owner.address);

        // Transfer some tokens to vesting contract for distribution
        const initialAmount = ethers.parseEther("5000000"); // 5M tokens
        await teachToken.mint(await vestingContract.getAddress(), initialAmount);
    });

    describe("Deployment", function () {
        it("Should set the correct payment token", async function () {
            expect(await crowdSale.paymentToken()).to.equal(await usdcToken.getAddress());
        });

        it("Should set the correct treasury", async function () {
            expect(await crowdSale.treasury()).to.equal(treasury.address);
        });

        it("Should have set the correct sale token", async function () {
            expect(await crowdSale.token()).to.equal(await teachToken.getAddress());
        });
    });

    describe("Tier Management", function () {
        it("Should allow admin to set tier status", async function () {
            // Initially tiers should be inactive
            const tierBefore = await crowdSale.tiers(0);
            expect(tierBefore.isActive).to.equal(false);

            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Check tier status
            const tierAfter = await crowdSale.tiers(0);
            expect(tierAfter.isActive).to.equal(true);
        });

        it("Should allow admin to set tier deadlines", async function () {
            const currentTime = (await ethers.provider.getBlock("latest")).timestamp;
            const newDeadline = currentTime + (7 * 86400); // 7 days from now

            await crowdSale.setTierDeadline(0, newDeadline);

            expect(await crowdSale.tierDeadlines(0)).to.equal(newDeadline);
        });

        it("Should allow admin to advance tier manually", async function () {
            expect(await crowdSale.currentTier()).to.equal(0);

            await crowdSale.advanceTier();

            expect(await crowdSale.currentTier()).to.equal(1);
        });
    });

    describe("Purchase Functionality", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = await crowdSale.presaleStart();
            await ethers.provider.send("evm_setNextBlockTimestamp", [Number(presaleStart) + 1]);
            await ethers.provider.send("evm_mine");

            // Approve USDC for crowdsale
            await usdcToken.connect(addr1).approve(await crowdSale.getAddress(), ethers.parseUnits("10000", 6));
            await usdcToken.connect(addr2).approve(await crowdSale.getAddress(), ethers.parseUnits("50000", 6));
            await usdcToken.connect(addr3).approve(await crowdSale.getAddress(), ethers.parseUnits("2000", 6));
        });

        it("Should respect purchase limits", async function () {
            // Get min/max purchase limits
            const tier = await crowdSale.tiers(0);
            const minPurchase = tier.minPurchase;
            const maxPurchase = tier.maxPurchase;

            // Try to purchase below minimum (should fail)
            await expect(
                crowdSale.connect(addr1).purchase(0, minPurchase - 1n)
            ).to.be.revertedWithCustomError(crowdSale,"BelowMinPurchase");
            
            // Try to purchase above maximum (should fail)
            await expect(
                crowdSale.connect(addr1).purchase(0, maxPurchase + 1n)
            ).to.be.revertedWithCustomError(crowdSale,"AboveMaxPurchase");
            
            // Purchase at minimum should succeed
            await crowdSale.connect(addr1).purchase(0, minPurchase);
            
            // Need to advance time for rate limiting
            await ethers.provider.send("evm_increaseTime", [3600]); // 1 hour
            await ethers.provider.send("evm_mine");

            // Purchase at maximum should succeed
            await crowdSale.connect(addr2).purchase(0, maxPurchase);
        });

        it("Should create vesting schedules for purchases", async function () {
            const purchaseAmount = ethers.parseUnits("1000", 6); // 1,000 USDC

            // Purchase tokens
            await crowdSale.connect(addr1).purchase(0, purchaseAmount);

            // Check that a vesting schedule was created
            const purchase = await crowdSale.purchases(addr1.address);
            expect(purchase.vestingCreated).to.equal(true);
            expect(purchase.vestingScheduleId).to.be.gt(0);
        });
    });

    describe("Token Generation Event (TGE)", function () {
        beforeEach(async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = await crowdSale.presaleStart();
            await ethers.provider.send("evm_setNextBlockTimestamp", [Number(presaleStart) + 1]);
            await ethers.provider.send("evm_mine");

            // Make purchases
            await usdcToken.connect(addr1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));
            await crowdSale.connect(addr1).purchase(0, ethers.parseUnits("1000", 6));
        });

        it("Should not allow completing TGE before presale ends", async function () {
            await expect(
                crowdSale.completeTGE()
            ).to.be.revertedWith("Presale still active");
        });

        it("Should allow completing TGE after presale ends", async function () {
            // Fast forward to presale end
            const presaleEnd = await crowdSale.presaleEnd();
            await ethers.provider.send("evm_setNextBlockTimestamp", [Number(presaleEnd) + 1]);
            await ethers.provider.send("evm_mine");

            // Complete TGE
            await crowdSale.completeTGE();

            expect(await crowdSale.tgeCompleted()).to.equal(true);
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow admin to pause the presale", async function () {
            expect(await crowdSale.emergencyState()).to.equal(0); // NORMAL state

            await crowdSale.pausePresale();

            expect(await crowdSale.emergencyState()).to.equal(1); // MINOR_EMERGENCY state
        });

        it("Should allow admin to resume the presale", async function () {
            // First pause
            await crowdSale.pausePresale();
            expect(await crowdSale.emergencyState()).to.equal(1); // MINOR_EMERGENCY state

            // Then resume
            await crowdSale.resumePresale();
            expect(await crowdSale.emergencyState()).to.equal(0); // NORMAL state
        });

        it("Should prevent purchases when paused", async function () {
            // Activate tier 0
            await crowdSale.setTierStatus(0, true);

            // Fast forward to presale start
            const presaleStart = await crowdSale.presaleStart();
            await ethers.provider.send("evm_setNextBlockTimestamp", [Number(presaleStart) + 1]);
            await ethers.provider.send("evm_mine");

            // Pause crowdsale
            await crowdSale.pausePresale();

            // Try to purchase (should fail)
            await usdcToken.connect(addr1).approve(await crowdSale.getAddress(), ethers.parseUnits("1000", 6));
            await expect(
                crowdSale.connect(addr1).purchase(0, ethers.parseUnits("1000", 6))
            ).to.be.revertedWith("TokenCrowdSale: contract is paused");
        });
    });

    describe("Registry Integration", function () {
        it("Should allow setting registry address", async function () {
            // Deploy a mock registry
            const Registry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(Registry, [], {
                initializer: "initialize",
                kind: "uups"
            });

            // Set registry
            await crowdSale.setRegistry(await registry.getAddress());

            // Verify registry is set
            expect(await crowdSale.registry()).to.equal(await registry.getAddress());
        });
    });
});