// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

/**
 * @title EmergencyManager
 * @dev Manages emergency states and recovery procedures for the crowdsale
 */
contract EmergencyManager is
AccessControlEnumerableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Emergency state tracking
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }
    EmergencyState public emergencyState;

    // Emergency thresholds
    uint8 public constant MINOR_EMERGENCY_THRESHOLD = 1;
    uint8 public constant CRITICAL_EMERGENCY_THRESHOLD = 2;

    // Emergency recovery tracking
    mapping(address => bool) public recoveryApprovals;
    uint8 public requiredRecoveryApprovals;
    uint8 public recoveryApprovalsCount;

    // Emergency withdrawal tracking
    mapping(address => bool) public emergencyWithdrawalsProcessed;

    // Emergency timestamps
    uint64 public emergencyPauseTime;

    // Crowdsale reference
    address public crowdsaleContract;

    // Events
    event EmergencyStateChanged(EmergencyState state);
    event EmergencyPaused(address indexed triggeredBy, uint64 timestamp);
    event EmergencyResumed(address indexed resumedBy);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint64 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint64 timestamp);
    event EmergencyWithdrawalProcessed(address indexed user, uint256 amount);
    event CrowdsaleSet(address indexed crowdsale);
    event RecoveryRequirementsUpdated(uint8 requiredApprovals);

    // Errors
    error UnauthorizedCaller();
    error AlreadyInEmergencyMode();
    error NotInEmergencyMode();
    error NotEmergencyRole();
    error AlreadyApproved();
    error AlreadyProcessed();
    error RecoveryNotActive();
    error InvalidRequiredApprovalsValue();

    modifier onlyCrowdsale() {
        if (msg.sender != crowdsaleContract) revert UnauthorizedCaller();
        _;
    }

    /**
     * @dev Initializer function to replace constructor
     */
    function initialize() initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);

        // Initialize state
        emergencyState = EmergencyState.NORMAL;
        requiredRecoveryApprovals = 3; // Default value
        recoveryApprovalsCount = 0;
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Set the crowdsale contract address
     * @param _crowdsale Address of the crowdsale contract
     */
    function setCrowdsale(address _crowdsale) external onlyRole(Constants.ADMIN_ROLE) {
        require(_crowdsale != address(0), "Zero address");
        crowdsaleContract = _crowdsale;
        emit CrowdsaleSet(_crowdsale);
    }

    /**
     * @dev Get the current emergency state
     * @return Current emergency state
     */
    function getEmergencyState() external view returns (EmergencyState) {
        return emergencyState;
    }

    /**
     * @dev Set emergency state
     * @param _stateValue Emergency state value (0=NORMAL, 1=MINOR, 2=CRITICAL)
     */
    function setEmergencyState(uint8 _stateValue) external onlyRole(Constants.EMERGENCY_ROLE) {
        _setEmergencyState(_stateValue);
    }

    /**
     * @dev Internal function to set emergency state
     * @param _stateValue Emergency state value
     */
    function _setEmergencyState(uint8 _stateValue) internal {
        EmergencyState newState;
        if (_stateValue == 0) {
            newState = EmergencyState.NORMAL;
        } else if (_stateValue == 1) {
            newState = EmergencyState.MINOR_EMERGENCY;
        } else {
            newState = EmergencyState.CRITICAL_EMERGENCY;
        }

        EmergencyState oldState = emergencyState;
        emergencyState = newState;

        // Handle pause/unpause based on state
        if (newState != EmergencyState.NORMAL && oldState == EmergencyState.NORMAL) {
            emergencyPauseTime = uint64(block.timestamp);
            emit EmergencyPaused(msg.sender, uint64(block.timestamp));
        } else if (newState == EmergencyState.NORMAL && oldState != EmergencyState.NORMAL) {
            emit EmergencyResumed(msg.sender);
        }

        // Handle recovery mode
        if (newState == EmergencyState.CRITICAL_EMERGENCY && oldState != EmergencyState.CRITICAL_EMERGENCY) {
            // Reset approvals when entering critical emergency
            recoveryApprovalsCount = 0;
            for (uint i = 0; i < getRoleMemberCount(Constants.ADMIN_ROLE); i++) {
                recoveryApprovals[getRoleMember(Constants.ADMIN_ROLE, i)] = false;
            }
            emit EmergencyRecoveryInitiated(msg.sender, uint64(block.timestamp));
        } else if (newState != EmergencyState.CRITICAL_EMERGENCY && oldState == EmergencyState.CRITICAL_EMERGENCY) {
            // Reset approvals when leaving critical emergency
            recoveryApprovalsCount = 0;
            emit EmergencyRecoveryCompleted(msg.sender, uint64(block.timestamp));
        }

        emit EmergencyStateChanged(newState);
    }

    /**
     * @dev Declare emergency state via the enum
     * @param _stateEnum Emergency state enum value
     */
    function declareEmergency(EmergencyState _stateEnum) external onlyRole(Constants.EMERGENCY_ROLE) {
        _setEmergencyState(uint8(_stateEnum));
    }

    /**
     * @dev Convenience function to pause operations
     */
    function pauseOperations() external onlyRole(Constants.EMERGENCY_ROLE) {
        if (emergencyState != EmergencyState.NORMAL) revert AlreadyInEmergencyMode();
        _setEmergencyState(1); // Set to MINOR_EMERGENCY
    }

    /**
     * @dev Convenience function to resume operations
     */
    function resumeOperations() external onlyRole(Constants.ADMIN_ROLE) {
        if (emergencyState == EmergencyState.NORMAL) revert NotInEmergencyMode();
        // Only allow resuming from MINOR_EMERGENCY directly
        if (emergencyState == EmergencyState.CRITICAL_EMERGENCY) {
            require(recoveryApprovalsCount >= requiredRecoveryApprovals, "Insufficient recovery approvals");
        }
        _setEmergencyState(0); // Set to NORMAL
    }

    /**
     * @dev Approve recovery in critical emergency
     */
    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        if (emergencyState != EmergencyState.CRITICAL_EMERGENCY) revert RecoveryNotActive();
        if (recoveryApprovals[msg.sender]) revert AlreadyApproved();

        recoveryApprovals[msg.sender] = true;
        recoveryApprovalsCount++;

        if (recoveryApprovalsCount >= requiredRecoveryApprovals) {
            // Return to normal state when enough approvals
            _setEmergencyState(0); // Set to NORMAL
        }
    }

    /**
     * @dev Process emergency withdrawal
     * @param _user User address
     * @param _amount Refund amount
     */
    function processEmergencyWithdrawal(address _user, uint256 _amount) external onlyCrowdsale {
        if (emergencyState != EmergencyState.CRITICAL_EMERGENCY) revert RecoveryNotActive();
        if (emergencyWithdrawalsProcessed[_user]) revert AlreadyProcessed();

        emergencyWithdrawalsProcessed[_user] = true;
        emit EmergencyWithdrawalProcessed(_user, _amount);
    }

    /**
     * @dev Check if emergency withdrawal was processed
     * @param _user User address
     * @return Whether withdrawal was processed
     */
    function isEmergencyWithdrawalProcessed(address _user) external view returns (bool) {
        return emergencyWithdrawalsProcessed[_user];
    }

    /**
     * @dev Mark emergency withdrawal as processed
     * @param _user User address
     */
    function markEmergencyWithdrawalProcessed(address _user) external onlyCrowdsale {
        emergencyWithdrawalsProcessed[_user] = true;
    }

    /**
     * @dev Set required recovery approvals
     * @param _approvals Number of approvals required
     */
    function setRequiredRecoveryApprovals(uint8 _approvals) external onlyRole(Constants.ADMIN_ROLE) {
        if (_approvals == 0) revert InvalidRequiredApprovalsValue();
        requiredRecoveryApprovals = _approvals;
        emit RecoveryRequirementsUpdated(_approvals);
    }

    /**
     * @dev Get number of current recovery approvals
     * @return Number of approvals
     */
    function getRecoveryApprovalsCount() external view returns (uint8) {
        return recoveryApprovalsCount;
    }

    /**
     * @dev Check if admin has approved recovery
     * @param _admin Admin address
     * @return Whether admin has approved
     */
    function hasApprovedRecovery(address _admin) external view returns (bool) {
        return recoveryApprovals[_admin];
    }

    /**
     * @dev Check if emergency mode is active
     * @return Whether in emergency mode
     */
    function isEmergencyMode() external view returns (bool) {
        return emergencyState != EmergencyState.NORMAL;
    }

    /**
     * @dev Check if critical emergency is active
     * @return Whether in critical emergency
     */
    function isCriticalEmergency() external view returns (bool) {
        return emergencyState == EmergencyState.CRITICAL_EMERGENCY;
    }

    /**
     * @dev Get emergency pause time
     * @return Timestamp when emergency was declared
     */
    function getEmergencyPauseTime() external view returns (uint64) {
        return emergencyPauseTime;
    }
}
