// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Interfaces/ILiquidityProvisioner.sol";
import "./Interfaces/IDexRegistry.sol";

// Interfaces for DEX interactions
interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint96 amountADesired,
        uint96 amountBDesired,
        uint96 amountAMin,
        uint96 amountBMin,
        address to,
        uint40 deadline
    ) external returns (uint96 amountA, uint96 amountB, uint96 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint96 liquidity,
        uint96 amountAMin,
        uint96 amountBMin,
        address to,
        uint96 deadline
    ) external returns (uint96 amountA, uint96 amountB);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint96);
    function balanceOf(address owner) external view returns (uint96);
    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
}

interface IStakingRewards {
    function stake(uint96 amount) external;
    function withdraw(uint96 amount) external;
    function getReward() external;
    function earned(address account) external view returns (uint96);
}

/**
 * @title LiquidityProvisioner
 * @dev Handles adding and removing liquidity to/from DEXs and manages LP tokens
 */
contract LiquidityProvisioner is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable,
ILiquidityProvisioner
{
    // Primary token and stablecoin
    ERC20Upgradeable public token;
    ERC20Upgradeable public stablecoin;

    // Interface to DEX registry
    IDexRegistry public dexRegistry;

    // LP token balance tracking
    mapping(uint16 => uint256) public dexLpTokenBalance;

    // LP token ownership status
    mapping(uint16 => bool) public dexLpOwnershipRenounced;

    // Target price for token in USD (scaled by 1e6)
    uint96 public targetPrice;

    event DetailedLiquidityProvided(uint16 dexId, uint96 tokenAdded, uint96 stableAdded, uint96 liquidity);
    // Error declarations
    error ZeroAddress();
    error InvalidDexId(uint16 dexId);
    error DexNotActive(uint16 dexId);
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error ApprovalFailed();
    error LiquidityAddFailed();
    error LiquidityRemoveFailed();
    error StakingFailed();
    error NoLpTokensToStake();
    error NoLpTokensToRenounce();
    error AlreadyRenounced();
    error NotOwner();
    error UnableToDetermineTokenOrder();

    /**
     * @dev Initializer
     * @param _token The platform token address
     * @param _stablecoin The stablecoin address
     * @param _dexRegistry The DEX registry address
     * @param _initialTargetPrice Initial target price for liquidity
     */
    function initialize(
        address _token,
        address _stablecoin,
        address _dexRegistry,
        uint96 _initialTargetPrice
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        if (_token == address(0) || _stablecoin == address(0) || _dexRegistry == address(0)) revert ZeroAddress();
        if (_initialTargetPrice == 0) revert ZeroAmount();

        token = ERC20Upgradeable(_token);
        stablecoin = ERC20Upgradeable(_stablecoin);
        dexRegistry = IDexRegistry(_dexRegistry);
        targetPrice = _initialTargetPrice;

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
     * @dev Creates liquidity at the target price across all active DEXs
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     */
    function createLiquidityAtTargetPrice(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount
    ) public override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_tokenAmount == 0 || _stablecoinAmount == 0) revert ZeroAmount();

        // Ensure the contract has enough tokens
        if (token.balanceOf(address(this)) < _tokenAmount ||
            stablecoin.balanceOf(address(this)) < _stablecoinAmount) {
            revert InsufficientBalance();
        }

        // Get active DEXs
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();

        // Distribute liquidity across DEXs according to allocation percentages
        for (uint16 i = 0; i < activeDexes.length; i++) {
            uint16 dexId = activeDexes[i];
            IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(dexId);

            // Calculate allocation for this DEX
            uint96 dexTokenAmount = uint96((_tokenAmount * dex.allocationPercentage) / 10000);
            uint96 dexStablecoinAmount = uint96((_stablecoinAmount * dex.allocationPercentage) / 10000);

            if (dexTokenAmount > 0 && dexStablecoinAmount > 0) {
                (uint96 tokenAdded, uint96 stableAdded, uint96 liquidity) = addLiquidityToDex(
                    dexId,
                    dexTokenAmount,
                    dexStablecoinAmount
                );
                emit DetailedLiquidityProvided(dexId, tokenAdded, stableAdded, liquidity);
            }
        }
    }

    /**
     * @dev Creates and renounces ownership of liquidity
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     * @param _deadAddress Address to renounce to (typically 0xdead)
     */
    function createAndRenounceLiquidity(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount,
        address _deadAddress
    ) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_tokenAmount == 0 || _stablecoinAmount == 0) revert ZeroAmount();
        if (_deadAddress == address(0)) revert ZeroAddress();

        // First create the liquidity
        createLiquidityAtTargetPrice(_tokenAmount, _stablecoinAmount);

        // Then renounce ownership for each DEX
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();
        for (uint16 i = 0; i < activeDexes.length; i++) {
            uint16 dexId = activeDexes[i];
            if (!dexLpOwnershipRenounced[dexId]) {
                renounceLpOwnership(dexId, _deadAddress);
            }
        }
    }

    /**
     * @dev Adds liquidity to a specific DEX
     * @param _dexId ID of the DEX
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     * @return tokenAmountAdded Amount of tokens actually added
     * @return stablecoinAmountAdded Amount of stablecoin actually added
     * @return liquidity LP tokens received
     */
    function addLiquidityToDex(
        uint16 _dexId,
        uint96 _tokenAmount,
        uint96 _stablecoinAmount
    ) public override onlyRole(Constants.ADMIN_ROLE) nonReentrant returns (
        uint96 tokenAmountAdded,
        uint96 stablecoinAmountAdded,
        uint96 liquidity
    ) {
        if (_tokenAmount == 0 || _stablecoinAmount == 0) revert ZeroAmount();

        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert DexNotActive(_dexId);

        // Approve router to spend tokens
        if (!token.approve(dex.router, _tokenAmount)) revert ApprovalFailed();
        if (!stablecoin.approve(dex.router, _stablecoinAmount)) revert ApprovalFailed();

        // Add liquidity
        try IUniswapV2Router(dex.router).addLiquidity(
            address(token),
            address(stablecoin),
            _tokenAmount,
            _stablecoinAmount,
            0, // Accept any amount of tokens
            0, // Accept any amount of stablecoin
            address(this),
            uint40(block.timestamp + 1800) // 30 minutes deadline
        ) returns (uint96 amountA, uint96 amountB, uint96 liq) {
            tokenAmountAdded = amountA;
            stablecoinAmountAdded = amountB;
            liquidity = liq;
        } catch {
            revert LiquidityAddFailed();
        }

        // Update pair address if it's not set yet
        if (dex.pair == address(0)) {
            address pair = IUniswapV2Factory(dex.factory).getPair(address(token), address(stablecoin));
            if (pair != address(0)) {
                dexRegistry.setDexPair(_dexId, pair);
            }
        }

        // Update LP token balance
        dexLpTokenBalance[_dexId] += liquidity;

        emit LiquidityProvided(_dexId, tokenAmountAdded, stablecoinAmountAdded, liquidity);
        return (tokenAmountAdded, stablecoinAmountAdded, liquidity);
    }

    /**
     * @dev Removes liquidity from a specific DEX
     * @param _dexId ID of the DEX
     * @param _lpAmount Amount of LP tokens to remove
     * @param _minTokenAmount Minimum token amount to receive
     * @param _minStablecoinAmount Minimum stablecoin amount to receive
     * @return tokenAmount Token amount received
     * @return stablecoinAmount Stablecoin amount received
     */
    function removeLiquidityFromDex(
        uint16 _dexId,
        uint96 _lpAmount,
        uint96 _minTokenAmount,
        uint96 _minStablecoinAmount
    ) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant returns (
        uint96 tokenAmount,
        uint96 stablecoinAmount
    ) {
        if (_lpAmount == 0) revert ZeroAmount();

        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert DexNotActive(_dexId);
        if (dex.pair == address(0)) revert ZeroAddress();

        // Check LP token balance
        if (dexLpTokenBalance[_dexId] < _lpAmount) revert InsufficientBalance();

        // Approve router to spend LP tokens
        if (!IUniswapV2Pair(dex.pair).approve(dex.router, _lpAmount)) revert ApprovalFailed();

        // Remove liquidity
        try IUniswapV2Router(dex.router).removeLiquidity(
            address(token),
            address(stablecoin),
            _lpAmount,
            _minTokenAmount,
            _minStablecoinAmount,
            address(this),
            uint96(block.timestamp + 1800) // 30 minutes deadline
        ) returns (uint96 amountA, uint96 amountB) {
            tokenAmount = amountA;
            stablecoinAmount = amountB;
        } catch {
            revert LiquidityRemoveFailed();
        }

        // Update LP token balance
        dexLpTokenBalance[_dexId] -= _lpAmount;

        emit LiquidityRemoved(_dexId, tokenAmount, stablecoinAmount, _lpAmount);
        return (tokenAmount, stablecoinAmount);
    }

    /**
     * @dev Stakes LP tokens in a staking rewards contract
     * @param _dexId ID of the DEX
     * @param _amount Amount of LP tokens to stake
     */
    function stakeLPTokens(uint16 _dexId, uint96 _amount) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert DexNotActive(_dexId);
        if (dex.stakingRewards == address(0)) revert ZeroAddress();

        // Ensure the pair exists
        if (dex.pair == address(0)) revert ZeroAddress();

        // Check LP token balance
        IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);
        uint96 lpBalance = uint96(pair.balanceOf(address(this)));
        if (lpBalance < _amount) revert NoLpTokensToStake();

        // Approve staking contract
        if (!pair.approve(dex.stakingRewards, _amount)) revert ApprovalFailed();

        // Stake LP tokens
        try IStakingRewards(dex.stakingRewards).stake(_amount) {
            // Success
        } catch {
            revert StakingFailed();
        }

        // Update LP token balance tracking
        dexLpTokenBalance[_dexId] = lpBalance - _amount;

        emit LpTokensStaked(_dexId, _amount);
    }

    /**
     * @dev Unstakes LP tokens from a staking rewards contract
     * @param _dexId ID of the DEX
     * @param _amount Amount of LP tokens to unstake
     */
    function unstakeLPTokens(uint16 _dexId, uint96 _amount) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert DexNotActive(_dexId);
        if (dex.stakingRewards == address(0)) revert ZeroAddress();

        // Unstake LP tokens
        try IStakingRewards(dex.stakingRewards).withdraw(_amount) {
            // Success
        } catch {
            revert StakingFailed();
        }

        // Update LP token balance tracking
        dexLpTokenBalance[_dexId] += _amount;
    }

    /**
     * @dev Claims rewards from staking LP tokens
     * @param _dexId ID of the DEX
     */
    function claimLPRewards(uint16 _dexId) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (dex.stakingRewards == address(0)) revert ZeroAddress();

        // Check earned rewards
        uint96 earned = IStakingRewards(dex.stakingRewards).earned(address(this));
        if (earned == 0) revert ZeroAmount();

        // Claim rewards
        try IStakingRewards(dex.stakingRewards).getReward() {
            // Success
        } catch {
            revert StakingFailed();
        }

        emit LpRewardsClaimed(_dexId, earned);
    }

    /**
     * @dev Renounces ownership of LP tokens by sending them to a dead address
     * @param _dexId ID of the DEX
     * @param _deadAddress Address to send LP tokens to
     */
    function renounceLpOwnership(uint16 _dexId, address _deadAddress) public override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_deadAddress == address(0)) revert ZeroAddress();
        if (dexLpOwnershipRenounced[_dexId]) revert AlreadyRenounced();

        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert DexNotActive(_dexId);

        // Ensure the pair exists
        if (dex.pair == address(0)) revert ZeroAddress();

        // Get LP token balance
        IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);
        uint96 lpBalance = uint96(pair.balanceOf(address(this)));

        if (lpBalance == 0) revert NoLpTokensToRenounce();

        // Send LP tokens to dead address
        if (!pair.transfer(_deadAddress, lpBalance)) revert TransferFailed();

        // Mark as renounced
        dexLpOwnershipRenounced[_dexId] = true;

        emit OwnershipRenounced(_dexId);
    }

    /**
     * @dev Get LP token balance for a DEX
     * @param _dexId ID of the DEX
     * @return LP token balance
     */
    function getLpTokenBalance(uint16 _dexId) external view override returns (uint96) {
        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);

        if (dex.pair != address(0)) {
            return uint96(IUniswapV2Pair(dex.pair).balanceOf(address(this)));
        }

        return 0;
    }

    /**
     * @dev Get DEX registry address
     * @return Registry address
     */
    function getDexRegistry() external view override returns (address) {
        return address(dexRegistry);
    }

    /**
     * @dev Set DEX registry address
     * @param _registry New registry address
     */
    function setDexRegistry(address _registry) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_registry == address(0)) revert ZeroAddress();
        dexRegistry = IDexRegistry(_registry);
    }

    /**
     * @dev Get token and stablecoin addresses
     * @return token Token address
     * @return stablecoin Stablecoin address
     */
    function getTokenAndStablecoin() external view override returns (address, address) {
        return (address(token), address(stablecoin));
    }

    /**
     * @dev Set token address
     * @param _token New token address
     */
    function setToken(address _token) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        token = ERC20Upgradeable(_token);
    }

    /**
     * @dev Set stablecoin address
     * @param _stablecoin New stablecoin address
     */
    function setStablecoin(address _stablecoin) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_stablecoin == address(0)) revert ZeroAddress();
        stablecoin = ERC20Upgradeable(_stablecoin);
    }

    /**
     * @dev Set the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.LIQUIDITY_PROVISIONER_NAME);
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_token == address(token) || _token == address(stablecoin)) revert NotOwner();

        // Prevent recovery of LP tokens from any active DEX
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();
        for (uint16 i = 0; i < activeDexes.length; i++) {
            IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(activeDexes[i]);
            if (dex.pair == _token) revert NotOwner();
        }

        ERC20Upgradeable recoveryToken = ERC20Upgradeable(_token);
        uint256 balance = recoveryToken.balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        if (!recoveryToken.transfer(owner(), balance)) revert TransferFailed();
    }

    function getTargetPrice() external override view returns (uint96 _targetPrice){
        _targetPrice=targetPrice;
    }
}