// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Interfaces/IDexRegistry.sol";

/**
 * @title DexRegistry
 * @dev Registry for managing DEX information and allocations
 */
contract DexRegistry is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable,
IDexRegistry
{
    // DEX details
    DexInfo[] public dexes;

    // Mapping of supported DEX routers
    mapping(address => bool) public supportedRouters;

    // Mapping of supported DEX factories
    mapping(address => bool) public supportedFactories;

    // Liquidity Manager reference
    address public liquidityManager;

    // Events
    event DexAdded(uint16 indexed dexId, string name, address router, uint8 allocationPercentage);
    event DexUpdated(uint16 indexed dexId, string name, address router, uint8 allocationPercentage);
    event DexActivated(uint16 indexed dexId);
    event DexDeactivated(uint16 indexed dexId);
    event LiquidityManagerSet(address indexed manager);
    event RouterSupported(address indexed router, bool supported);
    event FactorySupported(address indexed factory, bool supported);

    // Errors
    error ZeroAddress();
    error InvalidDexId(uint16 dexId);
    error AllocationExceeds100Percent();
    error NameCannotBeEmpty();
    error NotLiquidityManager();
    error PairAlreadySet();
    error DexNotActive();

    /**
     * @dev Modifier to ensure caller is the Liquidity Manager
     */
    modifier onlyLiquidityManager() {
        if (msg.sender != liquidityManager) revert NotLiquidityManager();
        _;
    }

    /**
     * @dev Constructor
     */
    //constructor() {
    //    _disableInitializers();
    //}

    /**
     * @dev Initializes the contract
     */
    function initialize() initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Adds a new DEX to the registry
     * @param _name Name of the DEX
     * @param _router Router contract address
     * @param _factory Factory contract address
     * @param _stakingRewards Staking rewards contract address (optional)
     * @param _allocationPercentage Percentage allocation (100 = 1%)
     * @return dexId ID of the added DEX
     */
    function addDex(
        string memory _name,
        address _router,
        address _factory,
        address _stakingRewards,
        uint8 _allocationPercentage
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant returns (uint16) {
        if (_router == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        if (bytes(_name).length == 0) revert NameCannotBeEmpty();

        // Validate allocation percentage
        uint8 totalAllocation = _allocationPercentage;
        for (uint16 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                totalAllocation += dexes[i].allocationPercentage;
            }
        }
        if (totalAllocation > 10000) revert AllocationExceeds100Percent();

        // Add the DEX
        uint16 dexId = uint16(dexes.length);
        dexes.push(DexInfo({
            name: _name,
            router: _router,
            factory: _factory,
            pair: address(0), // Will be set when adding liquidity
            stakingRewards: _stakingRewards,
            allocationPercentage: _allocationPercentage,
            active: true
        }));

        // Add to supported routers and factories if not already supported
        if (!supportedRouters[_router]) {
            supportedRouters[_router] = true;
            emit RouterSupported(_router, true);
        }

        if (!supportedFactories[_factory]) {
            supportedFactories[_factory] = true;
            emit FactorySupported(_factory, true);
        }

        emit DexAdded(dexId, _name, _router, _allocationPercentage);

        return dexId;
    }

    /**
     * @dev Updates an existing DEX
     * @param _dexId ID of the DEX to update
     * @param _name New name of the DEX
     * @param _router New router contract address
     * @param _factory New factory contract address
     * @param _stakingRewards New staking rewards contract address
     * @param _allocationPercentage New percentage allocation
     */
    function updateDex(
        uint16 _dexId,
        string memory _name,
        address _router,
        address _factory,
        address _stakingRewards,
        uint8 _allocationPercentage
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        if (_router == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        if (bytes(_name).length == 0) revert NameCannotBeEmpty();

        DexInfo storage dex = dexes[_dexId];

        // Calculate new total allocation
        uint8 oldAllocation = dex.active ? dex.allocationPercentage : 0;
        uint8 totalAllocation = _allocationPercentage;

        for (uint16 i = 0; i < dexes.length; i++) {
            if (i != _dexId && dexes[i].active) {
                totalAllocation += dexes[i].allocationPercentage;
            }
        }

        if (totalAllocation > 10000) revert AllocationExceeds100Percent();

        // Update DEX info
        dex.name = _name;
        dex.router = _router;
        dex.factory = _factory;
        dex.stakingRewards = _stakingRewards;
        dex.allocationPercentage = _allocationPercentage;

        // Update supported routers and factories if needed
        if (!supportedRouters[_router]) {
            supportedRouters[_router] = true;
            emit RouterSupported(_router, true);
        }

        if (!supportedFactories[_factory]) {
            supportedFactories[_factory] = true;
            emit FactorySupported(_factory, true);
        }

        emit DexUpdated(_dexId, _name, _router, _allocationPercentage);
    }

    /**
     * @dev Activates a DEX
     * @param _dexId ID of the DEX to activate
     */
    function activateDex(uint16 _dexId) external onlyRole(Constants.ADMIN_ROLE) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);

        // Check if already active
        if (dexes[_dexId].active) return;

        // Check allocation percentage
        uint8 totalAllocation = dexes[_dexId].allocationPercentage;
        for (uint16 i = 0; i < dexes.length; i++) {
            if (i != _dexId && dexes[i].active) {
                totalAllocation += dexes[i].allocationPercentage;
            }
        }

        if (totalAllocation > 10000) revert AllocationExceeds100Percent();

        dexes[_dexId].active = true;
        emit DexActivated(_dexId);
    }

    /**
     * @dev Deactivates a DEX
     * @param _dexId ID of the DEX to deactivate
     */
    function deactivateDex(uint16 _dexId) external onlyRole(Constants.ADMIN_ROLE) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);

        // Check if already inactive
        if (!dexes[_dexId].active) return;

        dexes[_dexId].active = false;
        emit DexDeactivated(_dexId);
    }

    /**
     * @dev Gets information about a DEX
     * @param _dexId ID of the DEX
     * @return DEX information
     */
    function getDexInfo(uint16 _dexId) external view returns (DexInfo memory) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        return dexes[_dexId];
    }

    /**
     * @dev Gets the number of DEXes
     * @return Number of DEXes
     */
    function getDexCount() external view returns (uint16) {
        return uint16(dexes.length);
    }

    /**
     * @dev Gets the pair address for a DEX
     * @param _dexId ID of the DEX
     * @return Pair address
     */
    function getDexPair(uint16 _dexId) external view returns (address) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        return dexes[_dexId].pair;
    }

    /**
     * @dev Sets the pair address for a DEX
     * @param _dexId ID of the DEX
     * @param _pair Pair address
     */
    function setDexPair(uint16 _dexId, address _pair) external onlyLiquidityManager {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        if (!dexes[_dexId].active) revert DexNotActive();
        if (dexes[_dexId].pair != address(0)) revert PairAlreadySet();

        dexes[_dexId].pair = _pair;
    }

    /**
     * @dev Gets the allocation percentage for a DEX
     * @param _dexId ID of the DEX
     * @return Allocation percentage
     */
    function getDexAllocation(uint16 _dexId) external view returns (uint8) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        return dexes[_dexId].allocationPercentage;
    }

    /**
     * @dev Gets the total allocation percentage across all active DEXes
     * @return Total allocation percentage
     */
    function getTotalAllocation() external view returns (uint16) {
        uint16 totalAllocation = 0;
        for (uint16 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                totalAllocation += dexes[i].allocationPercentage;
            }
        }
        return totalAllocation;
    }

    /**
     * @dev Checks if a DEX is active
     * @param _dexId ID of the DEX
     * @return Whether the DEX is active
     */
    function isDexActive(uint16 _dexId) external view returns (bool) {
        if (_dexId >= dexes.length) revert InvalidDexId(_dexId);
        return dexes[_dexId].active;
    }

    /**
     * @dev Gets the Liquidity Manager address
     * @return Liquidity Manager address
     */
    function getLiquidityManager() external view returns (address) {
        return liquidityManager;
    }

    /**
     * @dev Sets the Liquidity Manager address
     * @param _liquidityManager New Liquidity Manager address
     */
    function setLiquidityManager(address _liquidityManager) external onlyRole(Constants.ADMIN_ROLE) {
        if (_liquidityManager == address(0)) revert ZeroAddress();
        liquidityManager = _liquidityManager;
        emit LiquidityManagerSet(_liquidityManager);
    }

    /**
     * @dev Validates if a router is supported
     * @param _router Router address to validate
     * @return Whether the router is supported
     */
    function validateDexRouter(address _router) external view returns (bool) {
        return supportedRouters[_router];
    }

    /**
     * @dev Validates if a factory is supported
     * @param _factory Factory address to validate
     * @return Whether the factory is supported
     */
    function validateDexFactory(address _factory) external view returns (bool) {
        return supportedFactories[_factory];
    }

    /**
     * @dev Gets all active DEX IDs
     * @return Array of active DEX IDs
     */
    function getAllActiveDexes() external view returns (uint16[] memory) {
        uint16 activeCount = 0;

        // Count active DEXes
        for (uint16 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                activeCount++;
            }
        }

        // Create and populate array
        uint16[] memory activeDexes = new uint16[](activeCount);
        uint16 index = 0;

        for (uint16 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                activeDexes[index] = i;
                index++;
            }
        }

        return activeDexes;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.DEX_REGISTRY_NAME);
    }
}
