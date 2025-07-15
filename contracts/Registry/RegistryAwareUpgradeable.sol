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

    struct FailedCall {
        address caller;
        bytes32 contractName;
        bytes callData;
        uint256 timestamp;
        bool resolved;
    }
    mapping(uint256 => FailedCall) public failedCalls;
    uint256 public failedCallCounter;
    
    // Events
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ContractCallFailed(bytes32 indexed contractName, bytes4 indexed methodId, string reason);
    event EmergencyNotificationFailed(bytes32 indexed contractName);
    event TokenContractUnknown(bytes32 indexed contractName);
    
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
        if (address(registry) == address(0)) revert RegistryNotSet();
        return registry.getContractAddress(_contractNameBytes32);
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
            emit ContractCallFailed(_contractNameBytes32, bytes4(_callData), "Fallback call failed after registry offline mode");
            return (false, bytes(""));
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
                    
                    failedCalls[failedCallCounter++] = FailedCall({
                        caller: msg.sender,
                        contractName: _contractNameBytes32,
                        callData: _callData,
                        timestamp: block.timestamp,
                        resolved: false
                    });
                    
                    return (false, returnData);
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

    function retryFailedCall(uint256 callId) external onlyRole(Constants.ADMIN_ROLE) {
        FailedCall storage fc = failedCalls[callId];
        require(!fc.resolved, "Already resolved");

        address target = getContractAddress(fc.contractName);
        require(target != address(0), "Target address not found");

        (bool success, ) = target.call(fc.callData);
        require(success, "Retry call failed");

        fc.resolved = true;
    }
    
    /**
     * @dev Internal function that child contracts override to provide their pause state
     * @return Whether the contract is paused
     */
    function _isContractPaused() internal virtual view returns (bool) {
        return false; // Default implementation assumes not paused
    }
}