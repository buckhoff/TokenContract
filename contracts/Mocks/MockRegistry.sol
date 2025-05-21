// MockRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockRegistry
 * @dev Mock implementation of IContractRegistry for testing
 */
contract MockRegistry {
    // Store contract addresses and status
    mapping(bytes32 => address) private contracts;
    mapping(bytes32 => bool) private contractActive;
    mapping(bytes32 => uint256) private contractVersions;
    
    // System pause flag
    bool public systemPaused;

    /**
     * @dev Set a contract's address, active status, and version
     */
    function setContractAddress(bytes32 _name, address _address, bool _isActive) external {
        contracts[_name] = _address;
        contractActive[_name] = _isActive;
        contractVersions[_name] = 1;
    }

    /**
     * @dev Update a contract's status and version
     * This is separate from setting the address and more clearly named
     */
    function updateContractStatus(bytes32 _name, bool _isActive, uint256 _version) external {
        contractActive[_name] = _isActive;
        contractVersions[_name] = _version;
    }

    /**
     * @dev Get a contract's address
     */
    function getContractAddress(bytes32 _name) external view returns (address) {
        return contracts[_name];
    }

    /**
     * @dev Check if a contract is active
     */
    function isContractActive(bytes32 _name) external view returns (bool) {
        return contractActive[_name];
    }

    /**
     * @dev Check if the system is paused
     */
    function isSystemPaused() external view returns (bool) {
        return systemPaused;
    }

    /**
     * @dev Get a contract's version
     */
    function getContractVersion(bytes32 _name) external view returns (uint256) {
        return contractVersions[_name];
    }
    
    /**
     * @dev Set system pause state
     */
    function setPaused(bool _paused) external {
        systemPaused = _paused;
    }

    /**
     * @dev Utility to convert string to bytes32
     */
    function stringToBytes32(string memory _str) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_str));
    }
}