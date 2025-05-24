// MockEmergencyManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockEmergencyManager
 * @dev Mock implementation of IEmergencyManager for testing
 */
contract MockEmergencyManager {
    // Emergency state
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }
    EmergencyState public emergencyState = EmergencyState.NORMAL;

    // Track emergency withdrawals
    mapping(address => bool) public emergencyWithdrawalsProcessed;
    mapping(address => uint256) public withdrawalAmounts;

    // Emergency recovery functionality
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;
    bool public inEmergencyRecovery;
    uint256 public recoveryInitiatedTimestamp;
    uint256 public recoveryTimeout;
    uint8 public recoveryApprovalsCount;
    
    // Events
    event EmergencyRecoveryInitiated(address indexed initiator, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed completer);
    event RecoveryApprovalsUpdated(uint256 required);

    /**
     * @dev Constructor sets default values
     */
    constructor() {
        requiredRecoveryApprovals = 3; // Default value
        recoveryTimeout = 24 hours;
        recoveryApprovalsCount = 0;
    }

    /**
     * @dev Set the emergency state
     */
    function setEmergencyState(EmergencyState _state) external {
        emergencyState = _state;
    }

    /**
     * @dev Get the current emergency state
     */
    function getEmergencyState() external view returns (EmergencyState) {
        return emergencyState;
    }

    /**
     * @dev Check if withdrawal is processed
     */
    function isEmergencyWithdrawalProcessed(address _user) external view returns (bool) {
        return emergencyWithdrawalsProcessed[_user];
    }

    /**
     * @dev Process emergency withdrawal
     */
    function processEmergencyWithdrawal(address _user, uint256 _amount) external {
        emergencyWithdrawalsProcessed[_user] = true;
        withdrawalAmounts[_user] = _amount;
    }

    /**
     * @dev Set the required number of recovery approvals
     */
    function setRequiredRecoveryApprovals(uint256 _required) external {
        require(_required > 0, "MockEmergencyManager: invalid approval count");
        requiredRecoveryApprovals = _required;
        emit RecoveryApprovalsUpdated(_required);
    }

    /**
     * @dev Set recovery timeout
     */
    function setRecoveryTimeout(uint256 _timeout) external {
        require(_timeout >= 1 hours, "MockEmergencyManager: timeout too short");
        require(_timeout <= 7 days, "MockEmergencyManager: timeout too long");
        recoveryTimeout = _timeout;
    }

    /**
     * @dev Reset recovery state (for testing)
     */
    function resetRecoveryState() external {
        inEmergencyRecovery = false;
        recoveryInitiatedTimestamp = 0;
        // Reset all approvals - simplified for testing
    }

    
    /**
     * @dev Initiate emergency recovery
     */
    function initiateEmergencyRecovery() external {
        inEmergencyRecovery = true;
        recoveryInitiatedTimestamp = block.timestamp;
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    /**
     * @dev Approve recovery (simplified for testing)
     */
    function approveRecovery() external {
        require(inEmergencyRecovery, "MockEmergencyManager: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "MockEmergencyManager: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;
        recoveryApprovalsCount ++;

        if (recoveryApprovalsCount  >= requiredRecoveryApprovals) {
            inEmergencyRecovery = false;
            recoveryInitiatedTimestamp = 0;
            emit EmergencyRecoveryCompleted(msg.sender);
        }
    }

    /**
     * @dev Count recovery approvals (simplified for testing)
     */
    function _countRecoveryApprovals() internal view returns (uint256) {
        // For testing purposes, we'll track a simple counter
        // In real implementation this would check role members
        if (block.timestamp > recoveryInitiatedTimestamp + recoveryTimeout) {
            return 0; // Return 0 if recovery has timed out
        }

        // Simple mock implementation - just check if specific addresses approved
        uint256 count = 0;
        // This is a simplified version for testing
        // You might want to add specific test addresses here
        return count;
    }

    /**
     * @dev Get recovery approvals count (for testing)
     */
    function getRecoveryApprovalsCount() external view returns (uint256) {
        return recoveryApprovalsCount;
    }

    /**
     * @dev Check if user has approved recovery
     */
    function hasApprovedRecovery(address _user) external view returns (bool) {
        return emergencyRecoveryApprovals[_user];
    }

    
    /**
     * @dev Check if in emergency recovery mode
     */
    function isInEmergencyRecovery() external view returns (bool) {
        return inEmergencyRecovery;
    }
}