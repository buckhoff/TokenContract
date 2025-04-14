// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IContractRegistry.sol";

/**
 * @title RegistryAware
 * @dev Base contract for all registry-aware contracts in the TeacherSupport ecosystem
 * Provides functionality for interacting with the registry and emergency pause
 */
abstract contract RegistryAware {
    // Registry contract interface
    IContractRegistry public registry;

    // Contract name in the registry
    bytes32 public contractName;

    // Events
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ContractCallFailed(bytes32 indexed targetContract, bytes4 indexed methodId, string reason);
    
    /**
     * @dev Modifier to check if the system is not paused
     */
    modifier whenSystemNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool paused) {
                require(!paused, "RegistryAware: system is paused");
            } catch {
                // If registry call fails, proceed as not paused
                // This prevents deadlocks if registry is compromised
            }
        }
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
        require(address(registry) != address(0), "RegistryAware: registry not set");
        return registry.getContractAddress(_contractNameBytes32);
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
}