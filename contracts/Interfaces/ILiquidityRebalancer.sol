// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ILiquidityRebalancer
 * @dev Interface for the LiquidityRebalancer contract
 */
interface ILiquidityRebalancer {
    // Events
    event RebalancingPerformed(uint40 timestamp);
    event LiquidityHealthWarning(uint16 indexed dexId, string reason);
    event PriceDeviation(uint16 dexId, uint16 deviation);

    // Functions
    function performRebalancing() external;
    function checkLiquidityHealth() external view returns (
        bool isHealthy,
        string[] memory warnings,
        uint16[] memory dexIds
    );
    function updateRebalancingParameters(
        uint16 _maxPriceDivergence,
        uint16 _maxReserveImbalance,
        uint40 _rebalanceCooldown
    ) external;
    function getLastRebalanceTime() external view returns (uint40);
    function getDexReserves(uint16 _dexId) external view returns (
        uint96 tokenReserve,
        uint96 stableReserve,
        uint96 currentPrice,
        uint96 lpSupply
    );
    function getPriceDeviation() external view returns (uint16);
    function isRebalancingNeeded() external view returns (bool);
    function getDexRegistry() external view returns (address);
    function setDexRegistry(address _registry) external;
    function getLiquidityProvisioner() external view returns (address);
    function setLiquidityProvisioner(address _provisioner) external;
    function getTokenPriceFeed() external view returns (address);
    function setTokenPriceFeed(address _priceFeed) external;
}
