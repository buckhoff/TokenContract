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
}