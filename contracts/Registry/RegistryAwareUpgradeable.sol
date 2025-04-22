// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./Interfaces/IContractRegistry.sol";
import {Constants} from "../Constants.sol";

/**
 * @title RegistryAware
 * @dev Base contract for all registry-aware contracts in the platform ecosystem
 * Provides functionality for interacting with the registry and emergency pause
 */
abstract contract RegistryAwareUpgradeable is Initializable, AccessControlUpgradeable {
    
    // Registry contract interface
    IContractRegistry public registry;

    // Contract name in the registry
    bytes32 public contractName;

    bool public registryOfflineMode;
    
    //fallback address on failures
    mapping(bytes32 => address) internal _fallbackAddresses;
    
    // Events
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ContractCallFailed(bytes32 indexed targetContract, bytes4 indexed methodId, string reason);
    event FallbackAddressSet(bytes32 indexed contractname,address indexed fallbackaddress);
    event RegistryOfflineModeEnabled();
    event RegistryOfflineModeDisabled();
    /**
     * @dev Modifier to check if the system is not paused
     */
    modifier whenSystemNotPaused() {
        if (address(registry) != address(0) && !registryOfflineMode) {
            try registry.isSystemPaused() returns (bool paused) {
                require(!paused, "RegistryAware: system is paused");
            } catch {
                // If registry call fails, proceed as not paused
                if (!registryOfflineMode) {
                    revert("Registry unavailable");
                }
            }
        }
        _;
    }

    modifier onlyAdmin() {
        require(hasRole(Constants.ADMIN_ROLE, msg.sender), "RegistryAware: caller is not admin role");
        _;
    }
    /**
     * @dev Modifier to check if the caller is a specific contract from registry
     * @param _contractNameBytes32 Name of the expected contract
     */
    modifier onlyFromRegistry(bytes32 _contractNameBytes32) {
        require(address(registry) != address(0), "RegistryAware: registry not set");
        try registry.getContractAddress(_contractNameBytes32) returns (address contractAddress) {
        require(contractAddress != address(0), "RegistryAware: contract not registered");
        require(msg.sender == contractAddress, "RegistryAware: caller not authorized contract");
        } catch{
            revert("RegistryAware: registry lookup failed");
        }
        _;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     * @param _contractNameBytes32 Name of this contract in the registry
     */
    function _setRegistry(address _registry, bytes32 _contractNameBytes32) internal {
        require(_registry != address(0), "RegistryAware: zero registry address");
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
        require(address(registry) != address(0), "RegistryAware: registry not set");
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
        require(address(registry) != address(0), "RegistryAware: registry not set");

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

    function setFallbackAddress(bytes32 _contractName, address _fallbackAddress) external onlyAdmin {
        _fallbackAddresses[_contractName] = _fallbackAddress;
        emit FallbackAddressSet(_contractName, _fallbackAddress);
    }

    // Modify getContractAddress to use fallback
    function getContractAddress(bytes32 _contractNameBytes32) internal view returns (address) {
        if (address(registry) == address(0)) {
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

    function enableRegistryOfflineMode() external onlyAdmin {
        registryOfflineMode = true;
        emit RegistryOfflineModeEnabled();
    }

    function disableRegistryOfflineMode() external onlyAdmin {
        registryOfflineMode = false;
        emit RegistryOfflineModeDisabled();
    }
}