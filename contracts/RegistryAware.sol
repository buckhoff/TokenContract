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

    /**
     * @dev Modifier to check if the system is not paused
     */
    modifier whenSystemNotPaused() {
        require(!registry.isSystemPaused(), "RegistryAware: system is paused");
        _;
    }

    /**
     * @dev Modifier to check if the caller is a specific contract from registry
     * @param _contractNameBytes32 Name of the expected contract
     */
    modifier onlyFromRegistry(bytes32 _contractNameBytes32) {
        address contractAddress = registry.getContractAddress(_contractNameBytes32);
        require(msg.sender == contractAddress, "RegistryAware: caller not authorized contract");
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
        return registry.getContractAddress(_contractNameBytes32);
    }

    /**
     * @dev Checks if a contract is active in the registry
     * @param _contractNameBytes32 Name of the contract to check
     * @return Whether the contract is active
     */
    function isContractActive(bytes32 _contractNameBytes32) internal view returns (bool) {
        return registry.isContractActive(_contractNameBytes32);
    }
}