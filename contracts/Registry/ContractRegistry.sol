// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Constants} from "../Libraries/Constants.sol";
import "../Interfaces/IContractRegistry.sol";

/**
 * @title ContractRegistry
 * @dev Central registry to manage contract addresses and versions for the TeacherSupport ecosystem
 * This facilitates cross-contract communication and upgradability
 */
contract ContractRegistry is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable, 
    IContractRegistry 
{
    
    // List of registered contract names
    bytes32[] public registeredContracts;
    
    // Contract names mapped to their addresses
    mapping(bytes32 => address) private contracts;
    // Contract versions
    mapping(bytes32 => uint256) private contractVersions;
    // Contract status (active or deprecated)
    mapping(bytes32 => bool) private contractActive;
    // Contract name to implementation history
    mapping(bytes32 => address[]) private implementationHistory;

    // Emergency pause status for the entire system
    bool public systemPaused;

    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;
    bool public inEmergencyRecovery;
    
    // Registry contract interfaces map (contract name => interface ID)
    mapping(bytes32 => bytes4) private contractInterfaces;

    uint256 public recoveryInitiatedTimestamp;
    uint256 public recoveryTimeout;
    
    event SystemHasBeenPaused(bytes32 indexed contractName);
    event SystemEmergencyTriggered(address indexed triggeredBy, string reason);
    event ExternalCallFailed(string method, address target);
    
    // Add custom errors at the top:
    error AlreadyRegistered();
    error NotAContract();
    error InterfaceNotSupported();
    error ZeroAddress();
    error NotRegistered();
    error SameAddress();
    error StringTooLong();
    error SystemNotPaused();
    error NotInRecoveryMode();
    error AlreadyApproved();
    error InvalidApprovalCount();
    error TimeoutTooShort();
    error TimeoutTooLong();
    error AlreadyPaused();
    
    /**
     * @dev Constructor 
     */
    //constructor() {
    //    _disableInitializers();
    //}

    /**
     * @dev Initialize function to replace constructor
     */
    function initialize() initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(Constants.MANAGER_ROLE, msg.sender);
        systemPaused = false;
        recoveryTimeout = 24 hours;
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }
    
    /**
     * @dev Register a new contract in the registry
     * @param _name Name of the contract (as bytes32)
     * @param _address Address of the contract
     */
    function registerContract(bytes32 _name, address _address, bytes4 _interfaceId) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if(_address == address(0)) revert ZeroAddress();
        if(contracts[_name] != address(0)) revert AlreadyRegistered();

        if (_address.code.length == 0) revert NotAContract();

        if (_interfaceId != bytes4(0)) {
            if (!_supportsInterface(_address, _interfaceId)) revert InterfaceNotSupported();
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
     * @param _interfaceId set the new interface ID
     */
    function updateContract(bytes32 _name, address _newAddress, bytes4 _interfaceId) external onlyRole(Constants.UPGRADER_ROLE) nonReentrant {
        if(_newAddress == address(0)) revert ZeroAddress();
        if(contracts[_name] == address(0)) revert NotRegistered();
        if(contracts[_name] == _newAddress) revert SameAddress();

        if (_newAddress.code.length == 0) revert NotAContract();
        
        address oldAddress = contracts[_name];
        bytes4 oldInterfaceId = contractInterfaces[_name];

        bytes4 newInterfaceId = (_interfaceId != bytes4(0)) ? _interfaceId : oldInterfaceId;

        if (newInterfaceId != bytes4(0)) {
            if (!_supportsInterface(_newAddress, newInterfaceId)) revert InterfaceNotSupported();
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
    function setContractStatus(bytes32 _name, bool _isActive) external onlyRole(Constants.ADMIN_ROLE) {
        if(contracts[_name] == address(0)) revert NotRegistered();

        contractActive[_name] = _isActive;

        emit ContractStatusChanged(_name, _isActive);
    }

    /**
     * @dev Get the address of a registered contract
     * @param _name Name of the contract (as bytes32)
     * @return address of the contract
     */
    function getContractAddress(bytes32 _name) external view returns (address) {
        if(contracts[_name] == address(0)) revert NotRegistered();
        return contracts[_name];
    }

    /**
     * @dev Get the current version of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Current version number
     */
    function getContractVersion(bytes32 _name) external view returns (uint256) {
        if(contracts[_name] == address(0)) revert NotRegistered();
        return contractVersions[_name];
    }

    /**
     * @dev Check if a contract is active
     * @param _name Name of the contract (as bytes32)
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _name) external view returns (bool) {
        if(contracts[_name] == address(0)){
            return false;
        }
        return contractActive[_name];
    }

    /**
    * @dev Get the interface ID of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Interface ID of the contract
     */
    function getContractInterface(bytes32 _name) external view returns (bytes4) {
        if(contracts[_name] == address(0)) revert NotRegistered();
        return contractInterfaces[_name];
    }
    
    /**
     * @dev Get the implementation history of a contract
     * @param _name Name of the contract (as bytes32)
     * @return Array of historical addresses
     */
    function getImplementationHistory(bytes32 _name) external view returns (address[] memory) {
        if(contracts[_name] == address(0)) revert NotRegistered();
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
     * @dev Utility to convert string to bytes32
     * @param _str String to convert
     * @return result bytes32
     */
    function stringToBytes32(string memory _str) external pure returns (bytes32 result) {
        if (bytes(_str).length > 32) revert StringTooLong();
        result = keccak256(abi.encodePacked(_str));

    }

    /**
    * @dev Triggers system-wide emergency mode
     * @param _reason Reason for the emergency
     */
    function triggerSystemEmergency(string memory _reason) external onlyRole(Constants.EMERGENCY_ROLE) {

        // Pause the registry
        try this.pauseSystem() {
            emit SystemHasBeenPaused("Contract Registry");
        } catch {

        }

        // Notify stability fund
        if (this.isContractActive(Constants.STABILITY_FUND_NAME)) {
            address stabilityFund = this.getContractAddress(Constants.STABILITY_FUND_NAME);
            (bool success, ) = stabilityFund.call(
                abi.encodeWithSignature("emergencyPause()")
            );
            if (!success) {
                emit EmergencyNotificationFailed(Constants.STABILITY_FUND_NAME);
            }
        }

        // Notify marketplace
        if (this.isContractActive(Constants.MARKETPLACE_NAME)) {
            address marketplace = this.getContractAddress(Constants.MARKETPLACE_NAME);
            (bool success, ) = marketplace.call(
                abi.encodeWithSignature("pauseMarketplace()")
            );
            if (!success) {
                emit EmergencyNotificationFailed(Constants.STABILITY_FUND_NAME);
            }
        }

        // Notify crowdsale
        if (this.isContractActive(Constants.CROWDSALE_NAME)) {
            address crowdsale = this.getContractAddress(Constants.CROWDSALE_NAME);
            (bool success, ) = crowdsale.call(
                abi.encodeWithSignature("pausePresale()")
            );
            if (!success) {
                emit EmergencyNotificationFailed(Constants.STABILITY_FUND_NAME);
            }
        }

        // Notify staking
        if (this.isContractActive(Constants.STAKING_NAME)) {
            address staking = this.getContractAddress(Constants.STAKING_NAME);
            (bool success, ) = staking.call(
                abi.encodeWithSignature("pauseStaking()")
            );
            if (!success) {
                emit EmergencyNotificationFailed(Constants.STABILITY_FUND_NAME);
            }

        }

        // Notify rewards
        if (this.isContractActive(Constants.PLATFORM_REWARD_NAME)) {
            address rewards = this.getContractAddress(Constants.PLATFORM_REWARD_NAME);
            (bool success, ) = rewards.call(
                abi.encodeWithSignature("pauseRewards()")
            );
            if (!success) {
                emit EmergencyNotificationFailed(Constants.STABILITY_FUND_NAME);
            }
        }

        emit SystemEmergencyTriggered(msg.sender, _reason);
    }

    // Add emergency recovery functions
    function initiateEmergencyRecovery() external onlyRole(Constants.EMERGENCY_ROLE) {
        if (systemPaused) revert SystemNotPaused();
        inEmergencyRecovery = true;
        recoveryInitiatedTimestamp = block.timestamp;

        // Reset any existing approvals to start fresh
        for (uint i = 0; i < getRoleMemberCount(Constants.ADMIN_ROLE); i++) {
            emergencyRecoveryApprovals[getRoleMember(Constants.ADMIN_ROLE, i)] = false;
        }
        
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        if (!inEmergencyRecovery) revert NotInRecoveryMode();
        if (emergencyRecoveryApprovals[msg.sender]) revert AlreadyApproved();

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
    /**
     * @dev Utility to set the min number of recovery approvals
     * @param _required approvals needed
     */
    function setRequiredRecoveryApprovals(uint256 _required) external onlyRole(Constants.ADMIN_ROLE) {
        if (_required == 0) revert InvalidApprovalCount();
        requiredRecoveryApprovals = _required;
        emit RecoveryApprovalsUpdated(_required);
    }

    /**
     * @dev Set timeout
     * @param _timeout new timeout to set
     */
    function setRecoveryTimeout(uint256 _timeout) external onlyRole(Constants.ADMIN_ROLE) {
        if (_timeout < 1 hours) revert TimeoutTooShort();
        if (_timeout > 7 days) revert TimeoutTooLong();
        recoveryTimeout = _timeout;
    }

    /**
    * @dev Pause the entire system in case of emergency
     */
    function pauseSystem() external {
        if (hasRole(Constants.ADMIN_ROLE, msg.sender) || hasRole(Constants.EMERGENCY_ROLE, msg.sender)) {
            if (systemPaused) revert AlreadyPaused();
            systemPaused = true;
            emit SystemPaused(msg.sender);
        }
        else{
            revert();
        }
    }

    /**
     * @dev Resume the system after emergency
     */
    function resumeSystem() external onlyRole(Constants.ADMIN_ROLE) {
        if (!systemPaused) revert SystemNotPaused();
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

    function _supportsInterface(address contractAddr, bytes4 interfaceId) internal view returns (bool) {
        (bool success, bytes memory result) = contractAddr.staticcall(
            abi.encodeWithSelector(0x01ffc9a7, 0x01ffc9a7) // ERC165 ID check
        );

        bool supportsERC165 = success && result.length >= 32 && abi.decode(result, (bool));

        if (!supportsERC165) return false;

        (success, result) = contractAddr.staticcall(
            abi.encodeWithSelector(0x01ffc9a7, interfaceId)
        );

        return (success && result.length >= 32 && abi.decode(result, (bool)));
    }
}