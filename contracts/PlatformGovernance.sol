// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import "./Interfaces/IPlatformStaking.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Interfaces/IPlatformGovernance.sol";

/**
 * @title PlatformGovernance
 * @dev Contract for decentralized governance of the TeacherSupport platform
 */
contract PlatformGovernance is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    RegistryAwareUpgradeable,
    IPlatformGovernance
{

    ERC20Upgradeable internal token;

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
    
    // Staking contract reference
    IPlatformStaking public stakingContract;
    
    // Proposal counter
    uint256 private _proposalIdCounter;
    
    // Voting power threshold to create a proposal (in platform tokens)
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
    
    // Mapping from proposal ID to Proposal
    mapping(uint256 => Proposal) public proposals;
    
    // Store active proposal IDs for iteration
    uint256[] public activeProposalIds;
    
    // Mapping to track if an address token voting power is locked
    mapping(address => uint256) public votingPowerLocked;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;

    bool internal paused;
    
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
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event RecoveryRequirementsUpdated(uint16 requiredGuardians, uint16 emergencyPeriod);
    event ProposalCanceledByGovernance(uint256 indexed proposalId, address indexed governor, string reason);

    
    bool public stakingWeightEnabled;
    uint16 public maxStakingMultiplier; // multiplier scaled by 100 (e.g., 200 = 2x)
    uint16 public maxStakingPeriod; // in days

    modifier whenContractNotPaused(){
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "PlatformGovernance: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                require(!paused, "PlatformGovernance: contract is paused");
            }
            require(registry.isRegistryOffline() = false, "PlatformGovernance: registry Offline");
        } else {
            require(!paused, "PlatformGovernance: contract is paused");
        }
        require(!paused, "PlatformGovernance: contract is paused");
        _;
    }
    
    modifier onlyAdmin() {
        require(hasRole(Constants.ADMIN_ROLE, msg.sender), "PlatformGovernance: caller is not admin role");
        _;
    }

    modifier onlyEmergency() {
        require(hasRole(Constants.EMERGENCY_ROLE, msg.sender), "PlatformGovernance: caller is not emergency role");
        _;
    }
    
    /**
     * @dev Constructor
     */
    constructor(){
        _disableInitializers();
    }
    
    /**
     * @dev Initializer sets the token address and governance parameters
     * @param _token Address of the platform token contract
     * @param _proposalThreshold Voting power needed to create a proposal
     * @param _minVotingPeriod Minimum voting period in seconds
     * @param _maxVotingPeriod Maximum voting period in seconds
     * @param _quorumThreshold Quorum percentage (e.g., 4% = 400)
     * @param _executionDelay Time delay before execution in seconds
     * @param _executionPeriod Execution time window in seconds
     */
    function initialize(
        address _token,
        uint256 _proposalThreshold,
        uint256 _minVotingPeriod,
        uint256 _maxVotingPeriod,
        uint256 _quorumThreshold,
        uint256 _executionDelay,
        uint256 _executionPeriod
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        require(_token != address(0), "PlatformGovernance: zero token address");
        require(_quorumThreshold <= 5000, "PlatformGovernance: quorum too high");
        require(_minVotingPeriod <= _maxVotingPeriod, "PlatformGovernance: invalid voting periods");
        
        token = ERC20Upgradeable(_token);
        proposalThreshold = _proposalThreshold;
        minVotingPeriod = _minVotingPeriod;
        maxVotingPeriod = _maxVotingPeriod;
        quorumThreshold = _quorumThreshold;
        executionDelay = _executionDelay;
        executionPeriod = _executionPeriod;
        emergencyPeriod = 24; // 24 hours emergency period by default
        requiredGuardians = 3; // Require 3 guardians to cancel a proposal
        allowedTokens[_token] = true; // Allow platform token by default
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
    function createProposal(address[] memory _targets, string[] memory _signatures, bytes[] memory _calldatas, 
        string memory _description, uint256 _votingPeriod) external whenContractNotPaused returns (uint256){
        
        // Use governance token from registry if available
        ERC20Upgradeable governanceToken = token;
        if (address(registry) != address(0) && registry.isContractActive(Constants.TOKEN_NAME)) {
            governanceToken =ERC20Upgradeable(registry.getContractAddress(Constants.TOKEN_NAME));
        }
        
        require(governanceToken.balanceOf(msg.sender) >= proposalThreshold, "PlatformGovernance: below proposal threshold");
        require(_targets.length > 0, "PlatformGovernance: empty proposal");
        require(_targets.length == _signatures.length, "PlatformGovernance: mismatched signatures");
        require(_targets.length == _calldatas.length, "PlatformGovernance: mismatched calldatas");
        require(_votingPeriod >= minVotingPeriod, "PlatformGovernance: voting period too short");
        require(_votingPeriod <= maxVotingPeriod, "PlatformGovernance: voting period too long");

        // Check if any system contracts are targets
        for (uint256 i = 0; i < _targets.length; i++) {
            address target = _targets[i];

            // Check if target is a core contract
            if (address(registry) != address(0)) {
                bytes32[] memory contractNames = new bytes32[](6);
                contractNames[0] = Constants.TOKEN_NAME;
                contractNames[1] = Constants.STABILITY_FUND_NAME;
                contractNames[2] = Constants.STAKING_NAME;
                contractNames[3] = Constants.MARKETPLACE_NAME;
                contractNames[4] = Constants.CROWDSALE_NAME;
                contractNames[5] = Constants.PLATFORM_REWARD_NAME;

                for (uint256 j = 0; j < contractNames.length; j++) {
                    if (registry.isContractActive(contractNames[j])) {
                        if (target == registry.getContractAddress(contractNames[j])) {
                            // Target is a system contract, require additional permissions
                            require(hasRole(Constants.ADMIN_ROLE, msg.sender), "PlatformGovernance: not authorized for system contracts");
                        }
                    }
                }
            }
        }
        
        uint256 proposalId = _proposalIdCounter;
        _proposalIdCounter++;
        
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
    function castVote(uint256 _proposalId, uint8 _voteType, string memory _reason) external nonReentrant {
        require(_voteType <= uint8(VoteType.Abstain), "PlatformGovernance: invalid vote type");
        require(_proposalId < _proposalIdCounter, "PlatformGovernance: proposal doesn't exist");
        require(bytes(_reason).length <= 200, "PlatformGovernance: reason too long");
        
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.startTime, "PlatformGovernance: voting not started");
        require(block.timestamp <= proposal.endTime, "PlatformGovernance: voting ended");
        require(!proposal.receipts[msg.sender].hasVoted, "PlatformGovernance: already voted");
        
        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "PlatformGovernance: no voting power");
        
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
        require(state(_proposalId) == ProposalState.Queued, "PlatformGovernance: proposal not queued");
        
        Proposal storage proposal = proposals[_proposalId];
        proposal.executed = true;
        
        // Execute each transaction in the proposal
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, ) = proposal.targets[i].call(proposal.calldatas[i]);
            require(success, "PlatformGovernance: transaction execution reverted");
        }
        
        emit ProposalExecuted(_proposalId);
    }
    
    /**
     * @dev Cancel a proposal (only proposer or if proposer drops below threshold)
     * @param _proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 _proposalId) external nonReentrant {
        ProposalState currentState = state(_proposalId);
        require(
            currentState == ProposalState.Pending || 
            currentState == ProposalState.Active,
            "PlatformGovernance: cannot cancel proposal"
        );
        
        Proposal storage proposal = proposals[_proposalId];
        
        // Only proposer or if proposer drops below threshold can cancel
        require(
            msg.sender == proposal.proposer || 
            token.balanceOf(proposal.proposer) < proposalThreshold,
            "PlatformGovernance: not authorized"
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
        uint256 totalSupply = token.totalSupply();
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
    function setParameterChangeDelay(uint256 _newDelay) external onlyAdmin {
        require(_newDelay <= 30 days, "PlatformGovernance: delay too long");

        emit TimelockDelayUpdated(parameterChangeDelay, _newDelay);
        parameterChangeDelay = _newDelay;
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
    * @dev Executes a scheduled parameter change after timelock delay
    */
    function executeParameterChange() external {
        require(pendingChange.isPending, "PlatformGovernance: no pending change");
        require(
            block.timestamp >= pendingChange.scheduledTime + parameterChangeDelay,
            "PlatformGovernance: timelock not expired"
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
    function cancelParameterChange() external onlyAdmin {
        require(pendingChange.isPending, "PlatformGovernance: no pending change");

        // Clear the pending change
        pendingChange.isPending = false;

        emit ParameterChangeCancelled();
    }

   
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
    ) external onlyAdmin {
        require(_minVotingPeriod <= _maxVotingPeriod, "PlatformGovernance: invalid voting periods");
        require(_quorumThreshold <= 5000, "PlatformGovernance: quorum too high");
        require(!pendingChange.isPending, "PlatformGovernance: change already pending");

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
    * @dev Sets the staking contract for calculating weighted votes
    * @param _stakingContract Address of the staking contract
    * @param _maxStakingMultiplier Maximum multiplier for long-term staking (scaled by 100)
    * @param _maxStakingPeriod Maximum staking period for weight calculation in days
    */
    function setStakingContract(
        address _stakingContract,
        uint16 _maxStakingMultiplier,
        uint16 _maxStakingPeriod
    ) external onlyAdmin {
        require(_stakingContract != address(0), "PlatformGovernance: zero staking address");
        require(_maxStakingMultiplier >= 100, "PlatformGovernance: multiplier must be >= 100");
        require(_maxStakingPeriod > 0, "PlatformGovernance: period must be > 0");

        stakingContract = IPlatformStaking(_stakingContract);
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
        uint256 tokenBalance = token.balanceOf(_voter);
    
        if (!stakingWeightEnabled || address(stakingContract) == address(0)) {
            return tokenBalance; // Basic voting power is just token balance
        }
    
        // Add basic token balance
        power = tokenBalance;

        // Check registry first if it's set
        if (address(registry) != address(0) && registry.isContractActive(Constants.STAKING_NAME)) {
            address stakingAddress = registry.getContractAddress(Constants.STAKING_NAME);

            if (stakingAddress != address(0)) {
                try IPlatformStaking(stakingAddress).getPoolCount() returns (uint256 poolCount) {
                    // Add weighted staking power
                    for (uint256 poolId = 0; poolId < poolCount; poolId++) {
                        try IPlatformStaking(stakingAddress).getUserStake(poolId, _voter) returns (
                            uint256 stakedAmount,
                            uint256 startTime,
                            uint256 lastClaimTime,
                            uint256 pendingReward,
                            address secondaryBeneficiary,
                            uint256 userRewardPortion,
                            uint256 secondaryRewardPortion
                        ) {
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
                        } catch {
                            // If call fails, continue with the next pool
                        }
                    }
                } catch {
                    // If getPoolCount fails, just use the token balance
                }
            }
        } else if (address(stakingContract) != address(0)) {
            // Fallback to contract reference if registry lookup fails
            try stakingContract.getPoolCount() returns (uint256 poolCount) {
                // Add weighted staking power (same logic as above)
                for (uint256 poolId = 0; poolId < poolCount; poolId++) {
                    try stakingContract.getUserStake(poolId, _voter) returns (
                        uint256 stakedAmount,
                        uint256 startTime,
                        uint256 lastClaimTime,
                        uint256 pendingReward,
                        address secondaryBeneficiary,
                        uint256 userRewardPortion,
                        uint256 secondaryRewardPortion
                    ) {
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
                    } catch {
                        // If call fails, continue with the next pool
                    }
                }
            } catch {
                // If getPoolCount fails, just use the token balance
            }
        }
    
        return power;
    }
    
	/**
	* @dev Allow or disallow a token for treasury operations
	* @param _token Address of the token
	* @param _allowed Whether the token is allowed
	*/
	function setTokenAllowance(address _token, bool _allowed) external onlyAdmin {
		allowedTokens[_token] = _allowed;
		emit TokenAllowanceChanged(_token, _allowed);
	}
	
	/**
	* @dev Deposit tokens to the treasury
	* @param _token Address of the token
	* @param _amount Amount to deposit
	*/
	function depositToTreasury(address _token, uint256 _amount) external nonReentrant {
		require(_amount > 0, "PlatformGovernance: zero amount");
		require(allowedTokens[_token], "PlatformGovernance: token not allowed");
		
		token = ERC20Upgradeable(_token);
		require(token.transferFrom(msg.sender, address(this), _amount), "PlatformGovernance: transfer failed");
		
		if (_token == address(token)) {
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
	function withdrawFromTreasury(address _token, address _recipient, uint256 _amount) external nonReentrant {
		// Only executable through a proposal
		require(msg.sender == address(this), "PlatformGovernance: only via proposal");
		require(_amount > 0, "PlatformGovernance: zero amount");
		require(_recipient != address(0), "PlatformGovernance: zero recipient");
		require(allowedTokens[_token], "PlatformGovernance: token not allowed");
		
		token = ERC20Upgradeable(_token);
		if (_token == address(token)) {
			require(_amount <= treasuryBalance, "PlatformGovernance: insufficient treasury");
			treasuryBalance -= uint96(_amount);
		}
		
		require(token.transfer(_recipient, _amount), "PlatformGovernance: transfer failed");
		
		emit TreasuryWithdrawal(_token, _recipient, _amount);
	}
	
	/**
	* @dev Get treasury balance of a specific token
	* @param _token Address of the token
	* @return balance Token balance in treasury
	*/
	function getTreasuryBalance(address _token) external view returns (uint256 balance) {
		if (_token == address(token)) {
			return treasuryBalance;
		} else {
			return ERC20Upgradeable(_token).balanceOf(address(this));
		}
	}  
	/**
	* @dev Add a new guardian address
	* @param _guardian Address to add as guardian
	*/
	function addGuardian(address _guardian) external onlyAdmin {
		require(_guardian != address(0), "PlatformGovernance: zero guardian address");
		require(!guardians[_guardian], "PlatformGovernance: already guardian");
		
		guardians[_guardian] = true;
		emit GuardianAdded(_guardian);
	}
	
	/**
	* @dev Remove a guardian address
	* @param _guardian Address to remove as guardian
	*/
	function removeGuardian(address _guardian) external onlyAdmin {
		require(guardians[_guardian], "PlatformGovernance: not a guardian");
		
		guardians[_guardian] = false;
		emit GuardianRemoved(_guardian);
	}
	
	/**
	* @dev Set emergency governance parameters
	* @param _emergencyPeriod Time in hours to allow emergency cancellation
	* @param _requiredGuardians Minimum guardians required to cancel proposal
	*/
	function setEmergencyParameters(uint16 _emergencyPeriod, uint16 _requiredGuardians) external onlyAdmin {
		emergencyPeriod = _emergencyPeriod;
		requiredGuardians = _requiredGuardians;
	}
	
	/**
	* @dev Vote to cancel a potentially malicious proposal
	* @param _proposalId ID of the proposal
	* @param _reason Reason for cancellation
	*/
	function voteToCancel(uint256 _proposalId, string calldata _reason) external {
		require(guardians[msg.sender], "PlatformGovernance: not a guardian");
		require(!guardianCancellations[_proposalId][msg.sender], "PlatformGovernance: already voted");
		
		ProposalState currentState = state(_proposalId);
		require(
			currentState == ProposalState.Pending || 
			currentState == ProposalState.Active,
			"PlatformGovernance: cannot cancel proposal"
		);
		
		Proposal storage proposal = proposals[_proposalId];
		
		// Check if within emergency period
		require(
			block.timestamp <= proposal.startTime + (emergencyPeriod * 1 hours),
			"PlatformGovernance: emergency period expired"
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

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyAdmin {
        _setRegistry(_registry, Constants.TEACHER_GOVERNANCE);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyAdmin {
        require(address(registry) != address(0), "PlatformGovernance: registry not set");

        // Update token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newTeachToken = registry.getContractAddress(Constants.TOKEN_NAME);
            address oldTeachToken = address(token);

            if (newTeachToken != oldTeachToken) {
                token = ERC20Upgradeable(newTeachToken);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldTeachToken, newTeachToken);
            }
        }

        // Update Staking reference
        if (registry.isContractActive(Constants.STAKING_NAME)) {
            address newStaking = registry.getContractAddress(Constants.STAKING_NAME);
            address oldStaking = address(stakingContract);

            if (newStaking != oldStaking) {
                stakingContract = IPlatformStaking(newStaking);
                stakingWeightEnabled = true; // Enable staking weight when staking contract is available
                emit ContractReferenceUpdated(Constants.STAKING_NAME, oldStaking, newStaking);
            }
        }
    }

    // Add emergency recovery for governance operations
    function setRecoveryRequirements(uint16 _requiredGuardians, uint16 _emergencyPeriod) external onlyAdmin {
        requiredGuardians = _requiredGuardians;
        emergencyPeriod = _emergencyPeriod;
        emit RecoveryRequirementsUpdated(_requiredGuardians, _emergencyPeriod);
    }

    // Add proposal cancellation by governor consensus
    function cancelProposalByGovernance(uint256 _proposalId, string calldata _reason) external onlyAdmin {
        ProposalState currentState = state(_proposalId);
        require(
            currentState == ProposalState.Queued ||
            currentState == ProposalState.Succeeded,
            "Governance: cannot cancel proposal"
        );

        Proposal storage proposal = proposals[_proposalId];
        proposal.canceled = true;

        // Remove from active proposals
        for (uint256 i = 0; i < activeProposalIds.length; i++) {
            if (activeProposalIds[i] == _proposalId) {
                activeProposalIds[i] = activeProposalIds[activeProposalIds.length - 1];
                activeProposalIds.pop();
                break;
            }
        }

        emit ProposalCanceledByGovernance(_proposalId, msg.sender, _reason);
    }

    // Update cache periodically
    function updateAddressCache() public {
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    _cachedTokenAddress = tokenAddress;
                }
            } catch {}

            try registry.getContractAddress(Constants.STABILITY_FUND_NAME) returns (address stabilityFund) {
                if (stabilityFund != address(0)) {
                    _cachedStabilityFundAddress = stabilityFund;
                }
            } catch {}

            _lastCacheUpdate = block.timestamp;
        }
    }

    /**
     * @dev Retrieves the address of the token contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getTokenAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0) && !registryOfflineMode) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    // Update cache with successful lookup
                    _cachedTokenAddress = tokenAddress;
                    _lastCacheUpdate = block.timestamp;
                    return tokenAddress;
                }
            } catch {
                // Registry lookup failed, continue to fallbacks
            }
        }

        // Second attempt: Use cached address if available and not too old
        if (_cachedTokenAddress != address(0) && block.timestamp - _lastCacheUpdate < 1 days) {
            return _cachedTokenAddress;
        }

        // Third attempt: Use explicitly set fallback address
        address fallbackAddress = _fallbackAddresses[Constants.TOKEN_NAME];
        if (fallbackAddress != address(0)) {
            return fallbackAddress;
        }

        // Final fallback: Use hardcoded address (if appropriate) or revert
        revert("Token address unavailable through all fallback mechanisms");
    }
}