const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PlatformGovernance Contract", function () {
    let teachToken;
    let governance;
    let owner;
    let voter1;
    let voter2;
    let voter3;
    let guardians = [];

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

    beforeEach(async function () {
        // Get the contract factories and signers
        const TeachToken = await ethers.getContractFactory("TeachToken");
        const PlatformGovernance = await ethers.getContractFactory("PlatformGovernance");
        [owner, voter1, voter2, voter3, ...guardians] = await ethers.getSigners();

        // Deploy token
        teachToken = await upgrades.deployProxy(TeachToken, [], {
            initializer: "initialize",
        });
        await teachToken.waitForDeployment();

        // Mint tokens to voters for governance participation
        await teachToken.mint(voter1.address, ethers.parseEther("500000")); // 500k tokens
        await teachToken.mint(voter2.address, ethers.parseEther("300000")); // 300k tokens
        await teachToken.mint(voter3.address, ethers.parseEther("200000")); // 200k tokens

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
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
            const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

            expect(await governance.hasRole(ADMIN_ROLE, owner.address)).to.equal(true);
            expect(await governance.hasRole(EMERGENCY_ROLE, owner.address)).to.equal(true);
        });
    });

    describe("Proposal Creation and Voting", function () {
        let proposalId;
        const votingPeriod = 4 * 24 * 60 * 60; // 4 days

        // Sample proposal details
        const targets = [];
        const signatures = [];
        const calldatas = [];
        const description = "Test proposal to update governance parameters";

        beforeEach(async function () {
            // Add mock target address
            targets.push(await governance.getAddress());

            // Add mock function signature
            signatures.push("updateGovernanceParameters(uint256,uint256,uint256,uint256,uint256,uint256)");

            // Add mock calldata for the function
            calldatas.push(
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
            );

            // Create proposal with voter1 who has enough tokens
            const tx = await governance.connect(voter1).createProposal(
                targets,
                signatures,
                calldatas,
                description,
                votingPeriod
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event ? event.args.proposalId : 0;
        });

        it("Should create a proposal with correct details", async function () {
            const proposalDetails = await governance.getProposalDetails(proposalId);

            expect(proposalDetails.proposer).to.equal(voter1.address);
            expect(proposalDetails.description).to.equal(description);
           
            expect(proposalDetails.currentState).to.equal(ProposalState.Active);
        });
        
        it("Should not allow creating proposals below threshold", async function () {

            await teachToken.connect(voter3).transfer(voter2.address, ethers.parseEther("125000"))
            await expect(
                governance.connect(voter3).createProposal(
                    targets,
                    signatures,
                    calldatas,
                    description,
                    votingPeriod
                )
            ).to.be.revertedWith("PlatformGovernance: below proposal threshold");
        });

        it("Should track votes correctly", async function () {
            // Voter1 votes for
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support the proposal");

            // Voter2 votes against
            await governance.connect(voter2).castVote(proposalId, VoteType.Against, "Against the proposal");

            // Voter3 abstains
            await governance.connect(voter3).castVote(proposalId, VoteType.Abstain, "Abstaining from voting");

            // Get vote counts
            const votes = await governance.getProposalVotes(proposalId);

            expect(votes.againstVotes).to.equal(ethers.parseEther("300000"));
            expect(votes.forVotes).to.equal(ethers.parseEther("500000"));
            expect(votes.abstainVotes).to.equal(ethers.parseEther("200000"));
        });

        it("Should not allow double voting", async function () {
            // Voter1 votes for
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support the proposal");

            // Try to vote again
            await expect(
                governance.connect(voter1).castVote(proposalId, VoteType.Against, "Changed my mind")
            ).to.be.revertedWith("PlatformGovernance: already voted");
        });

        it("Should transition proposal state correctly", async function () {
            // Initially active
            expect(await governance.state(proposalId)).to.equal(ProposalState.Active);

            // Vote to pass
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support the proposal");

            // Fast forward past voting period
            await time.increase(votingPeriod + 1);

            // Now should be in Succeeded state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Succeeded);

            // Fast forward past execution delay
            await time.increase(executionDelay + 1);

            // Now should be in Queued state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Queued);
        });

        it("Should execute a successful proposal", async function () {
            // Vote to pass
            await governance.connect(voter1).castVote(proposalId, VoteType.For, "Support the proposal");

            // Fast forward past voting period + execution delay
            await time.increase(votingPeriod + executionDelay + 1);

            // Check state is Queued
            expect(await governance.state(proposalId)).to.equal(ProposalState.Queued);

            // Execute proposal
            await governance.executeProposal(proposalId);

            // Should be in Executed state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Executed);

            // Parameters should be updated
            expect(await governance.proposalThreshold()).to.equal(ethers.parseEther("150000"));
            expect(await governance.quorumThreshold()).to.equal(500);
        });

        it("Should allow cancellation by proposer", async function () {
            await governance.connect(voter1).cancelProposal(proposalId);

            // Should be in Defeated state
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });
    });

    describe("Treasury Management", function () {
        it("Should allow setting token allowance", async function () {
            const tokenAddress = await teachToken.getAddress();

            await governance.setTokenAllowance(tokenAddress, true);

            expect(await governance.allowedTokens(tokenAddress)).to.equal(true);
        });

        it("Should allow depositing allowed tokens", async function () {
            const tokenAddress = await teachToken.getAddress();
            const depositAmount = ethers.parseEther("5000");

            // Allow token
            await governance.setTokenAllowance(tokenAddress, true);

            // Approve governance to spend tokens
            await teachToken.connect(voter1).approve(await governance.getAddress(), depositAmount);

            // Deposit tokens
            await governance.connect(voter1).depositToTreasury(tokenAddress, depositAmount);

            // Check treasury balance
            expect(await governance.getTreasuryBalance(tokenAddress)).to.equal(depositAmount);
        });

        it("Should not allow withdrawing without a proposal", async function () {
            await expect(
                governance.withdrawFromTreasury(
                    await teachToken.getAddress(),
                    voter1.address,
                    ethers.parseEther("1000")
                )
            ).to.be.revertedWith("PlatformGovernance: only via proposal");
        });
    });

    describe("Guardian System", function () {
        let proposalId;

        beforeEach(async function () {
            // Create a controversial proposal
            const targets = [await governance.getAddress()];
            const signatures = ["setTokenAllowance(address,bool)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "bool"],
                    [ethers.ZeroAddress, true] // Zero address is suspicious
                )
            ];

            // Create proposal
            const tx = await governance.connect(voter1).createProposal(
                targets,
                signatures,
                calldatas,
                "Controversial proposal",
                4 * 24 * 60 * 60
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'ProposalCreated');
            proposalId = event ? event.args.proposalId : 0;

            // Add guardians
            for (let i = 0; i < 3; i++) {
                await governance.addGuardian(guardians[i].address);
            }

            // Set emergency parameters
            await governance.setEmergencyParameters(24, 2); // 24h window, 2 guardians required
        });

        it("Should register guardians correctly", async function () {
            for (let i = 0; i < 3; i++) {
                expect(await governance.guardians(guardians[i].address)).to.equal(true);
            }
        });

        it("Should allow guardians to vote to cancel", async function () {
            // First guardian votes to cancel
            await governance.connect(guardians[0]).voteToCancel(proposalId, "Suspicious proposal");

            // Second guardian votes to cancel
            await governance.connect(guardians[1]).voteToCancel(proposalId, "Suspicious address");

            // Proposal should be canceled (2 guardians required)
            expect(await governance.state(proposalId)).to.equal(ProposalState.Defeated);
        });

        it("Should not allow non-guardians to vote to cancel", async function () {
            await expect(
                governance.connect(voter2).voteToCancel(proposalId, "I don't like this")
            ).to.be.revertedWith("PlatformGovernance: not a guardian");
        });

        it("Should not allow cancellations after emergency period", async function () {
            // Fast forward past emergency period (24h)
            await time.increase(25 * 60 * 60);

            await expect(
                governance.connect(guardians[0]).voteToCancel(proposalId, "Too late")
            ).to.be.revertedWith("PlatformGovernance: emergency period expired");
        });
    });

    describe("Staking Integration", function () {
        it("Should set staking contract and parameters", async function () {
            // Deploy a mock staking contract (using a token as a stand-in)
            const mockStaking = await upgrades.deployProxy(
                await ethers.getContractFactory("TeachToken"),
                [],
                { initializer: "initialize" }
            );

            // Set staking contract
            await governance.setStakingContract(
                await mockStaking.getAddress(),
                200, // 2x max multiplier
                365 // 1 year max staking period
            );

            expect(await governance.stakingContract()).to.equal(await mockStaking.getAddress());
            expect(await governance.maxStakingMultiplier()).to.equal(200);
            expect(await governance.maxStakingPeriod()).to.equal(365);
            expect(await governance.stakingWeightEnabled()).to.equal(true);
        });
    });

    describe("Parameter Management", function () {
        it("Should schedule parameter changes with timelock", async function () {
            // Schedule parameter change
            await governance.updateGovernanceParameters(
                ethers.parseEther("150000"), // New proposal threshold
                4 * 24 * 60 * 60, // New min voting period
                10 * 24 * 60 * 60, // New max voting period
                500, // New quorum threshold
                3 * 24 * 60 * 60, // New execution delay
                4 * 24 * 60 * 60 // New execution period
            );

            // Set parameter change delay
            await governance.setParameterChangeDelay(1 * 24 * 60 * 60); // 1 day

            // Fast forward past delay
            await time.increase(1 * 24 * 60 * 60 + 1);

            // Execute the change
            await governance.executeParameterChange();

            // Parameters should be updated
            expect(await governance.proposalThreshold()).to.equal(ethers.parseEther("150000"));
            expect(await governance.quorumThreshold()).to.equal(500);
        });

        it("Should allow canceling a scheduled parameter change", async function () {
            // Schedule parameter change
            await governance.updateGovernanceParameters(
                ethers.parseEther("150000"),
                4 * 24 * 60 * 60,
                10 * 24 * 60 * 60,
                500,
                3 * 24 * 60 * 60,
                4 * 24 * 60 * 60
            );

            // Cancel the change
            await governance.cancelParameterChange();

            // Try to execute (should fail)
            await expect(
                governance.executeParameterChange()
            ).to.be.revertedWith("PlatformGovernance: no pending change");
        });
    });

    describe("Registry Integration", function () {
        it("Should set and use registry", async function () {
            // Deploy registry
            const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });

            // Set registry in governance contract
            await governance.setRegistry(await registry.getAddress());
            expect(await governance.registry()).to.equal(await registry.getAddress());

            // Register token in registry
            const TOKEN_NAME = ethers.keccak256(ethers.toUtf8Bytes("_TEACH_TOKEN"));
            await registry.registerContract(TOKEN_NAME, await teachToken.getAddress(), "0x00000000");

            // Update contract references
            await governance.updateContractReferences();
        });
    });

    describe("Emergency Management", function () {
        it("Should trigger system emergency", async function () {
            // Deploy registry
            const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
            const registry = await upgrades.deployProxy(ContractRegistry, [], {
                initializer: "initialize",
            });

            // Set registry in governance contract
            await governance.setRegistry(await registry.getAddress());

            // Trigger emergency
            await governance.triggerSystemEmergency("Critical security issue");

            // Emergency state should be updated
            expect(await governance.emergencyState()).to.not.equal(0);
        });
    });

    describe("Upgradeability", function() {
        it("Should be upgradeable using the UUPS pattern", async function() {
            // Create a proposal before upgrade
            const targets = [await governance.getAddress()];
            const signatures = ["setParameterChangeDelay(uint256)"];
            const calldatas = [
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256"],
                    [3 * 24 * 60 * 60] // 3 days
                )
            ];

            await governance.connect(voter1).createProposal(
                targets,
                signatures,
                calldatas,
                "Test proposal",
                4 * 24 * 60 * 60
            );

            // Deploy a new implementation
            const GovernanceV2 = await ethers.getContractFactory("PlatformGovernance");

            // Upgrade to new implementation
            const upgradedGovernance = await upgrades.upgradeProxy(
                await governance.getAddress(),
                GovernanceV2
            );

            // Check that the address stayed the same
            expect(await upgradedGovernance.getAddress()).to.equal(await governance.getAddress());

            // Verify state is preserved
            expect(await upgradedGovernance.token()).to.equal(await teachToken.getAddress());
            expect(await upgradedGovernance.proposalThreshold()).to.equal(proposalThreshold);

            // Active proposals should still exist
            const activeProposals = await upgradedGovernance.getActiveProposals();
            expect(activeProposals.length).to.equal(1);
        });
    });
});