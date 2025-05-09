const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("TeachToken Contract", function () {
    let teachToken;
    let owner;
    let addr1;
    let addr2;
    let addr3;
    let addr4;
    let addr5;
    let addr6;
    let addr7;

    const MAX_SUPPLY = ethers.parseEther("5000000000"); // 5 billion tokens

    beforeEach(async function () {
        // Get the contract factory and signers
        const TeachToken = await ethers.getContractFactory("TeachToken");
        [owner, addr1, addr2, addr3, addr4, addr5, addr6, addr7] = await ethers.getSigners();

        // Deploy using upgrades plugin
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });

        await teachToken.waitForDeployment();
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            const DEFAULT_ADMIN_ROLE = ethers.ZeroHash; // For ethers v6
            expect(await teachToken.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true)
        });

        it("Should have correct name and symbol", async function () {
            expect(await teachToken.name()).to.equal("TeacherSupport Token");
            expect(await teachToken.symbol()).to.equal("TEACH");
        });

        it("Should set initial supply to 0", async function () {
            expect(await teachToken.totalSupply()).to.equal(0);
        });

        it("Should grant DEFAULT_ADMIN_ROLE to the owner", async function () {
            const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
            expect(await teachToken.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true);
        });

        it("Should grant ADMIN_ROLE to the owner", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
            expect(await teachToken.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
        });

        it("Should grant MINTER_ROLE to the owner", async function () {
            const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
            expect(await teachToken.hasRole(MINTER_ROLE, owner.address)).to.equal(true);
        });

        it("Should grant BURNER_ROLE to the owner", async function () {
            const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
            expect(await teachToken.hasRole(BURNER_ROLE, owner.address)).to.equal(true);
        });
    });

    describe("Initial Distribution", function () {
        it("Should perform initial distribution correctly", async function () {
            // Initial distribution percentages
            const platformEcosystemPercent = 20; // 20%
            const communityIncentivesPercent = 24; // 24%
            const initialLiquidityPercent = 12; // 12%
            const publicPresalePercent = 25; // 25%
            const teamAndDevPercent = 8; // 8%
            const educationalPartnersPercent = 7; // 7%
            const reservePercent = 4; // 4%

            // Calculate expected token amounts
            const platformEcosystemAmount = MAX_SUPPLY * BigInt(platformEcosystemPercent) / 100n;
            const communityIncentivesAmount = MAX_SUPPLY * BigInt(communityIncentivesPercent) / 100n;
            const initialLiquidityAmount = MAX_SUPPLY * BigInt(initialLiquidityPercent) / 100n;
            const publicPresaleAmount = MAX_SUPPLY * BigInt(publicPresalePercent) / 100n;
            const teamAndDevAmount = MAX_SUPPLY * BigInt(teamAndDevPercent) / 100n;
            const educationalPartnersAmount = MAX_SUPPLY * BigInt(educationalPartnersPercent) / 100n;
            const reserveAmount = MAX_SUPPLY * BigInt(reservePercent) / 100n;

            // Perform initial distribution
            await teachToken.performInitialDistribution(
                addr1.address, // platformEcosystem
                addr2.address, // communityIncentives
                addr3.address, // initialLiquidity
                addr4.address, // publicPresale
                addr5.address, // teamAndDev
                addr6.address, // educationalPartners
                addr7.address  // reserve
            );

            // Check if distribution was performed correctly
            expect(await teachToken.balanceOf(addr1.address)).to.equal(platformEcosystemAmount);
            expect(await teachToken.balanceOf(addr2.address)).to.equal(communityIncentivesAmount);
            expect(await teachToken.balanceOf(addr3.address)).to.equal(initialLiquidityAmount);
            expect(await teachToken.balanceOf(addr4.address)).to.equal(publicPresaleAmount);
            expect(await teachToken.balanceOf(addr5.address)).to.equal(teamAndDevAmount);
            expect(await teachToken.balanceOf(addr6.address)).to.equal(educationalPartnersAmount);
            expect(await teachToken.balanceOf(addr7.address)).to.equal(reserveAmount);

            // Check total supply
            expect(await teachToken.totalSupply()).to.equal(MAX_SUPPLY);

            // Check that initial distribution is marked as completed
            expect(await teachToken.isInitialDistributionComplete()).to.equal(true);
        });

        it("Should not allow performing initial distribution twice", async function () {
            await teachToken.performInitialDistribution(
                addr1.address, addr2.address, addr3.address, addr4.address,
                addr5.address, addr6.address, addr7.address
            );

            await expect(
                teachToken.performInitialDistribution(
                    addr1.address, addr2.address, addr3.address, addr4.address,
                    addr5.address, addr6.address, addr7.address
                )
            ).to.be.revertedWith("Initial distribution already completed");
        });
    });

    describe("Minting", function () {
        it("Should allow owner to mint tokens", async function () {
            await teachToken.mint(addr1.address, ethers.parseEther("1000"));
            expect(await teachToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("1000"));
        });

        it("Should not allow non-minters to mint tokens", async function () {
            await expect(
                teachToken.connect(addr1).mint(addr1.address, ethers.parseEther("1000"))
            ).to.be.reverted;
        });

        it("Should respect maximum supply limit when minting", async function () {
            // Perform initial distribution to get close to max supply
            await teachToken.performInitialDistribution(
                addr1.address, addr2.address, addr3.address, addr4.address,
                addr5.address, addr6.address, addr7.address
            );

            // Try to mint more tokens beyond max supply
            await expect(
                teachToken.mint(addr1.address, 1)
            ).to.be.revertedWith("TeachToken: Max supply exceeded");
        });
    });

    describe("Burning", function () {
        beforeEach(async function () {
            // Mint some tokens to addr1 for testing burn functionality
            await teachToken.mint(addr1.address, ethers.parseEther("1000"));
        });

        it("Should allow users to burn their own tokens", async function () {
            await teachToken.connect(addr1).burn(ethers.parseEther("500"));
            expect(await teachToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("500"));
        });

        it("Should allow burners to burn tokens from other addresses", async function () {
            const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));

            // Approve owner to burn tokens
            await teachToken.connect(addr1).approve(owner.address, ethers.parseEther("500"));

            // Burn tokens from addr1
            await teachToken.burnFrom(addr1.address, ethers.parseEther("500"));

            expect(await teachToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("500"));
        });

        it("Should not allow non-burners to burn tokens from other addresses", async function () {
            // Approve addr2 to burn tokens
            await teachToken.connect(addr1).approve(addr2.address, ethers.parseEther("500"));

            // Try to burn tokens from addr1 (should fail)
            await expect(
                teachToken.connect(addr2).burnFrom(addr1.address, ethers.parseEther("500"))
            ).to.be.reverted;
        });
    });

    describe("Role Management", function () {
        it("Should allow adding new minters", async function () {
            const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));

            await teachToken.addMinter(addr1.address);
            expect(await teachToken.hasRole(MINTER_ROLE, addr1.address)).to.equal(true);

            // Test that new minter can mint
            await teachToken.connect(addr1).mint(addr2.address, ethers.parseEther("1000"));
            expect(await teachToken.balanceOf(addr2.address)).to.equal(ethers.parseEther("1000"));
        });

        it("Should allow removing minters", async function () {
            const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));

            await teachToken.addMinter(addr1.address);
            await teachToken.removeMinter(addr1.address);

            expect(await teachToken.hasRole(MINTER_ROLE, addr1.address)).to.equal(false);

            // Test that removed minter can't mint anymore
            await expect(
                teachToken.connect(addr1).mint(addr2.address, ethers.parseEther("1000"))
            ).to.be.reverted;
        });

        it("Should allow adding new burners", async function () {
            const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));

            await teachToken.addBurner(addr1.address);
            expect(await teachToken.hasRole(BURNER_ROLE, addr1.address)).to.equal(true);
        });

        it("Should allow removing burners", async function () {
            const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));

            await teachToken.addBurner(addr1.address);
            await teachToken.removeBurner(addr1.address);

            expect(await teachToken.hasRole(BURNER_ROLE, addr1.address)).to.equal(false);
        });
    });

    describe("Pausing", function () {
        beforeEach(async function () {
            // Mint some tokens to addr1 for testing transfers
            await teachToken.mint(addr1.address, ethers.parseEther("1000"));
        });

        it("Should allow admin to pause the contract", async function () {
            await teachToken.pause();

            // Try to transfer tokens (should fail when paused)
            await expect(
                teachToken.connect(addr1).transfer(addr2.address, ethers.parseEther("500"))
            ).to.be.revertedWith("TeachToken: Paused");
        });

        it("Should allow emergency role to unpause the contract", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

            // Verify owner has EMERGENCY_ROLE
            expect(await teachToken.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);

            // Pause and then unpause
            await teachToken.pause();
            await teachToken.unpause();

            // Transfer should work again
            await teachToken.connect(addr1).transfer(addr2.address, ethers.parseEther("500"));
            expect(await teachToken.balanceOf(addr2.address)).to.equal(ethers.parseEther("500"));
        });
    });

    describe("Token Recovery", function () {
        it("Should allow setting recovery allowed tokens", async function () {
            // Deploy a dummy token for testing recovery
            const DummyToken = await ethers.getContractFactory("TeachToken");
            const dummyToken = await upgrades.deployProxy(DummyToken, [], {
                initializer: "initialize",
            });

            await teachToken.setRecoveryAllowedToken(await dummyToken.getAddress(), true);

            // Verify token is marked as allowed for recovery
            expect(await teachToken.recoveryAllowedTokens(await dummyToken.getAddress())).to.equal(true);
        });

        it("Should not allow setting TEACH token as recoverable", async function () {
            await expect(
                teachToken.setRecoveryAllowedToken(await teachToken.getAddress(), true)
            ).to.be.revertedWith("TeachToken: cannot allow TEACH token");
        });
    });

    describe("Upgradeable Pattern", function() {
        it("Should be upgradeable using the UUPS pattern", async function() {
            // Deploy a new implementation
            const TeachTokenV2 = await ethers.getContractFactory("TeachToken");

            // Upgrade to new implementation
            const upgradedToken = await upgrades.upgradeProxy(
                await teachToken.getAddress(),
                TeachTokenV2
            );

            // Check that the address stayed the same
            expect(await upgradedToken.getAddress()).to.equal(await teachToken.getAddress());

            // Verify state is preserved (name, symbol, etc.)
            expect(await upgradedToken.name()).to.equal("TeacherSupport Token");
            expect(await upgradedToken.symbol()).to.equal("TEACH");

            // Functionality should still work
            await upgradedToken.mint(addr1.address, ethers.parseEther("100"));
            expect(await upgradedToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("100"));
        });
    });

    describe("Miscellaneous", function () {
        it("Should return correct chain ID", async function () {
            const chainId = await teachToken.getChainId();
            expect(chainId).to.not.equal(0);

            // This will depend on the network you're testing on
            // For hardhat network, it's typically 31337
            expect(chainId).to.equal(31337n);
        });

        it("Should properly set registry", async function () {
            // Deploy a mock registry
            const mockRegistry = await ethers.deployContract("ContractRegistry");
            await mockRegistry.initialize();

            // Set registry
            await teachToken.setRegistry(await mockRegistry.getAddress());

            // Verify registry is set
            expect(await teachToken.registry()).to.equal(await mockRegistry.getAddress());
        });
    });
});