// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "../Interfaces/IContractRegistry.sol";
import {Constants} from "../Libraries/Constants.sol";

/**
 * @title RegistryAware
 * @dev Base contract for all registry-aware contracts in the platform ecosystem
 * Provides functionality for interacting with the registry and emergency pause
 */
abstract contract RegistryAwareUpgradeable is Initializable, AccessControlEnumerableUpgradeable {
    
    // Registry contract interface
    IContractRegistry public registry;

    // Contract name in the registry
    bytes32 public contractName;

    bool public registryOfflineMode;
    
    //fallback address on failures
    mapping(bytes32 => address) internal _fallbackAddresses;
    
    // Events
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ContractCallFailed(bytes32 indexed contractName, bytes4 indexed methodId, string reason);
    event FallbackAddressSet(bytes32 indexed contractName,address indexed fallbackaddress);
    event RegistryOfflineModeEnabled();
    event RegistryOfflineModeDisabled();
    event EmergencyNotificationFailed(bytes32 indexed contractName);
    
    error SystemPaused();
    error RegistryNotSet();
    error ContractNotActive();
    error ZeroContractAddress();
    error FailedToRetrieveContractAddress();
    error NotAuthorized();
    error RegistryCallFailed();
    error FailedToRetrieveContractStatus();
    error ContractPaused();
    error RegistryOffline();
    
   /**
     * @dev Modifier to check if the system is not paused
     */
    modifier whenContractNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if(systemPaused) revert SystemPaused();
            } catch {
                if(_isContractPaused()) revert ContractPaused();
            }
            if(registryOfflineMode) revert RegistryOffline();
            if(_isContractPaused()) revert ContractPaused();
        } else {
            if(_isContractPaused()) revert ContractPaused();
        }
        _;
    }
    
    /**
     * @dev Modifier to check if the caller is a specific contract from registry
     * @param _contractNameBytes32 Name of the expected contract
     */
    modifier onlyFromRegistry(bytes32 _contractNameBytes32) {
        if(address(registry) == address(0)) revert RegistryNotSet();

        address expectedCaller;
        try registry.isContractActive(_contractNameBytes32) returns (bool isActive) {
            if (!isActive) {
                revert ContractNotActive();
            }

            try registry.getContractAddress(_contractNameBytes32) returns (address contractAddress) {
                if (contractAddress == address(0)) {
                    revert ZeroContractAddress();
                }
                expectedCaller = contractAddress;
            } catch {
                revert FailedToRetrieveContractAddress();
            }
        } catch {
            revert FailedToRetrieveContractStatus();
        }

        // Verify caller matches expected address
        if (msg.sender != expectedCaller) revert NotAuthorized();
        _;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     * @param _contractNameBytes32 Name of this contract in the registry
     */
    function _setRegistry(address _registry, bytes32 _contractNameBytes32) internal {
        if(_registry == address(0)) revert ZeroContractAddress();
        address oldRegistry = address(registry);
        registry = IContractRegistry(_registry);
        contractName = _contractNameBytes32;

        emit RegistryUpdated(oldRegistry, _registry);
    }

    /**
     * @dev Gets the address of a contract from the registry
     * @param _contractNameBytes32 Name of the contract to look up
     * @return Contract address
     */
    function getContractAddress(bytes32 _contractNameBytes32) internal view returns (address) {
        if (address(registry) == address(0) || registryOfflineMode) {
            return _fallbackAddresses[_contractNameBytes32];
        }

        try registry.getContractAddress(_contractNameBytes32) returns (address contractAddress) {
            if (contractAddress != address(0)) {
                return contractAddress;
            }
        } catch {
            // Registry call failed, use fallback
        }

        return _fallbackAddresses[_contractNameBytes32];
    }

    /**
     * @dev Checks if a contract is active in the registry
     * @param _contractNameBytes32 Name of the contract to check
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _contractNameBytes32) internal view returns (bool) {
        if (address(registry) == address(0)) revert RegistryNotSet();
        return registry.isContractActive(_contractNameBytes32);
    }

    /**
     * @dev Makes a safe call to another contract through the registry
     * @param _contractNameBytes32 Name of the contract to call
     * @param _callData The calldata to send
     * @return success Whether the call succeeded
     * @return returnData The data returned by the call
     */
    function _safeContractCall(
        bytes32 _contractNameBytes32,
        bytes memory _callData
    ) internal returns (bool success, bytes memory returnData) {
        // Check if registry is set and not in offline mode
        if (address(registry) == address(0)) {
            emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Registry not set");
            return (false, bytes(""));
        }

        if (registryOfflineMode) {
            // In offline mode, try to use fallback address
            address fallbackAddress = _fallbackAddresses[_contractNameBytes32];
            if (fallbackAddress != address(0)) {
                (success, returnData) = fallbackAddress.call(_callData);
                if (!success) {
                    emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Fallback call failed");
                }
                return (success, returnData);
            } else {
                emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "No fallback address");
                return (false, bytes(""));
            }
        }

        // Standard registry flow
        try registry.isContractActive(_contractNameBytes32) returns (bool isActive) {
            if (!isActive) {
                emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Contract not active");
                return (false, bytes(""));
            }

            try registry.getContractAddress(_contractNameBytes32) returns (address contractAddress) {
                if (contractAddress == address(0)) {
                    emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Zero contract address");
                    return (false, bytes(""));
                }

                // Make the actual call
                (success, returnData) = contractAddress.call(_callData);

                if (!success) {
                    emit ContractCallFailed(
                        _contractNameBytes32,
                        bytes4(_callData),
                        "Call reverted"
                    );
                }

                return (success, returnData);
            } catch {
                emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Failed to get contract address");
                return (false, bytes(""));
            }
        } catch {
            emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Failed to check contract active status");
            return (false, bytes(""));
        }
    }

    function setFallbackAddress(bytes32 _contractName, address _fallbackAddress) external onlyRole(Constants.ADMIN_ROLE) {
        _fallbackAddresses[_contractName] = _fallbackAddress;
        emit FallbackAddressSet(_contractName, _fallbackAddress);
    }

    function enableRegistryOfflineMode() external onlyRole(Constants.ADMIN_ROLE) {
        registryOfflineMode = true;
        emit RegistryOfflineModeEnabled();
    }

    function isRegistryOffline() public onlyRole(Constants.ADMIN_ROLE) view returns (bool _isOffline)  {
        _isOffline = registryOfflineMode;
        return _isOffline;
    }

    function disableRegistryOfflineMode() external onlyRole(Constants.ADMIN_ROLE) {
        // Verify registry is accessible before disabling offline mode
        require(address(registry) != address(0), "RegistryAware: registry not set");
        
        // Test registry connection
        try registry.isSystemPaused() returns (bool) {
            // Registry is accessible, can disable offline mode
            registryOfflineMode = false;
            emit RegistryOfflineModeDisabled();
        } catch {
            // Registry still not accessible
            revert("RegistryAware: registry not accessible");
        }
    }

    /**
     * @dev Internal function that child contracts override to provide their pause state
     * @return Whether the contract is paused
     */
    function _isContractPaused() internal virtual view returns (bool) {
        return false; // Default implementation assumes not paused
    }
}