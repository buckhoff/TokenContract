// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ILiquidityManager
 * @dev Interface for the LiquidityManager contract
 */
interface ILiquidityManager {
    // Phase details
    struct LiquidityPhase {
        uint96 tokenAmount;
        uint96 stablecoinAmount;
        uint96 targetPrice; // Target price in USD (scaled by 1e6)
        uint96 deadline;
        bool executed;
    }

    // Events
    event LiquidityPhaseAdded(uint96 indexed phaseId, uint96 tokenAmount, uint96 stablecoinAmount, uint96 targetPrice);
    event LiquidityPhaseExecuted(uint96 indexed phaseId, uint96 tokenAmount, uint96 stablecoinAmount);
    event TargetPriceUpdated(uint96 newTargetPrice);
    event PriceFloorUpdated(uint96 newPriceFloor);
    event SwapExecuted(uint16 indexed dexId, uint96 amountIn, uint96 amountOut, bool isTokenToStable);

    // Functions
    function addLiquidityPhase(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount,
        uint96 _targetPrice,
        uint40 _deadline
    ) external returns (uint96);

    function executeNextLiquidityPhase() external;
    function deployLiquidityInPhases(uint96[] calldata _phaseIds) external;
    function swapWithPriceFloor(
        uint16 _dexId,
        uint96 _amountIn,
        uint96 _minAmountOut,
        bool _isTokenToStable
    ) external returns (uint96);

    function updateTargetPrice(uint96 _newTargetPrice) external;
    function updatePriceFloor(uint96 _newPriceFloor) external;

    function getDexRegistry() external view returns (address);
    function setDexRegistry(address _registry) external;
    function getLiquidityProvisioner() external view returns (address);
    function setLiquidityProvisioner(address _provisioner) external;
    function getLiquidityRebalancer() external view returns (address);
    function setLiquidityRebalancer(address _rebalancer) external;
    function getTokenPriceFeed() external view returns (address);
    function setTokenPriceFeed(address _priceFeed) external;

    function getPhaseCount() external view returns (uint96);
    function getPhaseDetails(uint96 _phaseId) external view returns (LiquidityPhase memory);
    function getTokenPrice() external view returns (uint96);
}