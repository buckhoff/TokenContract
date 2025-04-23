// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "./Libraries/Constants.sol";
/**
 * @title IPlatformGovernance
 * @dev Interface for the PlatformGovernance contract
 */
interface IPlatformGovernance {

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
     * @dev Get the voting power for an address
     * @param _voter Address to get voting power for
     * @return power The weighted voting power
     */
    function getVotingPower(address _voter) external view returns (uint256 power);

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
     * @dev Get proposal state
     * @param _proposalId ID of the proposal
     * @return ProposalState Current state of the proposal
     */
    function state(uint256 _proposalId) external view returns (uint8); // Using uint8 for enum

    /**
     * @dev Execute a successful proposal
     * @param _proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) external;
}