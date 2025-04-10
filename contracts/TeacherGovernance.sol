// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// Add the interface for staking contract
interface ITokenStaking {
    function getUserStake(uint256 _poolId, address _user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 lastClaimTime,
        uint256 pendingReward,
        address schoolBeneficiary,
        uint256 userRewardPortion,
        uint256 schoolRewardPortion
    );
    function getPoolCount() external view returns (uint256);
}

/**
 * @title TeacherGovernance
 * @dev Contract for decentralized governance of the TeacherSupport platform
 */
contract TeacherGovernance is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    // The TeachToken contract
    IERC20 public teachToken;
    
    // Proposal counter
    Counters.Counter private _proposalIdCounter;
    
    // Voting power threshold to create a proposal (in TEACH tokens)
    uint256 public proposalThreshold;
    
    // Minimum voting period in seconds
    uint256 public minVotingPeriod;
    
    // Maximum voting period in seconds
    uint256 public maxVotingPeriod;
    
    // Quorum threshold (percentage of total supply, e.g., 4% = 400)
    uint256 public quorumThreshold;
    
    // Execution delay after a proposal passes (in seconds)
    uint256 public executionDelay;
    
    // Execution period after delay (in seconds)
    uint256 public executionPeriod;

    // Timelock delay for critical parameter changes (in seconds)
    uint256 public parameterChangeDelay;

    // Pending parameter change
    PendingParameterChange public pendingChange;

    // Add state variables
    uint96 public treasuryBalance;
    mapping(address => bool) public allowedTokens;
    uint16 public emergencyPeriod; // Time in hours to allow emergency cancellation after proposal creation
    uint16 public requiredGuardians; // Minimum guardians required to cancel proposal
    mapping(address => bool) public guardians; // Addresses with guardian power
    mapping(uint256 => mapping(address => bool)) public guardianCancellations; // Track guardian votes
    mapping(uint256 => uint16) public cancellationVotes; // Count cancellation votes
    
    // Enum for proposal state
    enum ProposalState {
        Pending,    // Proposed but voting not started
        Active,     // Voting is active
        Defeated,   // Failed to reach quorum or majority
        Succeeded,  // Passed but not yet executed
        Queued,     // Waiting for execution delay
        Executed,   // Successfully executed
        Expired     // Execution time passed
    }
    
    // Enum for vote type
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    // Struct to store proposal information
    struct Proposal {
        address proposer;
        string description;
        bytes[] calldatas;
        address[] targets;
        string[] signatures;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool canceled;
        mapping(address => Receipt) receipts;
    }
    
    // Struct to store vote receipt
    struct Receipt {
        bool hasVoted;
        VoteType voteType;
        uint256 votes;
    }

    // Struct to track pending parameter changes
    struct PendingParameterChange {
        uint256 proposalThreshold;
        uint256 minVotingPeriod;
        uint256 maxVotingPeriod;
        uint256 quorumThreshold;
        uint256 executionDelay;
        uint256 executionPeriod;
        uint256 scheduledTime;
        bool isPending;
    }
    
    // Mapping from proposal ID to Proposal
    mapping(uint256 => Proposal) public proposals;
    
    // Store active proposal IDs for iteration
    uint256[] public activeProposalIds;
    
    // Mapping to track if an address token voting power is locked
    mapping(address => uint256) public votingPowerLocked;
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        string[] signatures,
        bytes[] calldatas,
        string description,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 voteType,
        uint256 votes,
        string reason
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event GovernanceParametersUpdated(
        uint256 proposalThreshold,
        uint256 minVotingPeriod,
        uint256 maxVotingPeriod,
        uint256 quorumThreshold,
        uint256 executionDelay,
        uint256 executionPeriod
    );

    // Events
    event ParameterChangeScheduled(
        uint256 proposalThreshold,
        uint256 minVotingPeriod,
        uint256 maxVotingPeriod,
        uint256 quorumThreshold,
        uint256 executionDelay,
        uint256 executionPeriod,
        uint256 scheduledTime
    );
    event ParameterChangeExecuted();
    event ParameterChangeCancelled();
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event TokenDepositedToTreasury(address token, address depositor, uint256 amount);
    event TreasuryWithdrawal(address token, address recipient, uint256 amount);
    event TokenAllowanceChanged(address token, bool allowed);
    event GuardianAdded(address guardian);
    event GuardianRemoved(address guardian);
    event ProposalCancellationVoted(uint256 indexed proposalId, address guardian);
    event ProposalEmergencyCancelled(uint256 indexed proposalId, string reason);  

    ITokenStaking public stakingContract;
    bool public stakingWeightEnabled;
    uint16 public maxStakingMultiplier; // multiplier scaled by 100 (e.g., 200 = 2x)
    uint16 public maxStakingPeriod; // in days

    /**
     * @dev Constructor sets the token address and governance parameters
     * @param _teachToken Address of the TEACH token contract
     * @param _proposalThreshold Voting power needed to create a proposal
     * @param _minVotingPeriod Minimum voting period in seconds
     * @param _maxVotingPeriod Maximum voting period in seconds
     * @param _quorumThreshold Quorum percentage (e.g., 4% = 400)
     * @param _executionDelay Time delay before execution in seconds
     * @param _executionPeriod Execution time window in seconds
     */
    constructor(
        address _teachToken,
        uint256 _proposalThreshold,
        uint256 _minVotingPeriod,
        uint256 _maxVotingPeriod,
        uint256 _quorumThreshold,
        uint256 _executionDelay,
        uint256 _executionPeriod
    ) Ownable(msg.sender) {
        require(_teachToken != address(0), "TeacherGovernance: zero token address");
        require(_quorumThreshold <= 5000, "TeacherGovernance: quorum too high");
        require(_minVotingPeriod <= _maxVotingPeriod, "TeacherGovernance: invalid voting periods");
        
        teachToken = IERC20(_teachToken);
        proposalThreshold = _proposalThreshold;
        minVotingPeriod = _minVotingPeriod;
        maxVotingPeriod = _maxVotingPeriod;
        quorumThreshold = _quorumThreshold;
        executionDelay = _executionDelay;
        executionPeriod = _executionPeriod;
        emergencyPeriod = 24; // 24 hours emergency period by default
        requiredGuardians = 3; // Require 3 guardians to cancel a proposal
        allowedTokens[_teachToken] = true; // Allow TEACH token by default
    }
    
    /**
     * @dev Creates a new governance proposal
     * @param _targets Contract addresses to call
     * @param _signatures Function signatures to call
     * @param _calldatas Calldata for each function call
     * @param _description Description of the proposal
     * @param _votingPeriod Voting period duration in seconds
     * @return uint256 ID of the newly created proposal
     */
    function createProposal(
        address[] memory _targets,
        string[] memory _signatures,
        bytes[] memory _calldatas,
        string memory _description,
        uint256 _votingPeriod
    ) external returns (uint256) {
        require(teachToken.balanceOf(msg.sender) >= proposalThreshold, "TeacherGovernance: below proposal threshold");
        require(_targets.length > 0, "TeacherGovernance: empty proposal");
        require(_targets.length == _signatures.length, "TeacherGovernance: mismatched signatures");
        require(_targets.length == _calldatas.length, "TeacherGovernance: mismatched calldatas");
        require(_votingPeriod >= minVotingPeriod, "TeacherGovernance: voting period too short");
        require(_votingPeriod <= maxVotingPeriod, "TeacherGovernance: voting period too long");
        
        uint256 proposalId = _proposalIdCounter.current();
        _proposalIdCounter.increment();
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.proposer = msg.sender;
        newProposal.description = _description;
        newProposal.targets = _targets;
        newProposal.signatures = _signatures;
        newProposal.calldatas = _calldatas;
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + _votingPeriod;
        
        activeProposalIds.push(proposalId);
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            _targets,
            _signatures,
            _calldatas,
            _description,
            block.timestamp,
            block.timestamp + _votingPeriod
        );
        
        return proposalId;
    }
    
    /**
     * @dev Cast a vote on a proposal
     * @param _proposalId ID of the proposal
     * @param _voteType Vote type (0=Against, 1=For, 2=Abstain)
     * @param _reason Reason for the vote
     */
    function castVote(
        uint256 _proposalId,
        uint8 _voteType,
        string memory _reason
    ) external nonReentrant {
        require(_voteType <= uint8(VoteType.Abstain), "TeacherGovernance: invalid vote type");
        
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.startTime, "TeacherGovernance: voting not started");
        require(block.timestamp <= proposal.endTime, "TeacherGovernance: voting ended");
        require(!proposal.receipts[msg.sender].hasVoted, "TeacherGovernance: already voted");
        
        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "TeacherGovernance: no voting power");
        
        // Update voter receipt
        proposal.receipts[msg.sender] = Receipt({
            hasVoted: true,
            voteType: VoteType(_voteType),
            votes: votes
        });
        
        // Lock voting power for this proposal
        votingPowerLocked[msg.sender] = proposal.endTime;
        
        // Update vote counts
        if (_voteType == uint8(VoteType.Against)) {
            proposal.againstVotes += votes;
        } else if (_voteType == uint8(VoteType.For)) {
            proposal.forVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }
        
        emit VoteCast(msg.sender, _proposalId, _voteType, votes, _reason);
    }
    
    /**
     * @dev Execute a successful proposal
     * @param _proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) external nonReentrant {
        require(state(_proposalId) == ProposalState.Queued, "TeacherGovernance: proposal not queued");
        
        Proposal storage proposal = proposals[_proposalId];
        proposal.executed = true;
        
        // Execute each transaction in the proposal
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, ) = proposal.targets[i].call(proposal.calldatas[i]);
            require(success, "TeacherGovernance: transaction execution reverted");
        }
        
        emit ProposalExecuted(_proposalId);
    }
    
    /**
     * @dev Cancel a proposal (only proposer or if proposer drops below threshold)
     * @param _proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 _proposalId) external {
        ProposalState currentState = state(_proposalId);
        require(
            currentState == ProposalState.Pending || 
            currentState == ProposalState.Active,
            "TeacherGovernance: cannot cancel proposal"
        );
        
        Proposal storage proposal = proposals[_proposalId];
        
        // Only proposer or if proposer drops below threshold can cancel
        require(
            msg.sender == proposal.proposer || 
            teachToken.balanceOf(proposal.proposer) < proposalThreshold,
            "TeacherGovernance: not authorized"
        );
        
        proposal.canceled = true;
        
        // Remove from active proposals
        for (uint256 i = 0; i < activeProposalIds.length; i++) {
            if (activeProposalIds[i] == _proposalId) {
                activeProposalIds[i] = activeProposalIds[activeProposalIds.length - 1];
                activeProposalIds.pop();
                break;
            }
        }
        
        emit ProposalCanceled(_proposalId);
    }
    
    /**
     * @dev Get the current state of a proposal
     * @param _proposalId ID of the proposal
     * @return ProposalState Current state of the proposal
     */
    function state(uint256 _proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[_proposalId];
        
        if (proposal.canceled) {
            return ProposalState.Defeated;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        }
        
        if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        }
        
        // Check if quorum and vote success
        uint256 totalSupply = teachToken.totalSupply();
        uint256 quorumVotes = (totalSupply * quorumThreshold) / 10000;
        
        if (proposal.forVotes + proposal.againstVotes + proposal.abstainVotes < quorumVotes) {
            return ProposalState.Defeated; // Did not reach quorum
        }
        
        if (proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated; // More against votes than for votes
        }
        
        if (block.timestamp <= proposal.endTime + executionDelay) {
            return ProposalState.Succeeded; // Waiting for execution delay
        }
        
        if (block.timestamp <= proposal.endTime + executionDelay + executionPeriod) {
            return ProposalState.Queued; // Ready for execution
        }
        
        return ProposalState.Expired; // Execution period passed
    }
    
    /**
     * @dev Get vote details for a specific voter on a proposal
     * @param _proposalId ID of the proposal
     * @param _voter Address of the voter
     * @return hasVoted Whether the voter has voted
     * @return voteType Type of vote cast
     * @return votes Number of votes cast
     */
    function getReceipt(uint256 _proposalId, address _voter) external view returns (
        bool hasVoted,
        VoteType voteType,
        uint256 votes
    ) {
        Receipt storage receipt = proposals[_proposalId].receipts[_voter];
        return (receipt.hasVoted, receipt.voteType, receipt.votes);
    }
    
    /**
     * @dev Get counts of votes for a specific proposal
     * @param _proposalId ID of the proposal
     * @return againstVotes Number of against votes
     * @return forVotes Number of for votes
     * @return abstainVotes Number of abstain votes
     */
    function getProposalVotes(uint256 _proposalId) external view returns (
        uint256 againstVotes,
        uint256 forVotes,
        uint256 abstainVotes
    ) {
        Proposal storage proposal = proposals[_proposalId];
        return (proposal.againstVotes, proposal.forVotes, proposal.abstainVotes);
    }

    /**
    * @dev Sets the timelock delay for parameter changes
    * @param _newDelay New delay in seconds
     */
    function setParameterChangeDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay <= 30 days, "TeacherGovernance: delay too long");

        emit TimelockDelayUpdated(parameterChangeDelay, _newDelay);
        parameterChangeDelay = _newDelay;
    }
    
    /**
     * @dev Updates governance parameters
     * @param _proposalThreshold New proposal threshold
     * @param _minVotingPeriod New minimum voting period
     * @param _maxVotingPeriod New maximum voting period
     * @param _quorumThreshold New quorum threshold
     * @param _executionDelay New execution delay
     * @param _executionPeriod New execution period
     */
    function updateGovernanceParameters(
        uint256 _proposalThreshold,
        uint256 _minVotingPeriod,
        uint256 _maxVotingPeriod,
        uint256 _quorumThreshold,
        uint256 _executionDelay,
        uint256 _executionPeriod
    ) external onlyOwner {
        require(_minVotingPeriod <= _maxVotingPeriod, "TeacherGovernance: invalid voting periods");
        require(_quorumThreshold <= 5000, "TeacherGovernance: quorum too high");
        
        proposalThreshold = _proposalThreshold;
        minVotingPeriod = _minVotingPeriod;
        maxVotingPeriod = _maxVotingPeriod;
        quorumThreshold = _quorumThreshold;
        executionDelay = _executionDelay;
        executionPeriod = _executionPeriod;
        
        emit GovernanceParametersUpdated(
            _proposalThreshold,
            _minVotingPeriod,
            _maxVotingPeriod,
            _quorumThreshold,
            _executionDelay,
            _executionPeriod
        );
    }
    
    /**
     * @dev Get proposal details
     * @param _proposalId ID of the proposal
     * @return proposer Address of the proposer
     * @return description Description of the proposal
     * @return startTime Start time of the voting period
     * @return endTime End time of the voting period
     * @return currentState Current state of the proposal
     */
    function getProposalDetails(uint256 _proposalId) external view returns (
        address proposer,
        string memory description,
        uint256 startTime,
        uint256 endTime,
        ProposalState currentState
    ) {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.proposer,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            state(_proposalId)
        );
    }
    
    /**
     * @dev Get all active proposal IDs
     * @return uint256[] Array of active proposal IDs
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        return activeProposalIds;
    }

    /**
    * @dev Schedules a governance parameter change with timelock
    * @param _proposalThreshold New proposal threshold
    * @param _minVotingPeriod New minimum voting period
    * @param _maxVotingPeriod New maximum voting period
    * @param _quorumThreshold New quorum threshold
    * @param _executionDelay New execution delay
    * @param _executionPeriod New execution period
    */
    function scheduleParameterChange(
        uint256 _proposalThreshold,
        uint256 _minVotingPeriod,
        uint256 _maxVotingPeriod,
        uint256 _quorumThreshold,
        uint256 _executionDelay,
        uint256 _executionPeriod
    ) external onlyOwner {
        require(_minVotingPeriod <= _maxVotingPeriod, "TeacherGovernance: invalid voting periods");
        require(_quorumThreshold <= 5000, "TeacherGovernance: quorum too high");
        require(!pendingChange.isPending, "TeacherGovernance: change already pending");

        // Schedule the change
        pendingChange = PendingParameterChange({
            proposalThreshold: _proposalThreshold,
            minVotingPeriod: _minVotingPeriod,
            maxVotingPeriod: _maxVotingPeriod,
            quorumThreshold: _quorumThreshold,
            executionDelay: _executionDelay,
            executionPeriod: _executionPeriod,
            scheduledTime: block.timestamp,
            isPending: true
        });

        emit ParameterChangeScheduled(
            _proposalThreshold,
            _minVotingPeriod,
            _maxVotingPeriod,
            _quorumThreshold,
            _executionDelay,
            _executionPeriod,
            block.timestamp
        );
    }

    /**
    * @dev Executes a scheduled parameter change after timelock delay
    */
    function executeParameterChange() external {
        require(pendingChange.isPending, "TeacherGovernance: no pending change");
        require(
            block.timestamp >= pendingChange.scheduledTime + parameterChangeDelay,
            "TeacherGovernance: timelock not expired"
        );

        // Update the parameters
        proposalThreshold = pendingChange.proposalThreshold;
        minVotingPeriod = pendingChange.minVotingPeriod;
        maxVotingPeriod = pendingChange.maxVotingPeriod;
        quorumThreshold = pendingChange.quorumThreshold;
        executionDelay = pendingChange.executionDelay;
        executionPeriod = pendingChange.executionPeriod;

        // Clear the pending change
        pendingChange.isPending = false;

        emit GovernanceParametersUpdated(
            proposalThreshold,
            minVotingPeriod,
            maxVotingPeriod,
            quorumThreshold,
            executionDelay,
            executionPeriod
        );

        emit ParameterChangeExecuted();
    }

    /**
    * @dev Cancels a scheduled parameter change
    */
    function cancelParameterChange() external onlyOwner {
        require(pendingChange.isPending, "TeacherGovernance: no pending change");

        // Clear the pending change
        pendingChange.isPending = false;

        emit ParameterChangeCancelled();
    }

    // Replace your existing updateGovernanceParameters function with this:
    /**
    * @dev Schedules a governance parameter update (replaces immediate update)
    */
    function updateGovernanceParameters(
        uint256 _proposalThreshold,
        uint256 _minVotingPeriod,
        uint256 _maxVotingPeriod,
        uint256 _quorumThreshold,
        uint256 _executionDelay,
        uint256 _executionPeriod
    ) external onlyOwner {
        // Simply call the schedule function
        scheduleParameterChange(
            _proposalThreshold,
            _minVotingPeriod,
            _maxVotingPeriod,
            _quorumThreshold,
            _executionDelay,
            _executionPeriod
        );
    }

    /**
    * @dev Sets the staking contract for calculating weighted votes
    * @param _stakingContract Address of the staking contract
    * @param _maxStakingMultiplier Maximum multiplier for long-term staking (scaled by 100)
    * @param _maxStakingPeriod Maximum staking period for weight calculation in days
    */
    function setStakingContract(
        address _stakingContract,
        uint16 _maxStakingMultiplier,
        uint16 _maxStakingPeriod
    ) external onlyOwner {
        require(_stakingContract != address(0), "TeacherGovernance: zero staking address");
        require(_maxStakingMultiplier >= 100, "TeacherGovernance: multiplier must be >= 100");
        require(_maxStakingPeriod > 0, "TeacherGovernance: period must be > 0");

        stakingContract = ITokenStaking(_stakingContract);
        maxStakingMultiplier = _maxStakingMultiplier;
        maxStakingPeriod = _maxStakingPeriod;
        stakingWeightEnabled = true;
    }

    /**
    * @dev Calculates the voting power for an address, considering staking weight if enabled
    * @param _voter Address to calculate voting power for
    * @return power The weighted voting power
     */
    function getVotingPower(address _voter) public view returns (uint256 power) {
        uint256 tokenBalance = teachToken.balanceOf(_voter);
    
        if (!stakingWeightEnabled || address(stakingContract) == address(0)) {
            return tokenBalance; // Basic voting power is just token balance
        }
    
        // Add basic token balance
        power = tokenBalance;
    
        // Add weighted staking power
        uint256 poolCount = stakingContract.getPoolCount();
        for (uint256 poolId = 0; poolId < poolCount; poolId++) {
            (
                uint256 stakedAmount,
                uint256 startTime,
                ,,,, // Skip other return values we don't need
            ) = stakingContract.getUserStake(poolId, _voter);
        
            if (stakedAmount > 0) {
                // Calculate staking duration in days
                uint256 stakingDays = (block.timestamp - startTime) / 1 days;
            
                // Calculate weight multiplier (linear between 1x and maxStakingMultiplier)
                uint256 multiplier = 100; // Base multiplier 1.0
                if (stakingDays > 0) {
                    uint256 additionalMultiplier = stakingDays >= maxStakingPeriod ? 
                        (maxStakingMultiplier - 100) : 
                        ((maxStakingMultiplier - 100) * stakingDays) / maxStakingPeriod;
                    
                    multiplier += additionalMultiplier;
                }
            
                // Apply multiplier to staked amount
                uint256 weightedStakedAmount = (stakedAmount * multiplier) / 100;
                power += weightedStakedAmount - stakedAmount; // Add only the extra voting power
            }
        }
    
        return power;
    }
   

	
	// Add these events
	event TokenDepositedToTreasury(address token, address depositor, uint256 amount);
	event TreasuryWithdrawal(address token, address recipient, uint256 amount);
	event TokenAllowanceChanged(address token, bool allowed);
	
	/**
	* @dev Allow or disallow a token for treasury operations
	* @param _token Address of the token
	* @param _allowed Whether the token is allowed
	*/
	function setTokenAllowance(address _token, bool _allowed) external onlyOwner {
		allowedTokens[_token] = _allowed;
		emit TokenAllowanceChanged(_token, _allowed);
	}
	
	/**
	* @dev Deposit tokens to the treasury
	* @param _token Address of the token
	* @param _amount Amount to deposit
	*/
	function depositToTreasury(address _token, uint256 _amount) external nonReentrant {
		require(_amount > 0, "TeacherGovernance: zero amount");
		require(allowedTokens[_token], "TeacherGovernance: token not allowed");
		
		IERC20 token = IERC20(_token);
		require(token.transferFrom(msg.sender, address(this), _amount), "TeacherGovernance: transfer failed");
		
		if (_token == address(teachToken)) {
			treasuryBalance += uint96(_amount);
		}
		
		emit TokenDepositedToTreasury(_token, msg.sender, _amount);
	}
	
	/**
	* @dev Withdraw tokens from treasury (only via successful proposal)
	* @param _token Address of the token
	* @param _recipient Recipient address
	* @param _amount Amount to withdraw
	*/
	function withdrawFromTreasury(
		address _token,
		address _recipient,
		uint256 _amount
	) external nonReentrant {
		// Only executable through a proposal
		require(msg.sender == address(this), "TeacherGovernance: only via proposal");
		require(_amount > 0, "TeacherGovernance: zero amount");
		require(_recipient != address(0), "TeacherGovernance: zero recipient");
		require(allowedTokens[_token], "TeacherGovernance: token not allowed");
		
		IERC20 token = IERC20(_token);
		if (_token == address(teachToken)) {
			require(_amount <= treasuryBalance, "TeacherGovernance: insufficient treasury");
			treasuryBalance -= uint96(_amount);
		}
		
		require(token.transfer(_recipient, _amount), "TeacherGovernance: transfer failed");
		
		emit TreasuryWithdrawal(_token, _recipient, _amount);
	}
	
	/**
	* @dev Get treasury balance of a specific token
	* @param _token Address of the token
	* @return balance Token balance in treasury
	*/
	function getTreasuryBalance(address _token) external view returns (uint256 balance) {
		if (_token == address(teachToken)) {
			return treasuryBalance;
		} else {
			return IERC20(_token).balanceOf(address(this));
		}
	}  
	/**
	* @dev Add a new guardian address
	* @param _guardian Address to add as guardian
	*/
	function addGuardian(address _guardian) external onlyOwner {
		require(_guardian != address(0), "TeacherGovernance: zero guardian address");
		require(!guardians[_guardian], "TeacherGovernance: already guardian");
		
		guardians[_guardian] = true;
		emit GuardianAdded(_guardian);
	}
	
	/**
	* @dev Remove a guardian address
	* @param _guardian Address to remove as guardian
	*/
	function removeGuardian(address _guardian) external onlyOwner {
		require(guardians[_guardian], "TeacherGovernance: not a guardian");
		
		guardians[_guardian] = false;
		emit GuardianRemoved(_guardian);
	}
	
	/**
	* @dev Set emergency governance parameters
	* @param _emergencyPeriod Time in hours to allow emergency cancellation
	* @param _requiredGuardians Minimum guardians required to cancel proposal
	*/
	function setEmergencyParameters(uint16 _emergencyPeriod, uint16 _requiredGuardians) external onlyOwner {
		emergencyPeriod = _emergencyPeriod;
		requiredGuardians = _requiredGuardians;
	}
	
	/**
	* @dev Vote to cancel a potentially malicious proposal
	* @param _proposalId ID of the proposal
	* @param _reason Reason for cancellation
	*/
	function voteToCancel(uint256 _proposalId, string calldata _reason) external {
		require(guardians[msg.sender], "TeacherGovernance: not a guardian");
		require(!guardianCancellations[_proposalId][msg.sender], "TeacherGovernance: already voted");
		
		ProposalState currentState = state(_proposalId);
		require(
			currentState == ProposalState.Pending || 
			currentState == ProposalState.Active,
			"TeacherGovernance: cannot cancel proposal"
		);
		
		Proposal storage proposal = proposals[_proposalId];
		
		// Check if within emergency period
		require(
			block.timestamp <= proposal.startTime + (emergencyPeriod * 1 hours),
			"TeacherGovernance: emergency period expired"
		);
		
		// Record guardian's vote
		guardianCancellations[_proposalId][msg.sender] = true;
		cancellationVotes[_proposalId] += 1;
		
		emit ProposalCancellationVoted(_proposalId, msg.sender);
		
		// If enough votes, cancel the proposal
		if (cancellationVotes[_proposalId] >= requiredGuardians) {
			proposal.canceled = true;
			
			// Remove from active proposals
			for (uint256 i = 0; i < activeProposalIds.length; i++) {
				if (activeProposalIds[i] == _proposalId) {
					activeProposalIds[i] = activeProposalIds[activeProposalIds.length - 1];
					activeProposalIds.pop();
					break;
				}
			}
			
			emit ProposalEmergencyCancelled(_proposalId, _reason);
		}
	}
}