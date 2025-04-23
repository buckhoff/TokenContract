// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Constants} from "./Libraries/Constants.sol";
import {IContractRegistry} from "../Interfaces/IContractRegistry.sol";

/**
 * @title ContractRegistry
 * @dev Central registry to manage contract addresses and versions for the TeacherSupport ecosystem
 * This facilitates cross-contract communication and upgradability
 */
contract ContractRegistry is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IContractRegistry {
    
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

    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;
    bool public inEmergencyRecovery;
    
    // Registry contract interfaces map (contract name => interface ID)
    mapping(bytes32 => bytes4) private contractInterfaces;

    uint256 public recoveryInitiatedTimestamp;
    uint256 public recoveryTimeout = 24 hours;
    
    modifier onlyAdmin() {
        require(hasRole(Constants.ADMIN_ROLE, msg.sender), "ContractRegistry: caller is not admin role");
        _;
    }

    modifier onlyUpgrader() {
        require(hasRole(Constants.UPGRADER_ROLE, msg.sender), "ContractRegistry: caller is not upgrader role");
        _;
    }

    modifier onlyEmergency() {
        require(hasRole(Constants.EMERGENCY_ROLE, msg.sender), "ContractRegistry: caller is not emergency role");
        _;
    }
    
    /**
     * @dev Constructor sets the initial admin
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize function to replace constructor
     */
    function initialize() initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        systemPaused = false;
    }

    /**
     * @dev Register a new contract in the registry
     * @param _name Name of the contract (as bytes32)
     * @param _address Address of the contract
     */
    function registerContract(bytes32 _name, address _address, bytes4 _interfaceId) external onlyAdmin nonReentrant {
        require(_address != address(0), "ContractRegistry: zero address");
        require(contracts[_name] == address(0), "ContractRegistry: already registered");

        require(_address.code.length > 0, "ContractRegistry: not a contract");

        if (_interfaceId != bytes4(0)) {
            // Create a minimal ERC165 check
            bytes4 ERC165_ID = 0x01ffc9a7; // ERC165 interface ID

            // Check if contract supports ERC165 first
            (bool success, bytes memory result) = _address.staticcall(
                abi.encodeWithSelector(ERC165_ID, ERC165_ID)
            );

            bool supportsERC165 = success && result.length >= 32 &&
                                abi.decode(result, (bool));

            // If contract supports ERC165, check for the specific interface
            if (supportsERC165) {
                (success, result) = _address.staticcall(
                    abi.encodeWithSelector(ERC165_ID, _interfaceId)
                );

                require(
                    success && result.length >= 32 && abi.decode(result, (bool)),
                    "ContractRegistry: interface not supported"
                );
            }
        }
        
        contracts[_name] = _address;
        contractVersions[_name] = 1;
        contractActive[_name] = true;
        registeredContracts.push(_name);

        if (_interfaceId != bytes4(0)) {
            contractInterfaces[_name] = _interfaceId;
            emit ContractInterfaceRegistered(_name, _interfaceId);
        }
        
        // Add to implementation history
        implementationHistory[_name].push(_address);

        requiredRecoveryApprovals = 3; // Default value
        
        emit ContractRegistered(_name, _address, 1);
    }

    /**
     * @dev Update an existing contract address
     * @param _name Name of the contract (as bytes32)
     * @param _newAddress New address of the contract
     */
    function updateContract(bytes32 _name, address _newAddress, bytes4 _interfaceId) external onlyUpgrader nonReentrant {
        require(_newAddress != address(0), "ContractRegistry: zero address");
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        require(contracts[_name] != _newAddress, "ContractRegistry: same address");

        require(_newAddress.code.length > 0, "ContractRegistry: not a contract");
        
        address oldAddress = contracts[_name];
        bytes4 oldInterfaceId = contractInterfaces[_name];

        bytes4 newInterfaceId = (_interfaceId != bytes4(0)) ? _interfaceId : oldInterfaceId;

        if (newInterfaceId != bytes4(0)) {
            // Create a minimal ERC165 check
            bytes4 ERC165_ID = 0x01ffc9a7; // ERC165 interface ID

            // Check if contract supports ERC165 first
            (bool success, bytes memory result) = _newAddress.staticcall(
                abi.encodeWithSelector(ERC165_ID, ERC165_ID)
            );

            bool supportsERC165 = success && result.length >= 32 &&
                                abi.decode(result, (bool));

            // If contract supports ERC165, check for the specific interface
            if (supportsERC165) {
                (success, result) = _newAddress.staticcall(
                    abi.encodeWithSelector(ERC165_ID, newInterfaceId)
                );

                require(
                    success && result.length >= 32 && abi.decode(result, (bool)),
                    "ContractRegistry: interface not supported"
                );
            }
        }
        
        contracts[_name] = _newAddress;

        // Update interface ID if provided
        if (_interfaceId != bytes4(0)) {
            contractInterfaces[_name] = _interfaceId;
            emit ContractInterfaceRegistered(_name, _interfaceId);
        }
        
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
    function setContractStatus(bytes32 _name, bool _isActive) external onlyAdmin {
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
    * @dev Get the interface ID of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Interface ID of the contract
     */
    function getContractInterface(bytes32 _name) external view returns (bytes4) {
        require(contracts[_name] != address(0), "ContractRegistry: not registered");
        return contractInterfaces[_name];
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
    function pauseSystem() external onlyAdmin onlyEmergency {
        require(!systemPaused, "ContractRegistry: already paused");
        systemPaused = true;
        emit SystemPaused(msg.sender);
    }

    /**
     * @dev Resume the system after emergency
     */
    function resumeSystem() external onlyAdmin {
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

    // Add emergency recovery functions
    function initiateEmergencyRecovery() external onlyEmergency {
        require(systemPaused, "ContractRegistry: system not paused");
        inEmergencyRecovery = true;
        recoveryInitiatedTimestamp = block.timestamp;

        // Reset any existing approvals to start fresh
        for (uint i = 0; i < getRoleMemberCount(Constants.ADMIN_ROLE); i++) {
            emergencyRecoveryApprovals[getRoleMember(Constants.ADMIN_ROLE, i)] = false;
        }
        
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    function approveRecovery() external onlyAdmin {
        require(inEmergencyRecovery, "ContractRegistry: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "ContractRegistry: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;

        if (_countRecoveryApprovals() >= requiredRecoveryApprovals) {
            inEmergencyRecovery = false;
            systemPaused = false;
            emit EmergencyRecoveryCompleted(msg.sender);
        }
    }

    function _countRecoveryApprovals() internal view returns (uint256) {
        uint256 count = 0;
        uint256 memberCount = getRoleMemberCount(Constants.ADMIN_ROLE);

        if (block.timestamp > recoveryInitiatedTimestamp + recoveryTimeout) {
            return 0; // Return 0 if recovery has timed out
        }
        
        for (uint i = 0; i < memberCount; i++) {
            address admin = getRoleMember(Constants.ADMIN_ROLE, i);
            if (emergencyRecoveryApprovals[admin]) {
                count++;
            }
        }
        return count;
    }

    function setRequiredRecoveryApprovals(uint256 _required) external onlyAdmin {
        require(_required > 0, "ContractRegistry: invalid approval count");
        requiredRecoveryApprovals = _required;
        emit RecoveryApprovalsUpdated(_required);
    }

    function getRoleMemberCount(bytes32 role) internal view returns (uint256) {
        return AccessControlUpgradeable.getRoleMemberCount(role);
    }

    function getRoleMember(bytes32 role, uint256 index) internal view returns (address) {
        return AccessControlUpgradeable.getRoleMember(role, index);
    }

    function setRecoveryTimeout(uint256 _timeout) external onlyAdmin {
        require(_timeout >= 1 hours, "ContractRegistry: timeout too short");
        require(_timeout <= 7 days, "ContractRegistry: timeout too long");
        recoveryTimeout = _timeout;
    }
}