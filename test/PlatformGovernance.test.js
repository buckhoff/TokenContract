const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PlatformGovernance Contract", function () {
    let teachToken;
    let stakingContract;
    let governance;
    let registry;
    let owner;
    let voter1;
    let voter2;
    let voter3;
    let guardians = [];
    let mockStabilityFund;

    // Constants
    const proposalThreshold = ethers.parseEther("100000"); // 100k tokens to create proposal
    const minVotingPeriod = 3 * 24 * 60 * 60; // 3 days
    const maxVotingPeriod = 7 * 24 * 60 * 60; // 7 days
    const quorumThreshold = 400; // 4% of total supply
    const executionDelay = 2 * 24 * 60 * 60; // 2 days
    const executionPeriod = 3 * 24 * 60 * 60; // 3 days

    // Enum for vote types
    const VoteType = {
        Against: 0,
        For: 1,
        Abstain: 2
    };

    // Enum for proposal state
    const ProposalState = {
        Pending: 0,
        Active: 1,
        Defeated: 2,
        Succeeded: 3,
        Queued: 4,
        Executed: 5,
        Expired: 6
    };

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));

    beforeEach(async function () {
        // Get the contract factories and signers
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const TokenStaking = await ethers.getContractFactory("TokenStaking");
        const PlatformGovernance = await ethers.getContractFactory("PlatformGovernance");
        const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
        const StabilityFund = await ethers.getContractFactory("PlatformStabilityFund");
        [owner, voter1, voter2, voter3, ...guardians] = await ethers.getSigners();

        // Deploy token
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.waitForDeployment();

        // Deploy registry
        registry = await upgrades.deployProxy(ContractRegistry, [], {
            initializer: "initialize"
        });
        await registry.waitForDeployment();

        // Deploy staking contract
        stakingContract = await upgrades.deployProxy(TokenStaking, [
            await teachToken.getAddress(),
            owner.address // platform rewards manager
        ], {
            initializer: "initialize"
        });
        await stakingContract.waitForDeployment();

        // Set up mock stability fund
        mockStabilityFund = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize"
        });

        // Deploy governance contract
        governance = await upgrades.deployProxy(PlatformGovernance, [
            await teachToken.getAddress(),
            proposalThreshold,
            minVotingPeriod,
            maxVotingPeriod,
            quorumThreshold,
            executionDelay,
            executionPeriod
        ], {
            initializer: "initialize",
        });
        await governance.waitForDeployment();

        // Mint tokens to voters for governance participation
        await teachToken.mint(voter1.address, ethers.parseEther("500000")); // 500k tokens
        await teachToken.mint(voter2.address, ethers.parseEther("300000")); // 300k tokens
        await teachToken.mint(voter3.address, ethers.parseEther("200000")); // 200k tokens

        // Register contracts in registry
        const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
        const STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));
        const GOVERNANCE_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_GOVERNANCE"));
        const STABILITY_FUND_NAME = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_STABILITY_FUND"));

        await registry.registerContract(TOKEN_NAME, await teachToken.getAddress(), "0x00000000");
        await registry.setContractStatus(TOKEN_NAME,true)
        await registry.registerContract(STAKING_NAME, await stakingContract.getAddress(), "0x00000000");
        await registry.registerContract(GOVERNANCE_NAME, await governance.getAddress(), "0x00000000");
        await registry.registerContract(STABILITY_FUND_NAME, await mockStabilityFund.getAddress(), "0x00000000");

        // Set registry in governance
        await governance.setRegistry(await registry.getAddress());

        // Update contract references
        await governance.updateContractReferences();

        // Set staking contract for voting power calculation
        await governance.setStakingContract(
            await stakingContract.getAddress(),
            200, // 2x max multiplier
            365 // 1 year max staking period
        );
    });

    describe("Deployment", function () {
        it("Should initialize with correct parameters", async function () {
            expect(await governance.token()).to.equal(await teachToken.getAddress());
            expect(await governance.proposalThreshold()).to.equal(proposalThreshold);
            expect(await governance.minVotingPeriod()).to.equal(minVotingPeriod);
            expect(await governance.maxVotingPeriod()).to.equal(maxVotingPeriod);
            expect(await governance.quorumThreshold()).to.equal(quorumThreshold);
            expect(await governance.executionDelay()).to.equal(executionDelay);
            expect(await governance.executionPeriod()).to.equal(executionPeriod);
        });

        it("Should grant proper roles to owner", async function () {
            expect(await governance.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await governance.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await governance.hasRole(EMERGENCY_ROLE, owner.address)).to.equal(true);
        });

        it("Should set correct staking parameters", async function () {
            expect(await governance.stakingContract()).to.equal(await stakingContract.getAddress());
            expect(await governance.maxStakingMultiplier()).to.equal(200);
            expect(await governance.maxStakingPeriod()).to.equal(365);
            expect(await governance.stakingWeightEnabled()).to.equal(true);
        });
    });

    describe("Proposal Creation", function () {
        let targets, signatures, calldatas, description, votingPeriod;

        beforeEach(async function () {
            // Setup standard proposal
            targets = [await governance.getAddress()];
            signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"), // New proposal threshold
                        4 * 24 * 60 * 60, // New min voting period
                        10 * 24 * 60 * 60, // New max voting period
                        500, // New quorum threshold
                        3 * 24 * 60 * 60, // New execution delay
                        4 * 24 * 60 * 60 // New execution period
                    ]
                )
            ];
            description = "Test proposal to update governance parameters";
            votingPeriod = 4 * 24 * 60 * 60; // 4 days
        });

        it("Should create a proposal with correct details", async function () {
            const tx = await governance.connect(voter1).createProposal(
                targets,
                signatures,
                calldatas,
                description,
                votingPeriod
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            const proposalDetails = await governance.getProposalDetails(proposalId);
            expect(proposalDetails.proposer).to.equal(voter1.address);
            expect(proposalDetails.description).to.equal(description);
            expect(proposalDetails.currentState).to.equal(ProposalState.Active);

            // Verify the proposal appears in active proposals
            const activeProposals = await governance.getActiveProposals();
            expect(activeProposals).to.include(proposalId);
        });

        it("Should not allow creating proposals below threshold", async function () {
            // Transfer some tokens from voter3 to make balance below threshold
            await teachToken.connect(voter3).transfer(voter2.address, ethers.parseEther("150000"));

            await expect(
                governance.connect(voter3).createProposal(
                    targets,
                    signatures,
                    calldatas,
                    description,
                    votingPeriod
                )
            ).to.be.revertedWithCustomError(governance,"InsufficientProposalThreshold")
        });

        it("Should not allow creation with invalid voting period", async function () {
            // Try with too short voting period
            await expect(
                governance.connect(voter1).createProposal(
                    targets, signatures, calldatas, description, minVotingPeriod - 100
                )
            ).to.be.revertedWithCustomError(governance,"InvalidVotingPeriod")

            // Try with too long voting period
            await expect(
                governance.connect(voter1).createProposal(
                    targets, signatures, calldatas, description, maxVotingPeriod + 100
                )
            ).to.be.revertedWithCustomError(governance,"InvalidVotingPeriod")
        });

        it("Should validate parameter matching", async function () {
            // Mismatched targets and signatures lengths
            await expect(
                governance.connect(voter1).createProposal(
                    [targets[0], targets[0]],
                    signatures,
                    calldatas,
                    description,
                    votingPeriod
                )
            ).to.be.revertedWithCustomError(governance,"SignatureMismatch")

            // Mismatched targets and calldatas lengths
            await expect(
                governance.connect(voter1).createProposal(
                    [targets[0], targets[0]],
                    [signatures[0], signatures[0]],
                    calldatas,
                    description,
                    votingPeriod
                )
            ).to.be.revertedWithCustomError(governance, "CalldataMismatch")
        });
    });

    describe("Voting Mechanism", function () {
        let proposalId;
        const votingPeriod = 4 * 24 * 60 * 60; // 4 days

        beforeEach(async function () {
            // Create a standard proposal
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"),
                        4 * 24 * 60 * 60,
                        10 * 24 * 60 * 60,
                        500,
                        3 * 24 * 60 * 60,
                        4 * 24 * 60 * 60
                    ]
                )
            ];
            const description = "Test proposal for voting";

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event.args.proposalId;
        });

        it("Should track votes correctly", async function () {
            // Cast votes with different types
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support the proposal");
            await governance.connect(voter2).castVote(proposalId, VoteType.Against, "Against the proposal");
            await governance.connect(voter3).castVote(proposalId, VoteType.Abstain, "Abstaining from voting");

            // Check vote receipts
            const receipt1 = await governance.getReceipt(proposalId, voter1.address);
            expect(receipt1.hasVoted).to.equal(true);
            expect(receipt1.voteType).to.equal(VoteType.For);
            expect(receipt1.votes).to.equal(ethers.parseEther("500000"));

            const receipt2 = await governance.getReceipt(proposalId, voter2.address);
            expect(receipt2.hasVoted).to.equal(true);
            expect(receipt2.voteType).to.equal(VoteType.Against);
            expect(receipt2.votes).to.equal(ethers.parseEther("300000"));

            const receipt3 = await governance.getReceipt(proposalId, voter3.address);
            expect(receipt3.hasVoted).to.equal(true);
            expect(receipt3.voteType).to.equal(VoteType.Abstain);
            expect(receipt3.votes).to.equal(ethers.parseEther("200000"));

            // Check total vote counts
            const votes = await governance.getProposalVotes(proposalId);
            expect(votes.forVotes).to.equal(ethers.parseEther("500000"));
            expect(votes.againstVotes).to.equal(ethers.parseEther("300000"));
            expect(votes.abstainVotes).to.equal(ethers.parseEther("200000"));
        });

        it("Should not allow double voting", async function () {
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");

            await expect(
                governance.connect(voter1).castVote(proposalId, VoteType.Against, "Changed mind")
            ).to.be.revertedWithCustomError(governance,"AlreadyVoted")
        });

        it("Should not allow voting before start time", async function () {
            // We'd need a proposal with a future start time for this test
            // For this test, we'll use time manipulation to go back in time
            await helpers.time.setNextBlockTimestamp((await ethers.provider.getBlock("latest")).timestamp - 100);

            await expect(
                governance.connect(voter1).castVote(proposalId, VoteType.For, "Too early")
            ).to.be.revertedWithCustomError(governance,"VotingNotStarted"); 
        });

        it("Should not allow voting after end time", async function () {
            await time.increase(votingPeriod + 1);

            await expect(
                governance.connect(voter1).castVote(proposalId, VoteType.For, "Too late")
            ).to.be.revertedWithCustomError(governance,"VotingEnded")
        });

        it("Should not allow invalid vote types", async function () {
            await expect(
                governance.connect(voter1).castVote(proposalId, 3, "Invalid vote type")
            ).to.be.revertedWithCustomError(governance,"InvalidVoteType")
        });
    });

    describe("Proposal State Transitions", function () {
        let proposalId;
        const votingPeriod = 4 * 24 * 60 * 60; // 4 days

        beforeEach(async function () {
            // Create a standard proposal
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"),
                        4 * 24 * 60 * 60,
                        10 * 24 * 60 * 60,
                        500,
                        3 * 24 * 60 * 60,
                        4 * 24 * 60 * 60
                    ]
                )
            ];
            const description = "Test proposal for state transitions";

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event.args.proposalId;
        });

        it("Should transition through all states correctly", async function () {
            // Initially active
            expect(await governance.state(proposalId)).to.equal(ProposalState.Active);

            // Vote to pass quorum and succeed
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");

            // Still active during voting period
            expect(await governance.state(proposalId)).to.equal(ProposalState.Active);

            // End voting period
            await time.increase(votingPeriod + 1);

            // Should be in Succeeded state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Succeeded);

            // Move to execution delay period
            await time.increase(executionDelay + 1);

            // Should be in Queued state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Queued);

            // Execute the proposal
            await governance.executeProposal(proposalId);

            // Should be in Executed state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Executed);
        });

        it("Should move to Defeated state if quorum not met", async function () {
            // Only voter3 votes (not enough for quorum)
            await governance.connect(voter3).castVote(proposalId, VoteType.For, "Support");

            // End voting period
            await time.increase(votingPeriod + 1);

            // Should be in Defeated state due to not meeting quorum
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });

        it("Should move to Defeated state if against votes win", async function () {
            // Voter1 votes for, voter2 and voter3 vote against
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await governance.connect(voter2).castVote(proposalId, VoteType.Against, "Against");
            await governance.connect(voter3).castVote(proposalId, VoteType.Against, "Against");

            // End voting period
            await time.increase(votingPeriod + 1);

            // Should be in Defeated state due to more against votes
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });

        it("Should move to Expired state if not executed in time", async function () {
            // Vote to pass
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");

            // End voting period and go past execution delay
            await time.increase(votingPeriod + executionDelay + 1);

            // Should be in Queued state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Queued);

            // Go past execution period
            await time.increase(executionPeriod + 1);

            // Should be in Expired state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Expired);
        });
    });

    describe("Proposal Execution", function () {
        let proposalId;

        beforeEach(async function () {
            // Create a proposal to update governance parameters
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"), // New proposal threshold
                        4 * 24 * 60 * 60, // New min voting period
                        10 * 24 * 60 * 60, // New max voting period
                        500, // New quorum threshold
                        3 * 24 * 60 * 60, // New execution delay
                        4 * 24 * 60 * 60 // New execution period
                    ]
                )
            ];
            const description = "Test proposal for execution";
            const votingPeriod = 4 * 24 * 60 * 60; // 4 days

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event.args.proposalId;

            // Vote to pass
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");

            // End voting period and go past execution delay
            await time.increase(votingPeriod + executionDelay + 1);
        });

        it("Should execute a proposal successfully", async function () {
            // Execute the proposal
            await governance.executeProposal(proposalId);

            // Verify state is Executed
            expect(await governance.state(proposalId)).to.equal(ProposalState.Executed);

            // Verify the parameters were updated
            expect(await governance.proposalThreshold()).to.equal(ethers.parseEther("150000"));
            expect(await governance.minVotingPeriod()).to.equal(4 * 24 * 60 * 60);
            expect(await governance.maxVotingPeriod()).to.equal(10 * 24 * 60 * 60);
            expect(await governance.quorumThreshold()).to.equal(500);
            expect(await governance.executionDelay()).to.equal(3 * 24 * 60 * 60);
            expect(await governance.executionPeriod()).to.equal(4 * 24 * 60 * 60);
        });

        it("Should not execute a proposal in the wrong state", async function () {
            // Try executing a successful proposal that's still in Succeeded state
            await time.increaseTo((await ethers.provider.getBlock("latest")).timestamp - executionDelay); // Go back in time

            await expect(
                governance.executeProposal(proposalId)
            ).to.be.revertedWithCustomError(governance, "ProposalNotQueued")

            // Try executing a defeated proposal
            // First, create a new proposal that won't pass
            const tx = await governance.connect(voter1).createProposal(
                [await governance.getAddress()],
                ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"],
                [ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"),
                        4 * 24 * 60 * 60,
                        10 * 24 * 60 * 60,
                        500,
                        3 * 24 * 60 * 60,
                        4 * 24 * 60 * 60
                    ]
                )],
                "Proposal that will be defeated",
                4 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const failedProposalId = event.args.proposalId;

            // Vote against
            await governance.connect(voter1).castVote(failedProposalId, VoteType.Against, "Against");
            await governance.connect(voter2).castVote(failedProposalId, VoteType.Against, "Against");

            // End voting period
            await time.increase(4 * 24 * 60 * 60 + 1);

            // Verify state is Defeated
            expect(await governance.state(failedProposalId)).to.equal(ProposalState.Defeated);

            // Try to execute
            await expect(
                governance.executeProposal(failedProposalId)
            ).to.be.revertedWithCustomError(governance,"ProposalNotQueued")
        });

        it("Should not allow executing an already executed proposal", async function () {
            // Execute once
            await governance.executeProposal(proposalId);

            // Try to execute again
            await expect(
                governance.executeProposal(proposalId)
            ).to.be.revertedWithCustomError(governance,"ProposalNotQueued")
        });
    });

    describe("Proposal Cancellation", function () {
        let proposalId;

        beforeEach(async function () {
            // Create a standard proposal
            const tx = await governance.connect(voter1).createProposal(
                [await governance.getAddress()],
                ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"],
                [ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"),
                        4 * 24 * 60 * 60,
                        10 * 24 * 60 * 60,
                        500,
                        3 * 24 * 60 * 60,
                        4 * 24 * 60 * 60
                    ]
                )],
                "Test proposal for cancellation",
                4 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event.args.proposalId;
        });

        it("Should allow proposer to cancel their proposal", async function () {
            // Verify initial state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Active);

            // Cancel as proposer
            await governance.connect(voter1).cancelProposal(proposalId);

            // Verify state changed to Defeated
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);

            // Check proposal removed from active list
            const activeProposals = await governance.getActiveProposals();
            expect(activeProposals).to.not.include(proposalId);
        });

        it("Should not allow non-proposer to cancel unless proposer drops below threshold", async function () {
            // Try to cancel as non-proposer
            await expect(
                governance.connect(voter2).cancelProposal(proposalId)
            ).to.be.revertedWithCustomError(governance,"NotProposer")

            // Reduce proposer's balance below threshold
            await teachToken.connect(voter1).transfer(voter3.address, ethers.parseEther("450000"));

            // Now non-proposer should be able to cancel
            await governance.connect(voter2).cancelProposal(proposalId);

            // Verify state changed to Defeated
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });

        it("Should not allow cancellation of proposals in terminal states", async function () {
            // Create a proposal, get it to Succeeded state
            const tx = await governance.connect(voter1).createProposal(
                [await governance.getAddress()],
                ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"],
                [ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"),
                        4 * 24 * 60 * 60,
                        10 * 24 * 60 * 60,
                        500,
                        3 * 24 * 60 * 60,
                        4 * 24 * 60 * 60
                    ]
                )],
                "Proposal to succeeded state",
                4 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const successProposalId = event.args.proposalId;

            await governance.connect(voter1).castVote(successProposalId, VoteType.For, "Support");
            await time.increase(4 * 24 * 60 * 60 + 1);

            // Verify state is Succeeded
            expect(await governance.state(successProposalId)).to.equal(ProposalState.Succeeded);

            // Try to cancel
            await expect(
                governance.connect(voter1).cancelProposal(successProposalId)
            ).to.be.revertedWithCustomError(governance,"InvalidProposalState")
        });
    });

    describe("Treasury Management", function () {
        beforeEach(async function () {
            // Allow the governance token
            await governance.setTokenAllowance(await teachToken.getAddress(), true);

            // Mint more tokens for treasury tests
            await teachToken.mint(voter1.address, ethers.parseEther("10000"));
            await teachToken.connect(voter1).approve(await governance.getAddress(), ethers.parseEther("10000"));
        });

        it("Should allow token allowance management", async function () {
            // Check initial state
            expect(await governance.allowedTokens(await teachToken.getAddress())).to.equal(true);

            // Set allowance for another token
            const mockToken = await ethers.deployContract("MockERC20", ["MockToken", "MCK"]);
            await governance.setTokenAllowance(await mockToken.getAddress(), true);

            // Verify allowance set
            expect(await governance.allowedTokens(await mockToken.getAddress())).to.equal(true);

            // Disable allowance
            await governance.setTokenAllowance(await mockToken.getAddress(), false);

            // Verify allowance removed
            expect(await governance.allowedTokens(await mockToken.getAddress())).to.equal(false);
        });

        it("Should allow depositing allowed tokens", async function () {
            // Deposit tokens to treasury
            await governance.connect(voter1).depositToTreasury(
                await teachToken.getAddress(),
                ethers.parseEther("1000")
            );

            // Check treasury balance
            expect(await governance.getTreasuryBalance(await teachToken.getAddress())).to.equal(ethers.parseEther("1000"));
        });

        it("Should not allow depositing non-allowed tokens", async function () {
            // Deploy a mock token
            const mockToken = await ethers.deployContract("MockERC20", ["MockToken", "MCK"]);
            await mockToken.mint(voter1.address, ethers.parseEther("1000"));
            await mockToken.connect(voter1).approve(await governance.getAddress(), ethers.parseEther("1000"));

            // Try to deposit non-allowed token
            await expect(
                governance.connect(voter1).depositToTreasury(
                    await mockToken.getAddress(),
                    ethers.parseEther("1000")
                )
            ).to.be.revertedWithCustomError(governance,"TokenNotAllowed")
        });

        it("Should only allow withdrawing via proposal", async function () {
            // Deposit tokens first
            await governance.connect(voter1).depositToTreasury(
                await teachToken.getAddress(),
                ethers.parseEther("1000")
            );

            // Try to withdraw directly (should fail)
            await expect(
                governance.withdrawFromTreasury(
                    await teachToken.getAddress(),
                    voter2.address,
                    ethers.parseEther("500")
                )
            ).to.be.revertedWithCustomError(governance,"OnlyViaProposal")

            // Create proposal to withdraw
            const targets = [await governance.getAddress()];
            const signatures = ["withdrawFromTreasury(address,address,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "address", "uint256"],
                    [
                        await teachToken.getAddress(),
                        voter2.address,
                        ethers.parseEther("500")
                    ]
                )
            ];
            const description = "Proposal to withdraw from treasury";
            const votingPeriod = 4 * 24 * 60 * 60;

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            // Vote and pass the proposal
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await time.increase(votingPeriod + executionDelay + 1);

            // Execute withdrawal proposal
            await governance.executeProposal(proposalId);

            // Check balances
            expect(await governance.getTreasuryBalance(await teachToken.getAddress())).to.equal(ethers.parseEther("500"));
            expect(await teachToken.balanceOf(voter2.address)).to.equal(ethers.parseEther("500"));
        });
    });

    describe("Guardian System", function () {
        let proposalId;

        beforeEach(async function () {
            // Add guardians
            await governance.addGuardian(guardians[0].address);
            await governance.addGuardian(guardians[1].address);
            await governance.addGuardian(guardians[2].address);

            // Set emergency parameters
            await governance.setEmergencyParameters(24, 2); // 24h window, 2 guardians required

            // Create a potentially malicious proposal
            const tx = await governance.connect(voter1).createProposal(
                [await governance.getAddress()],
                ["setTokenAllowance(address,bool)"],
                [ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "bool"],
                    [ethers.ZeroAddress, true] // Zero address is suspicious
                )],
                "Potentially malicious proposal",
                4 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event.args.proposalId;
        });

        it("Should allow guardian management", async function () {
            // Verify guardians added correctly
            expect(await governance.guardians(guardians[0].address)).to.equal(true);
            expect(await governance.guardians(guardians[1].address)).to.equal(true);
            expect(await governance.guardians(guardians[2].address)).to.equal(true);

            // Remove a guardian
            await governance.removeGuardian(guardians[1].address);

            // Verify guardian removed
            expect(await governance.guardians(guardians[1].address)).to.equal(false);
        });

        it("Should allow emergency parameter configuration", async function () {
            // Update emergency parameters
            await governance.setEmergencyParameters(48, 3); // 48h window, 3 guardians

            // Verify updated parameters
            expect(await governance.emergencyPeriod()).to.equal(48);
            expect(await governance.requiredGuardians()).to.equal(3);
        });

        it("Should allow guardians to cancel a malicious proposal", async function () {
            // Vote to cancel by first guardian
            await governance.connect(guardians[0]).voteToCancel(proposalId, "Suspicious address in proposal");

            // Proposal should still be active
            expect(await governance.state(proposalId)).to.equal(ProposalState.Active);

            // Vote to cancel by second guardian
            await governance.connect(guardians[1]).voteToCancel(proposalId, "Zero address should not be allowed");

            // Proposal should now be cancelled
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });

        it("Should not allow non-guardians to vote for cancellation", async function () {
            // Try to vote to cancel as non-guardian
            await expect(
                governance.connect(voter2).voteToCancel(proposalId, "I don't like this proposal")
            ).to.be.revertedWithCustomError(governance,"NotGuardian")
        });

        it("Should not allow voting for cancellation outside emergency period", async function () {
            // Fast forward past emergency period
            await time.increase(25 * 60 * 60); // 25 hours

            // Try to vote to cancel
            await expect(
                governance.connect(guardians[0]).voteToCancel(proposalId, "Too late to cancel")
            ).to.be.revertedWithCustomError(governance,"EmergencyPeriodExpired")
        });

        it("Should not allow voting for cancellation on proposals in terminal states", async function () {
            // Get proposal to Succeeded state
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await time.increase(4 * 24 * 60 * 60 + 1);

            // Verify state is Succeeded
            expect(await governance.state(proposalId)).to.equal(ProposalState.Succeeded);

            // Try to vote to cancel
            await expect(
                governance.connect(guardians[0]).voteToCancel(proposalId, "Too late to cancel")
            ).to.be.revertedWithCustomError(governance,"InvalidProposalState")
        });

        it("Should not allow duplicate cancellation votes", async function () {
            // Vote to cancel
            await governance.connect(guardians[0]).voteToCancel(proposalId, "Suspicious proposal");

            // Try to vote again
            await expect(
                governance.connect(guardians[0]).voteToCancel(proposalId, "Voting again")
            ).to.be.revertedWithCustomError(governance,"AlreadyVotedForCancellation")
        });
    });

    describe("Governance by Proposal Execution", function () {
        it("Should allow governance parameter changes via proposal", async function () {
            // Create proposal to update governance parameters
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("150000"), // New proposal threshold
                        4 * 24 * 60 * 60, // New min voting period
                        10 * 24 * 60 * 60, // New max voting period
                        500, // New quorum threshold
                        3 * 24 * 60 * 60, // New execution delay
                        4 * 24 * 60 * 60 // New execution period
                    ]
                )
            ];
            const description = "Proposal to update governance parameters";
            const votingPeriod = 4 * 24 * 60 * 60;

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            // Vote and pass the proposal
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await time.increase(votingPeriod + executionDelay + 1);

            // Execute the proposal
            await governance.executeProposal(proposalId);

            // Verify parameters updated
            expect(await governance.proposalThreshold()).to.equal(ethers.parseEther("150000"));
            expect(await governance.minVotingPeriod()).to.equal(4 * 24 * 60 * 60);
            expect(await governance.maxVotingPeriod()).to.equal(10 * 24 * 60 * 60);
            expect(await governance.quorumThreshold()).to.equal(500);
            expect(await governance.executionDelay()).to.equal(3 * 24 * 60 * 60);
            expect(await governance.executionPeriod()).to.equal(4 * 24 * 60 * 60);
        });

        it("Should allow treasury withdrawals via proposal", async function () {
            // Deposit tokens to treasury
            await governance.setTokenAllowance(await teachToken.getAddress(), true);
            await teachToken.connect(voter1).approve(await governance.getAddress(), ethers.parseEther("1000"));
            await governance.connect(voter1).depositToTreasury(
                await teachToken.getAddress(),
                ethers.parseEther("1000")
            );

            // Create proposal to withdraw
            const targets = [await governance.getAddress()];
            const signatures = ["withdrawFromTreasury(address,address,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "address", "uint256"],
                    [
                        await teachToken.getAddress(),
                        voter3.address,
                        ethers.parseEther("500")
                    ]
                )
            ];
            const description = "Proposal to withdraw from treasury";
            const votingPeriod = 4 * 24 * 60 * 60;

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            // Vote and pass the proposal
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await time.increase(votingPeriod + executionDelay + 1);

            // Execute the proposal
            await governance.executeProposal(proposalId);

            // Verify treasury withdrawal
            expect(await governance.getTreasuryBalance(await teachToken.getAddress())).to.equal(ethers.parseEther("500"));
            expect(await teachToken.balanceOf(voter3.address)).to.equal(ethers.parseEther("500"));
        });

        it("Should allow updating staking parameters via proposal", async function () {
            // Create proposal to update staking parameters
            const targets = [await governance.getAddress()];
            const signatures = ["setStakingContract(address,uint16,uint16)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint16", "uint16"],
                    [
                        await stakingContract.getAddress(),
                        300, // 3x max multiplier
                        730 // 2 years max staking period
                    ]
                )
            ];
            const description = "Proposal to update staking parameters";
            const votingPeriod = 4 * 24 * 60 * 60;

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            // Vote and pass the proposal
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support");
            await time.increase(votingPeriod + executionDelay + 1);

            // Execute the proposal
            await governance.executeProposal(proposalId);

            // Verify staking parameters updated
            expect(await governance.stakingContract()).to.equal(await stakingContract.getAddress());
            expect(await governance.maxStakingMultiplier()).to.equal(300);
            expect(await governance.maxStakingPeriod()).to.equal(730);
        });
    });

    describe("Parameter Change Timelock", function () {
        it("Should schedule and execute parameter changes with timelock", async function () {
            // Set timelock delay
            await governance.setParameterChangeDelay(86400); // 1 day

            // Schedule parameter change
            await governance.updateGovernanceParameters(
                ethers.parseEther("200000"), // New proposal threshold
                5 * 24 * 60 * 60, // New min voting period
                14 * 24 * 60 * 60, // New max voting period
                600, // New quorum threshold
                4 * 24 * 60 * 60, // New execution delay
                5 * 24 * 60 * 60 // New execution period
            );

            // Try to execute immediately (should fail)
            await expect(
                governance.executeParameterChange()
            ).to.be.revertedWithCustomError(governance,"TimelockNotExpired")

            // Fast forward past timelock
            await time.increase(86401);

            // Execute parameter change
            await governance.executeParameterChange();

            // Verify parameters updated
            expect(await governance.proposalThreshold()).to.equal(ethers.parseEther("200000"));
            expect(await governance.minVotingPeriod()).to.equal(5 * 24 * 60 * 60);
            expect(await governance.maxVotingPeriod()).to.equal(14 * 24 * 60 * 60);
            expect(await governance.quorumThreshold()).to.equal(600);
            expect(await governance.executionDelay()).to.equal(4 * 24 * 60 * 60);
            expect(await governance.executionPeriod()).to.equal(5 * 24 * 60 * 60);
        });

        it("Should not allow scheduling another change while one is pending", async function () {
            // Schedule first parameter change
            await governance.updateGovernanceParameters(
                ethers.parseEther("200000"),
                5 * 24 * 60 * 60,
                14 * 24 * 60 * 60,
                600,
                4 * 24 * 60 * 60,
                5 * 24 * 60 * 60
            );

            // Try to schedule another change
            await expect(
                governance.updateGovernanceParameters(
                    ethers.parseEther("250000"),
                    6 * 24 * 60 * 60,
                    15 * 24 * 60 * 60,
                    700,
                    5 * 24 * 60 * 60,
                    6 * 24 * 60 * 60
                )
            ).to.be.revertedWithCustomError(governance,"ChangeAlreadyPending")
        });

        it("Should allow cancelling a pending parameter change", async function () {
            // Schedule parameter change
            await governance.updateGovernanceParameters(
                ethers.parseEther("200000"),
                5 * 24 * 60 * 60,
                14 * 24 * 60 * 60,
                600,
                4 * 24 * 60 * 60,
                5 * 24 * 60 * 60
            );

            // Cancel the change
            await governance.cancelParameterChange();

            // Verify it's cancelled by being able to schedule a new change
            await governance.updateGovernanceParameters(
                ethers.parseEther("250000"),
                6 * 24 * 60 * 60,
                15 * 24 * 60 * 60,
                700,
                5 * 24 * 60 * 60,
                6 * 24 * 60 * 60
            );
        });
    });

    describe("Voting Power Calculation", function () {
        beforeEach(async function () {
            // Set up staking for voter3
            await teachToken.connect(voter3).approve(await stakingContract.getAddress(), ethers.parseEther("100000"));

            // Create a staking pool
            await stakingContract.createStakingPool(
                "Test Pool",
                "100", // reward rate
                365 * 24 * 60 * 60, // 1 year lock
                1000, // 10% early withdrawal fee
            );

            // Activate the pool
            await stakingContract.updateStakingPool(
                0, // pool ID
                "100", // reward rate
                365 * 24 * 60 * 60, // 1 year lock
                1000, // 10% early withdrawal fee
                true // active
            );

            // Register a school for staking beneficiary
            await stakingContract.registerSchool(owner.address, "Test School");
        });

        it("Should calculate standard voting power based on token balance", async function () {
            // Check voting power = token balance for standard holders
            expect(await governance.getVotingPower(voter1.address)).to.equal(ethers.parseEther("500000"));
            expect(await governance.getVotingPower(voter2.address)).to.equal(ethers.parseEther("300000"));
        });

        it("Should apply staking weight when user has staked tokens", async function () {
            // Record initial voting power
            const initialVotingPower = await governance.getVotingPower(voter3.address);

            // Stake tokens
            await stakingContract.connect(voter3).stake(0, ethers.parseEther("100000"), owner.address);

            // Fast forward 183 days (halfway through 1 year)
            await time.increase(183 * 24 * 60 * 60);

            // Update voting power
            await stakingContract.notifyGovernanceOfStakeChange(voter3.address);

            // Get new voting power
            const newVotingPower = await governance.getVotingPower(voter3.address);

            // With 50% time elapsed and max multiplier of 2x, expect ~1.5x voting power
            // Initial voting power (100k tokens) + some boost from staking
            expect(newVotingPower).to.be.gt(initialVotingPower);
        });

        it("Should update voting power when staking changes", async function () {
            // Stake some tokens
            await stakingContract.connect(voter3).stake(0, ethers.parseEther("50000"), owner.address);

            // Fast forward 90 days
            await time.increase(90 * 24 * 60 * 60);

            // Update voting power
            await stakingContract.notifyGovernanceOfStakeChange(voter3.address);

            // Record voting power
            const votingPower1 = await governance.getVotingPower(voter3.address);

            // Stake more tokens
            await stakingContract.connect(voter3).stake(0, ethers.parseEther("50000"), owner.address);

            // Update voting power again
            await stakingContract.notifyGovernanceOfStakeChange(voter3.address);

            // Get new voting power
            const votingPower2 = await governance.getVotingPower(voter3.address);

            // Should have increased
            expect(votingPower2).to.be.gt(votingPower1);
        });
    });

    describe("Emergency Functions", function () {
        it("Should trigger system emergency", async function () {
            // Trigger emergency
            await governance.triggerSystemEmergency("Critical security issue detected");

            // Should have set emergency state
            expect(await governance.paused()).to.equal(true);
        });

        it("Should allow governance emergency recovery", async function () {
            // Setup test environment for recovery
            await governance.grantRole(ADMIN_ROLE, guardians[0].address);
            await governance.grantRole(ADMIN_ROLE, guardians[1].address);
            await governance.grantRole(ADMIN_ROLE, guardians[2].address);

            // Pause governance
            await governance.pauseGovernance();
            expect(await governance.paused()).to.equal(true);

            // Set recovery requirements
            await governance.setRecoveryRequirements(2, 48); // 2 guardians, 48 hour window

            // Start recovery process
            await governance.connect(guardians[0]).initiateRecovery();

            // First approval
            await governance.connect(guardians[1]).approveRecovery();

            // Should still be paused
            expect(await governance.paused()).to.equal(true);

            // Second approval (should trigger recovery)
            await governance.connect(guardians[2]).approveRecovery();

            // Should be unpaused now
            expect(await governance.paused()).to.equal(false);
        });
    });

    describe("Registry Integration", function () {
        it("Should update contract references from registry", async function () {
            // Deploy new token and staking contracts
            const newToken = await upgrades.deployProxy(
                await ethers.getContractFactory("TeachToken"),
                [],
                { initializer: "initialize" }
            );

            const newStaking = await upgrades.deployProxy(
                await ethers.getContractFactory("TokenStaking"),
                [await newToken.getAddress(), owner.address],
                { initializer: "initialize" }
            );

            // Update contracts in registry
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
            const STAKING_NAME = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_STAKING"));

            await registry.updateContract(TOKEN_NAME, await newToken.getAddress(), "0x00000000");
            await registry.updateContract(STAKING_NAME, await newStaking.getAddress(), "0x00000000");

            // Update references in governance
            await governance.updateContractReferences();

            // Verify references updated
            expect(await governance.token()).to.equal(await newToken.getAddress());
            expect(await governance.stakingContract()).to.equal(await newStaking.getAddress());
        });

        it("Should use fallback address cache when registry is unavailable", async function () {
            // Set fallback addresses
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("TEACH_TOKEN"));
            await governance.setFallbackAddress(TOKEN_NAME, await teachToken.getAddress());

            // Enable offline mode
            await governance.enableRegistryOfflineMode();

            // Create a proposal to verify governance still works
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("200000"),
                        5 * 24 * 60 * 60,
                        14 * 24 * 60 * 60,
                        600,
                        4 * 24 * 60 * 60,
                        5 * 24 * 60 * 60
                    ]
                )
            ];
            const description = "Proposal during offline mode";
            const votingPeriod = 4 * 24 * 60 * 60;

            await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );

            // Disable offline mode
            await governance.disableRegistryOfflineMode();
        });
    });

    describe("Upgradeability", function() {
        it("Should be upgradeable using the UUPS pattern", async function() {
            // Create a proposal
            const targets = [await governance.getAddress()];
            const signatures = ["updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
                    [
                        ethers.parseEther("200000"),
                        5 * 24 * 60 * 60,
                        14 * 24 * 60 * 60,
                        600,
                        4 * 24 * 60 * 60,
                        5 * 24 * 60 * 60
                    ]
                )
            ];
            const description = "Test proposal";
            const votingPeriod = 4 * 24 * 60 * 60;

            const tx = await governance.connect(voter1).createProposal(
                targets, signatures, calldatas, description, votingPeriod
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            const proposalId = event.args.proposalId;

            // Deploy new implementation
            const GovernanceV2 = await ethers.getContractFactory("PlatformGovernance");

            // Upgrade to new implementation
            const upgradedGovernance = await upgrades.upgradeProxy(
                await governance.getAddress(),
                GovernanceV2
            );

            // Check address remains the same
            expect(await upgradedGovernance.getAddress()).to.equal(await governance.getAddress());

            // Verify state is preserved
            const proposalDetails = await upgradedGovernance.getProposalDetails(proposalId);
            expect(proposalDetails.proposer).to.equal(voter1.address);
            expect(proposalDetails.description).to.equal(description);

            // Verify active proposals remain
            const activeProposals = await upgradedGovernance.getActiveProposals();
            expect(activeProposals).to.include(proposalId);
        });
    });
});