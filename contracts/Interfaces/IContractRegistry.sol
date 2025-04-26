// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "../Libraries/Constants.sol";

/**
 * @title IContractRegistry
 * @dev Interface for the ContractRegistry to be used by other contracts
 */
interface IContractRegistry {
    // Events
    event ContractRegistered(bytes32 indexed contractName, address indexed contractAddress, uint256 version);
    event ContractUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress, uint256 newVersion);
    event ContractStatusChanged(bytes32 indexed contractName, bool isActive);
    event SystemPaused(address indexed by);
    event SystemResumed(address indexed by);
    event ContractInterfaceRegistered(bytes32 indexed contractName, bytes4 interfaceId);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin);
    event RecoveryApprovalsUpdated(uint256 requiredApprovals);

    /**
     * @dev Register a new contract in the registry
     * @param _name Name of the contract (as bytes32)
     * @param _address Address of the contract
     * @param _interfaceId Interface ID of the contract (optional)
     */
    function registerContract(bytes32 _name, address _address, bytes4 _interfaceId) external;

    /**
     * @dev Update an existing contract address
     * @param _name Name of the contract (as bytes32)
     * @param _newAddress New address of the contract
     * @param _interfaceId Interface ID of the contract (optional)
     */
    function updateContract(bytes32 _name, address _newAddress, bytes4 _interfaceId) external;

    /**
     * @dev Set the active status of a contract
     * @param _name Name of the contract (as bytes32)
     * @param _isActive Whether the contract is active
     */
    function setContractStatus(bytes32 _name, bool _isActive) external;

    /**
     * @dev Get the address of a registered contract
     * @param _name Name of the contract (as bytes32)
     * @return Address of the contract
     */
    function getContractAddress(bytes32 _name) external view returns (address);

    /**
     * @dev Get the current version of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Current version number
     */
    function getContractVersion(bytes32 _name) external view returns (uint256);

    /**
     * @dev Check if a contract is active
     * @param _name Name of the contract (as bytes32)
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _name) external view returns (bool);

    /**
     * @dev Get the interface ID of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Interface ID of the contract
     */
    function getContractInterface(bytes32 _name) external view returns (bytes4);

    /**
     * @dev Get the implementation history of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Array of historical addresses
     */
    function getImplementationHistory(bytes32 _name) external view returns (address[] memory);
    
    /**
     * @dev Get all the registered contracts
     * @return memory data
     */
    function getAllContractNames() external view returns (bytes32[] memory);
    
    /**
     * @dev Pause the entire system in case of emergency
     */
    function pauseSystem() external;

    /**
     * @dev Resume the system after emergency
     */
    function resumeSystem() external;

    /**
     * @dev Check if the system is paused
     * @return Whether the system is paused
     */
    function isSystemPaused() external view returns (bool);

    /**
     * @dev Convert string to bytes32
     * @param _str String to convert
     * @return result bytes32 representation
     */
    function stringToBytes32(string memory _str) external pure returns (bytes32 result);

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

    /**
     * @dev Set recovery timeout time
     * @param _timeout value for timeout
     */
    function setRecoveryTimeout(uint256 _timeout) external;
}