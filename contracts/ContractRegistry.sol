// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ContractRegistry
 * @dev Central registry to manage contract addresses and versions for the TeacherSupport ecosystem
 * This facilitates cross-contract communication and upgradability
 */
contract ContractRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Contract names mapped to their addresses
    mapping(bytes32 => address) private contracts;

    // Contract versions
    mapping(bytes32 => uint256) private contractVersions;

    // Contract status (active or deprecated)
    mapping(bytes32 => bool) private contractActive;

    // Contract name to implementation history
    mapping(bytes32 => address[]) private implementationHistory;

    // List of registered contract names
    bytes32[] public registeredContracts;

    // Emergency pause status for the entire system
    bool public systemPaused;

    // Events
    event ContractRegistered(bytes32 indexed contractName, address indexed contractAddress, uint256 version);
    event ContractUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress, uint256 newVersion);
    event ContractStatusChanged(bytes32 indexed contractName, bool isActive);
    event SystemPaused(address indexed by);
    event SystemResumed(address indexed by);

    /**
     * @dev Constructor sets the initial admin
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        systemPaused = false;
    }

    /**
     * @dev Register a new contract in the registry
     * @param _name Name of the contract (as bytes32)
     * @param _address Address of the contract
     */
    function registerContract(bytes32 _name, address _address) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_address != address(0), "ContractRegistry: zero address");
        require(contracts[_name] == address(0), "ContractRegistry: already registered");

        contracts[_name] = _address;
        contractVersions[_name] = 1;
        contractActive[_name] = true;
        registeredContracts.push(_name);

        // Add to implementation history
        implementationHistory[_name].push(_address);

        emit ContractRegistered(_name, _address, 1);
    }

    /**
     * @dev Update an existing contract address
     * @param _name Name of the contract (as bytes32)
     * @param _newAddress New address of the contract
     */
    function updateContract(bytes32 _name, address _newAddress) external onlyRole(UPGRADER_ROLE) nonReentrant {
        require(_newAddress != address(0), "ContractRegistry: zero address");
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        require(contracts[_name] != _newAddress, "ContractRegistry: same address");

        address oldAddress = contracts[_name];
        contracts[_name] = _newAddress;

        // Increment version and update history
        contractVersions[_name]++;
        implementationHistory[_name].push(_newAddress);

        emit ContractUpdated(_name, oldAddress, _newAddress, contractVersions[_name]);
    }

    /**
     * @dev Set the active status of a contract
     * @param _name Name of the contract (as bytes32)
     * @param _isActive Whether the contract is active
     */
    function setContractStatus(bytes32 _name, bool _isActive) external onlyRole(ADMIN_ROLE) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");

        contractActive[_name] = _isActive;

        emit ContractStatusChanged(_name, _isActive);
    }

    /**
     * @dev Get the address of a registered contract
     * @param _name Name of the contract (as bytes32)
     * @return Address of the contract
     */
    function getContractAddress(bytes32 _name) external view returns (address) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        return contracts[_name];
    }

    /**
     * @dev Get the current version of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Current version number
     */
    function getContractVersion(bytes32 _name) external view returns (uint256) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        return contractVersions[_name];
    }

    /**
     * @dev Check if a contract is active
     * @param _name Name of the contract (as bytes32)
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _name) external view returns (bool) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        return contractActive[_name];
    }

    /**
     * @dev Get the implementation history of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Array of historical addresses
     */
    function getImplementationHistory(bytes32 _name) external view returns (address[] memory) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        return implementationHistory[_name];
    }

    /**
     * @dev Get all registered contract names
     * @return Array of contract names
     */
    function getAllContractNames() external view returns (bytes32[] memory) {
        return registeredContracts;
    }

    /**
     * @dev Pause the entire system in case of emergency
     */
    function pauseSystem() external onlyRole(ADMIN_ROLE) {
        require(!systemPaused, "ContractRegistry: already paused");
        systemPaused = true;
        emit SystemPaused(msg.sender);
    }

    /**
     * @dev Resume the system after emergency
     */
    function resumeSystem() external onlyRole(ADMIN_ROLE) {
        require(systemPaused, "ContractRegistry: not paused");
        systemPaused = false;
        emit SystemResumed(msg.sender);
    }

    /**
     * @dev Check if the system is paused
     * @return Whether the system is paused
     */
    function isSystemPaused() external view returns (bool) {
        return systemPaused;
    }

    /**
     * @dev Utility to convert string to bytes32
     * @param _str String to convert
     * @return bytes32 representation
     */
    function stringToBytes32(string memory _str) external pure returns (bytes32 result) {
        require(bytes(_str).length <= 32, "ContractRegistry: string too long");
        assembly {
            result := mload(add(_str, 32))
        }
    }
}