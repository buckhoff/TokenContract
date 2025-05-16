// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ILiquidityProvisioner
 * @dev Interface for the LiquidityProvisioner contract
 */
interface ILiquidityProvisioner {
    // Events
    event LiquidityProvided(uint16 indexed dexId, uint96 tokenAmount, uint96 stablecoinAmount, uint96 lpTokens);
    event LiquidityRemoved(uint16 indexed dexId, uint96 tokenAmount, uint96 stablecoinAmount, uint96 lpTokens);
    event OwnershipRenounced(uint16 indexed dexId);
    event LpTokensStaked(uint16 indexed dexId, uint96 amount);
    event LpRewardsClaimed(uint16 indexed dexId, uint96 amount);

    // Functions
    function createLiquidityAtTargetPrice(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount
    ) external;

    function createAndRenounceLiquidity(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount,
        address _deadAddress
    ) external;

    function addLiquidityToDex(
        uint16 _dexId,
        uint96 _tokenAmount,
        uint96 _stablecoinAmount
    ) external returns (uint96 tokenAmountAdded, uint96 stablecoinAmountAdded, uint96 liquidity);

    function removeLiquidityFromDex(
        uint16 _dexId,
        uint96 _lpAmount,
        uint96 _minTokenAmount,
        uint96 _minStablecoinAmount
    ) external returns (uint96 tokenAmount, uint96 stablecoinAmount);

    function stakeLPTokens(uint16 _dexId, uint96 _amount) external;
    function unstakeLPTokens(uint16 _dexId, uint96 _amount) external;
    function claimLPRewards(uint16 _dexId) external;
    function renounceLpOwnership(uint16 _dexId, address _deadAddress) external;
    function getLpTokenBalance(uint16 _dexId) external view returns (uint96);
    function getDexRegistry() external view returns (address);
    function setDexRegistry(address _registry) external;
    function getTokenAndStablecoin() external view returns (address token, address stablecoin);
    function setToken(address _token) external;
    function setStablecoin(address _stablecoin) external;
    function getTargetPrice() external view returns (uint96 _targetPrice);
}

