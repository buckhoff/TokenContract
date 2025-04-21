// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title IContractRegistry
 * @dev Interface for the ContractRegistry to be used by other contracts
 */
interface IContractRegistry {

    event ContractRegistered(bytes32 indexed contractName, address indexed contractAddress, uint256 version);
    event ContractUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress, uint256 newVersion);
    event ContractStatusChanged(bytes32 indexed contractName, bool isActive);
    event SystemPaused(address indexed by);
    event SystemResumed(address indexed by);
    event ContractInterfaceRegistered(bytes32 indexed contractName, bytes4 interfaceId);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin);
    
    /**
     * @dev Get the address of a registered contract
     * @param _name Name of the contract (as bytes32)
     * @return Address of the contract
     */
    function getContractAddress(bytes32 _name) external view returns (address);

    /**
     * @dev Check if a contract is active
     * @param _name Name of the contract (as bytes32)
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _name) external view returns (bool);

    /**
     * @dev Check if the system is paused
     * @return Whether the system is paused
     */
    function isSystemPaused() external view returns (bool);

    /**
     * @dev Get the interface ID of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Interface ID of the contract
     */
    function getContractInterface(bytes32 _name) external view returns (bytes4);

    /**
     * @dev Get the current version of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Current version number
     */
    function getContractVersion(bytes32 _name) external view returns (uint256);

    /**
     * @dev Pause the entire system in case of emergency
     */
    function pauseSystem() external;

    /**
     * @dev Resume the system after emergency
     */
    function resumeSystem() external;

    /**
     * @dev Initiates emergency recovery mode
     */
    function initiateEmergencyRecovery() external;

    /**
     * @dev Approves emergency recovery
     */
    function approveRecovery() external;

    /**
     * @dev Sets required recovery approvals
     * @param _required Number of required approvals
     */
    function setRequiredRecoveryApprovals(uint256 _required) external;
    

    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}