// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "./Libraries/Constants.sol";
/**
 * @title IPlatformGovernance
 * @dev Interface for the PlatformGovernance contract
 */
interface IPlatformGovernance {

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
    
    // Events related to governance
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
    event SystemEmergencyTriggered(address indexed triggeredBy, string reason);
    
    /**
     * @dev Update voting power for an address
     * @param _voter Address to update voting power for
     */
    function updateVotingPower(address _voter) external;

    /**
     * @dev Trigger system-wide emergency mode
     * @param _reason Reason for the emergency
     */
    function triggerSystemEmergency(string calldata _reason) external;

    /**
     * @dev Create a proposal
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
    ) external returns (uint256);

    /**
     * @dev Cast a vote on a proposal
     * @param _proposalId ID of the proposal
     * @param _voteType Vote type (0=Against, 1=For, 2=Abstain)
     * @param _reason Reason for the vote
     */
    function castVote(uint256 _proposalId, uint8 _voteType, string memory _reason) external;

    /**
     * @dev Execute a successful proposal
     * @param _proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) external;

    /**
     * @dev Cancel a proposal (only proposer or if proposer drops below threshold)
     * @param _proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 _proposalId) external;
    
    /**
     * @dev Get proposal state
     * @param _proposalId ID of the proposal
     * @return ProposalState Current state of the proposal
     */
    function state(uint256 _proposalId) external view returns (ProposalState); // Using uint8 for enum

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
    );

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
    );

    /**
     * @dev Sets the timelock delay for parameter changes
     * @param _newDelay New delay in seconds
     */
    function setParameterChangeDelay(uint256 _newDelay) external;

    /**
     * @dev Updates governance parameters
     * @param _proposalThreshold New proposal threshold
     * @param _minVotingPeriod New minimum voting period
     * @param _maxVotingPeriod New maximum voting period
     * @param _quorumThreshold New quorum threshold
     * @param _executionDelay New execution delay
     * @param _executionPeriod New execution period
     */
    function updateGovernanceParameters(uint256 _proposalThreshold, uint256 _minVotingPeriod, uint256 _maxVotingPeriod,
        uint256 _quorumThreshold, uint256 _executionDelay, uint256 _executionPeriod) external;

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
    );

    /**
    * @dev Get all active proposal IDs
     * @return uint256[] Array of active proposal IDs
     */
    function getActiveProposals() external view returns (uint256[] memory);

    /**
    * @dev Schedules a governance parameter change with timelock
    * @param _proposalThreshold New proposal threshold
    * @param _minVotingPeriod New minimum voting period
    * @param _maxVotingPeriod New maximum voting period
    * @param _quorumThreshold New quorum threshold
    * @param _executionDelay New execution delay
    * @param _executionPeriod New execution period
    */
    function scheduleParameterChange(uint256 _proposalThreshold, uint256 _minVotingPeriod, uint256 _maxVotingPeriod,
        uint256 _quorumThreshold, uint256 _executionDelay, uint256 _executionPeriod) external;

    /**
    * @dev Executes a scheduled parameter change after timelock delay
    */
    function executeParameterChange() external;

    /**
    * @dev Cancels a scheduled parameter change
    */
    function cancelParameterChange() external;

    // Replace your existing updateGovernanceParameters function with this:
    /**
    * @dev Schedules a governance parameter update (replaces immediate update)
    */
    function updateGovernanceParameters(uint256 _proposalThreshold, uint256 _minVotingPeriod, uint256 _maxVotingPeriod,
        uint256 _quorumThreshold, uint256 _executionDelay, uint256 _executionPeriod) external;

    /**
   * @dev Sets the staking contract for calculating weighted votes
    * @param _stakingContract Address of the staking contract
    * @param _maxStakingMultiplier Maximum multiplier for long-term staking (scaled by 100)
    * @param _maxStakingPeriod Maximum staking period for weight calculation in days
    */
    function setStakingContract(address _stakingContract, uint16 _maxStakingMultiplier, uint16 _maxStakingPeriod) external;

    /**
   * @dev Calculates the voting power for an address, considering staking weight if enabled
    * @param _voter Address to calculate voting power for
    * @return power The weighted voting power
     */
    function getVotingPower(address _voter) public view returns (uint256 power);

    /**
	* @dev Allow or disallow a token for treasury operations
	* @param _token Address of the token
	* @param _allowed Whether the token is allowed
	*/
    function setTokenAllowance(address _token, bool _allowed) external;

    /**
	* @dev Deposit tokens to the treasury
	* @param _token Address of the token
	* @param _amount Amount to deposit
	*/
    function depositToTreasury(address _token, uint256 _amount) external;

    /**
	* @dev Withdraw tokens from treasury (only via successful proposal)
	* @param _token Address of the token
	* @param _recipient Recipient address
	* @param _amount Amount to withdraw
	*/
    function withdrawFromTreasury(address _token, address _recipient, uint256 _amount) external;

    /**
	* @dev Get treasury balance of a specific token
	* @param _token Address of the token
	* @return balance Token balance in treasury
	*/
    function getTreasuryBalance(address _token) external view returns (uint256 balance);

    /**
	* @dev Add a new guardian address
	* @param _guardian Address to add as guardian
	*/
    function addGuardian(address _guardian) external;

    /**
	* @dev Remove a guardian address
	* @param _guardian Address to remove as guardian
	*/
    function removeGuardian(address _guardian) external;

    /**
	* @dev Set emergency governance parameters
	* @param _emergencyPeriod Time in hours to allow emergency cancellation
	* @param _requiredGuardians Minimum guardians required to cancel proposal
	*/
    function setEmergencyParameters(uint16 _emergencyPeriod, uint16 _requiredGuardians) external;

    /**
	* @dev Vote to cancel a potentially malicious proposal
	* @param _proposalId ID of the proposal
	* @param _reason Reason for cancellation
	*/
    function voteToCancel(uint256 _proposalId, string calldata _reason) external;
    
    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external;

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external;

    /**
     * @dev Triggers system-wide emergency mode
     * @param _reason Reason for the emergency
     */
    function triggerSystemEmergency(string memory _reason) external;

    // Add emergency recovery for governance operations
    function setRecoveryRequirements(uint16 _requiredGuardians, uint16 _emergencyPeriod) external;

    // Add proposal cancellation by governor consensus
    function cancelProposalByGovernance(uint256 _proposalId, string calldata _reason) external;

    // Update cache periodically
    function updateAddressCache() public;
}