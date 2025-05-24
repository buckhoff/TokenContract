// MockGovernance.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockGovernance
 * @dev Mock implementation of governance for testing
 */
contract MockGovernance {
    // Proposal structure
    struct Proposal {
        uint256 id;
        string title;
        string description;
        address proposer;
        uint256 startTime;
        uint256 endTime;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votesAbstain;
        bool executed;
        bool canceled;
        ProposalType proposalType;
        bytes executionData;
    }

    enum ProposalType {
        PARAMETER_CHANGE,
        CONTRACT_UPGRADE,
        TREASURY_ALLOCATION,
        EMERGENCY_ACTION,
        GENERAL
    }

    enum VoteType {
        FOR,
        AGAINST,
        ABSTAIN
    }

    // Storage
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => VoteType)) public userVotes;
    mapping(address => uint256) public votingPower;
    mapping(address => uint256) public delegatedPower;
    mapping(address => address) public delegates;

    uint256 public nextProposalId = 1;
    uint256 public votingPeriod = 7 days;
    uint256 public minimumQuorum = 1000000; // Minimum votes needed
    uint256 public proposalThreshold = 100000; // Minimum tokens to propose

    // Governance parameters
    uint256 public proposalDelay = 1 days;
    uint256 public executionDelay = 2 days;
    bool public governancePaused;

    // Events
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title);
    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteType vote, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed delegate);

    /**
     * @dev Create a new proposal
     */
    function createProposal(
        string memory _title,
        string memory _description,
        ProposalType _type,
        bytes memory _executionData
    ) external returns (uint256) {
        require(!governancePaused, "Governance paused");
        require(votingPower[msg.sender] >= proposalThreshold, "Insufficient voting power");

        uint256 proposalId = nextProposalId++;

        proposals[proposalId] = Proposal({
            id: proposalId,
            title: _title,
            description: _description,
            proposer: msg.sender,
            startTime: block.timestamp + proposalDelay,
            endTime: block.timestamp + proposalDelay + votingPeriod,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            executed: false,
            canceled: false,
            proposalType: _type,
            executionData: _executionData
        });

        emit ProposalCreated(proposalId, msg.sender, _title);
        return proposalId;
    }

    /**
     * @dev Cast a vote on a proposal
     */
    function castVote(uint256 _proposalId, VoteType _vote) external {
        require(!governancePaused, "Governance paused");
        require(proposals[_proposalId].id != 0, "Proposal does not exist");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");
        require(block.timestamp >= proposals[_proposalId].startTime, "Voting not started");
        require(block.timestamp <= proposals[_proposalId].endTime, "Voting ended");

        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No voting power");

        hasVoted[_proposalId][msg.sender] = true;
        userVotes[_proposalId][msg.sender] = _vote;

        if (_vote == VoteType.FOR) {
            proposals[_proposalId].votesFor += weight;
        } else if (_vote == VoteType.AGAINST) {
            proposals[_proposalId].votesAgainst += weight;
        } else {
            proposals[_proposalId].votesAbstain += weight;
        }

        emit VoteCast(_proposalId, msg.sender, _vote, weight);
    }

    /**
     * @dev Execute a successful proposal
     */
    function executeProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.id != 0, "Proposal does not exist");
        require(!proposal.executed, "Already executed");
        require(!proposal.canceled, "Proposal canceled");
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(block.timestamp > proposal.endTime + executionDelay, "Execution delay not met");

        // Check if proposal passed
        require(isProposalSuccessful(_proposalId), "Proposal did not pass");

        proposal.executed = true;

        // Mock execution - in real implementation would execute the proposal data
        emit ProposalExecuted(_proposalId);
    }

    /**
     * @dev Cancel a proposal
     */
    function cancelProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.id != 0, "Proposal does not exist");
        require(!proposal.executed, "Already executed");
        require(msg.sender == proposal.proposer, "Not proposer");

        proposal.canceled = true;
        emit ProposalCanceled(_proposalId);
    }

    /**
     * @dev Delegate voting power to another address
     */
    function delegate(address _delegate) external {
        require(_delegate != msg.sender, "Cannot delegate to self");

        address currentDelegate = delegates[msg.sender];
        if (currentDelegate != address(0)) {
            delegatedPower[currentDelegate] -= votingPower[msg.sender];
        }

        delegates[msg.sender] = _delegate;
        if (_delegate != address(0)) {
            delegatedPower[_delegate] += votingPower[msg.sender];
        }

        emit DelegateChanged(msg.sender, _delegate);
    }

    /**
     * @dev Get voting power for an address (including delegated power)
     */
    function getVotingPower(address _voter) public view returns (uint256) {
        return votingPower[_voter] + delegatedPower[_voter];
    }

    /**
     * @dev Set voting power for testing
     */
    function setVotingPower(address _voter, uint256 _power) external {
        votingPower[_voter] = _power;
    }

    /**
     * @dev Check if a proposal was successful
     */
    function isProposalSuccessful(uint256 _proposalId) public view returns (bool) {
        Proposal storage proposal = proposals[_proposalId];

        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;

        // Check quorum
        if (totalVotes < minimumQuorum) {
            return false;
        }

        // Check if more votes for than against
        return proposal.votesFor > proposal.votesAgainst;
    }

    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 _proposalId) external view returns (Proposal memory) {
        return proposals[_proposalId];
    }

    /**
     * @dev Get voting results for a proposal
     */
    function getVotingResults(uint256 _proposalId) external view returns (
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        uint256 totalVotes,
        bool hasQuorum,
        bool isSuccessful
    ) {
        Proposal storage proposal = proposals[_proposalId];
        votesFor = proposal.votesFor;
        votesAgainst = proposal.votesAgainst;
        votesAbstain = proposal.votesAbstain;
        totalVotes = votesFor + votesAgainst + votesAbstain;
        hasQuorum = totalVotes >= minimumQuorum;
        isSuccessful = isProposalSuccessful(_proposalId);
    }

    /**
     * @dev Check if user has voted on a proposal
     */
    function hasUserVoted(uint256 _proposalId, address _user) external view returns (bool) {
        return hasVoted[_proposalId][_user];
    }

    /**
     * @dev Get user's vote on a proposal
     */
    function getUserVote(uint256 _proposalId, address _user) external view returns (VoteType) {
        require(hasVoted[_proposalId][_user], "User has not voted");
        return userVotes[_proposalId][_user];
    }

    /**
     * @dev Set governance parameters
     */
    function setVotingPeriod(uint256 _period) external {
        votingPeriod = _period;
    }

    function setMinimumQuorum(uint256 _quorum) external {
        minimumQuorum = _quorum;
    }

    function setProposalThreshold(uint256 _threshold) external {
        proposalThreshold = _threshold;
    }

    function setProposalDelay(uint256 _delay) external {
        proposalDelay = _delay;
    }

    function setExecutionDelay(uint256 _delay) external {
        executionDelay = _delay;
    }

    /**
     * @dev Emergency governance controls
     */
    function pauseGovernance() external {
        governancePaused = true;
    }

    function unpauseGovernance() external {
        governancePaused = false;
    }

    /**
     * @dev Get current governance parameters
     */
    function getGovernanceParams() external view returns (
        uint256 votingPeriod_,
        uint256 minimumQuorum_,
        uint256 proposalThreshold_,
        uint256 proposalDelay_,
        uint256 executionDelay_,
        bool isPaused
    ) {
        votingPeriod_ = votingPeriod;
        minimumQuorum_ = minimumQuorum;
        proposalThreshold_ = proposalThreshold;
        proposalDelay_ = proposalDelay;
        executionDelay_ = executionDelay;
        isPaused = governancePaused;
    }

    /**
     * @dev Get delegate for an address
     */
    function getDelegate(address _delegator) external view returns (address) {
        return delegates[_delegator];
    }

    /**
     * @dev Get total delegated power for an address
     */
    function getDelegatedPower(address _delegate) external view returns (uint256) {
        return delegatedPower[_delegate];
    }

    /**
     * @dev Check if proposal can be executed
     */
    function canExecuteProposal(uint256 _proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[_proposalId];

        if (proposal.id == 0 || proposal.executed || proposal.canceled) {
            return false;
        }

        if (block.timestamp <= proposal.endTime) {
            return false;
        }

        if (block.timestamp <= proposal.endTime + executionDelay) {
            return false;
        }

        return isProposalSuccessful(_proposalId);
    }

    /**
     * @dev Get proposal state
     */
    function getProposalState(uint256 _proposalId) external view returns (string memory) {
        Proposal storage proposal = proposals[_proposalId];

        if (proposal.id == 0) {
            return "NonExistent";
        }

        if (proposal.canceled) {
            return "Canceled";
        }

        if (proposal.executed) {
            return "Executed";
        }

        if (block.timestamp < proposal.startTime) {
            return "Pending";
        }

        if (block.timestamp <= proposal.endTime) {
            return "Active";
        }

        if (block.timestamp <= proposal.endTime + executionDelay) {
            return "Succeeded";
        }

        if (isProposalSuccessful(_proposalId)) {
            return "Queued";
        } else {
            return "Defeated";
        }
    }

    /**
     * @dev Batch vote on multiple proposals
     */
    function batchVote(
        uint256[] memory _proposalIds,
        VoteType[] memory _votes
    ) external {
        require(_proposalIds.length == _votes.length, "Array length mismatch");

        for (uint256 i = 0; i < _proposalIds.length; i++) {
            castVote(_proposalIds[i], _votes[i]);
        }
    }

    /**
     * @dev Get active proposals
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](nextProposalId - 1);
        uint256 count = 0;

        for (uint256 i = 1; i < nextProposalId; i++) {
            if (block.timestamp >= proposals[i].startTime &&
            block.timestamp <= proposals[i].endTime &&
                !proposals[i].canceled &&
                !proposals[i].executed) {
                activeIds[count] = i;
                count++;
            }
        }

        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeIds[i];
        }

        return result;
    }

    /**
     * @dev Get proposals by type
     */
    function getProposalsByType(ProposalType _type) external view returns (uint256[] memory) {
        uint256[] memory typeIds = new uint256[](nextProposalId - 1);
        uint256 count = 0;

        for (uint256 i = 1; i < nextProposalId; i++) {
            if (proposals[i].proposalType == _type) {
                typeIds[count] = i;
                count++;
            }
        }

        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = typeIds[i];
        }

        return result;
    }
}