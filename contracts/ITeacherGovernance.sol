// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ITeacherGovernance
 * @dev Interface for the TeacherGovernance contract
 */
interface ITeacherGovernance {
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
}