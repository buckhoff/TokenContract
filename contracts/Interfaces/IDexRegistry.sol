// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title IDexRegistry
 * @dev Interface for the DexRegistry contract
 */
interface IDexRegistry {
    // DEX details structure
    struct DexInfo {
        string name;
        address router;
        address factory;
        address pair;
        address stakingRewards; // For LP token staking
        uint8 allocationPercentage; // Percentage allocation (100 = 1%)
        bool active;
    }

    // Events
    event DexAdded(uint16 indexed dexId, string name, address router, uint8 allocationPercentage);
    event DexUpdated(uint16 indexed dexId, string name, address router, uint8 allocationPercentage);
    event DexActivated(uint16 indexed dexId);
    event DexDeactivated(uint16 indexed dexId);

    // Functions
    function addDex(
        string memory _name,
        address _router,
        address _factory,
        address _stakingRewards,
        uint8 _allocationPercentage
    ) external returns (uint16);

    function updateDex(
        uint16 _dexId,
        string memory _name,
        address _router,
        address _factory,
        address _stakingRewards,
        uint8 _allocationPercentage
    ) external;

    function activateDex(uint16 _dexId) external;
    function deactivateDex(uint16 _dexId) external;
    function getDexInfo(uint16 _dexId) external view returns (DexInfo memory);
    function getDexCount() external view returns (uint16);
    function getDexPair(uint16 _dexId) external view returns (address);
    function setDexPair(uint16 _dexId, address _pair) external;
    function getDexAllocation(uint16 _dexId) external view returns (uint8);
    function getTotalAllocation() external view returns (uint16);
    function isDexActive(uint16 _dexId) external view returns (bool);
    function getLiquidityManager() external view returns (address);
    function setLiquidityManager(address _liquidityManager) external;
    function validateDexRouter(address _router) external view returns (bool);
    function validateDexFactory(address _factory) external view returns (bool);
    function getAllActiveDexes() external view returns (uint16[] memory);
}
