const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TierManager", function () {
    let TierManager, tierManager;
    let ContractRegistry, registry;
    let admin, crowdsale, stranger;

    const CROWDSALE_CONTRACT = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("Crowdsale"));

    beforeEach(async function () {
        [admin, crowdsale, stranger] = await ethers.getSigners();

        ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        registry = await ContractRegistry.deploy();
        await registry.deployed();

        await registry.setContract(CROWDSALE_CONTRACT, crowdsale.address);

        TierManager = await ethers.getContractFactory("TierManager");
        tierManager = await TierManager.connect(admin).deploy();
        await tierManager.deployed();
        await tierManager.initialize(registry.address, admin.address);
    });

    it("should allow only admin to add tiers", async function () {
        const tier = {
            price: ethers.utils.parseEther("0.01"),
            maxTokens: ethers.utils.parseEther("1000"),
            vestingType: 0,
            vestingCliff: 0,
            vestingDuration: 0,
            deadline: Math.floor(Date.now() / 1000) + 86400,
        };

        await expect(tierManager.connect(admin).addTier(tier)).to.not.be.reverted;
        expect(await tierManager.getTierCount()).to.equal(1);

        await expect(tierManager.connect(stranger).addTier(tier)).to.be.revertedWith(
            "AccessControl: account is missing role"
        );
    });

    it("should allow only crowdsale to set active tier", async function () {
        const tier = {
            price: ethers.utils.parseEther("0.01"),
            maxTokens: ethers.utils.parseEther("1000"),
            vestingType: 0,
            vestingCliff: 0,
            vestingDuration: 0,
            deadline: Math.floor(Date.now() / 1000) + 86400,
        };

        await tierManager.connect(admin).addTier(tier);

        await expect(tierManager.connect(stranger).setActiveTier(0)).to.be.revertedWith(
            "Only crowdsale can call"
        );

        await expect(tierManager.connect(crowdsale).setActiveTier(0)).to.not.be.reverted;
        expect(await tierManager.getActiveTierId()).to.equal(0);
    });

    it("should auto-advance tier after deadline", async function () {
        const now = Math.floor(Date.now() / 1000);

        const expired = {
            price: ethers.utils.parseEther("0.01"),
            maxTokens: ethers.utils.parseEther("1000"),
            vestingType: 0,
            vestingCliff: 0,
            vestingDuration: 0,
            deadline: now - 10,
        };

        const next = {
            price: ethers.utils.parseEther("0.02"),
            maxTokens: ethers.utils.parseEther("2000"),
            vestingType: 1,
            vestingCliff: 0,
            vestingDuration: 0,
            deadline: now + 86400,
        };

        await tierManager.connect(admin).addTier(expired);
        await tierManager.connect(admin).addTier(next);
        await tierManager.connect(crowdsale).setActiveTier(0);

        await tierManager.connect(crowdsale).checkAndAdvanceTier();
        expect(await tierManager.getActiveTierId()).to.equal(1);
    });

    it("should return active tier details correctly", async function () {
        const tier = {
            price: ethers.utils.parseEther("0.05"),
            maxTokens: ethers.utils.parseEther("5000"),
            vestingType: 2,
            vestingCliff: 30 * 86400,
            vestingDuration: 180 * 86400,
            deadline: Math.floor(Date.now() / 1000) + 86400 * 5,
        };

        await tierManager.connect(admin).addTier(tier);
        await tierManager.connect(crowdsale).setActiveTier(0);

        const activeTier = await tierManager.getActiveTier();
        expect(activeTier.price).to.equal(tier.price);
        expect(activeTier.maxTokens).to.equal(tier.maxTokens);
        expect(activeTier.vestingType).to.equal(tier.vestingType);
    });

    it("should allow only admin to update tier", async function () {
        const tier = {
            price: ethers.utils.parseEther("0.01"),
            maxTokens: ethers.utils.parseEther("1000"),
            vestingType: 0,
            vestingCliff: 0,
            vestingDuration: 0,
            deadline: Math.floor(Date.now() / 1000) + 86400,
        };

        const updated = {
            price: ethers.utils.parseEther("0.02"),
            maxTokens: ethers.utils.parseEther("999"),
            vestingType: 1,
            vestingCliff: 7 * 86400,
            vestingDuration: 180 * 86400,
            deadline: Math.floor(Date.now() / 1000) + 86400 * 2,
        };

        await tierManager.connect(admin).addTier(tier);

        await expect(tierManager.connect(admin).updateTier(0, updated)).to.not.be.reverted;

        const result = await tierManager.getTier(0);
        expect(result.price).to.equal(updated.price);
        expect(result.maxTokens).to.equal(updated.maxTokens);
        expect(result.vestingType).to.equal(updated.vestingType);

        await expect(tierManager.connect(stranger).updateTier(0, tier)).to.be.revertedWith(
            "AccessControl: account is missing role"
        );
    });
});
