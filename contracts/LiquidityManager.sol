// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Interfaces/ILiquidityManager.sol";
import "./Interfaces/IDexRegistry.sol";
import "./Interfaces/ILiquidityProvisioner.sol";
import "./Interfaces/ILiquidityRebalancer.sol";

interface ITokenPriceFeed {
    function getTokenPrice(address token, address stablecoin) external view returns (uint96);
}

// Interface to router
interface IRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @title LiquidityManager
 * @dev Core contract that coordinates between DEX registry, provisioner, and rebalancer
 */
contract LiquidityManager is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable,
ILiquidityManager
{
    // Component addresses
    address public dexRegistry;
    address public liquidityProvisioner;
    address public liquidityRebalancer;
    address public tokenPriceFeed;

    // Tokens
    ERC20Upgradeable public token;
    ERC20Upgradeable public stablecoin;

    // Liquidity phase details
    mapping(uint96 => LiquidityPhase) public liquidityPhases;
    uint96 private _phaseIdCounter;

    // Target price and floor price
    uint96 public targetPrice;
    uint96 public priceFloor;

    // Error declarations
    error ZeroAddress();
    error InvalidPhaseId(uint96 phaseId);
    error InvalidTargetPrice();
    error InvalidPriceFloor();
    error NoAvailablePhases();
    error PhaseDeadlinePassed(uint96 phaseId, uint96 deadline);
    error PhaseAlreadyExecuted(uint96 phaseId);
    error InvalidDexId(uint16 dexId);
    error DexNotActive(uint16 dexId);
    error ZeroAmount();
    error BelowMinReturn(uint96 received, uint96 minimum);
    error PriceFloorBreached(uint96 currentPrice, uint96 floor);
    error TransferFailed();
    error SwapFailed();
    error CannotRecoverCoreTokens();
    error NoTokensToRecover();

    /**
     * @dev Initializer
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @param _targetPrice Initial target price
     */
    function initialize(
        address _token,
        address _stablecoin,
        uint96 _targetPrice
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        if (_token == address(0) || _stablecoin == address(0)) revert ZeroAddress();
        if (_targetPrice == 0) revert InvalidTargetPrice();

        token = ERC20Upgradeable(_token);
        stablecoin = ERC20Upgradeable(_stablecoin);
        targetPrice = _targetPrice;
        priceFloor = _targetPrice / 2; // Default price floor at 50% of target price
        _phaseIdCounter = 1;

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
     * @dev Adds a new liquidity deployment phase
     * @param _tokenAmount Amount of tokens to deploy
     * @param _stablecoinAmount Amount of stablecoin to deploy
     * @param _targetPrice Target price for this phase
     * @param _deadline Deadline for execution
     * @return phaseId ID of the added phase
     */
    function addLiquidityPhase(
        uint96 _tokenAmount,
        uint96 _stablecoinAmount,
        uint96 _targetPrice,
        uint40 _deadline
    ) external override onlyRole(Constants.ADMIN_ROLE) returns (uint96) {
        if (_tokenAmount == 0 || _stablecoinAmount == 0) revert ZeroAmount();
        if (_targetPrice == 0) revert InvalidTargetPrice();
        if (_deadline <= block.timestamp) revert PhaseDeadlinePassed(0, _deadline);

        uint96 phaseId = _phaseIdCounter++;

        liquidityPhases[phaseId] = LiquidityPhase({
            tokenAmount: _tokenAmount,
            stablecoinAmount: _stablecoinAmount,
            targetPrice: _targetPrice,
            deadline: _deadline,
            executed: false
        });

        emit LiquidityPhaseAdded(phaseId, _tokenAmount, _stablecoinAmount, _targetPrice);
        return phaseId;
    }

    /**
     * @dev Executes the next pending liquidity phase
     */
    function executeNextLiquidityPhase() external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        uint96 phaseId = _findNextPendingPhase();
        if (phaseId == 0) revert NoAvailablePhases();

        LiquidityPhase storage phase = liquidityPhases[phaseId];
        if (phase.executed) revert PhaseAlreadyExecuted(phaseId);
        if (block.timestamp > phase.deadline) revert PhaseDeadlinePassed(phaseId, phase.deadline);

        // Set the target price for this phase
        targetPrice = phase.targetPrice;
        emit TargetPriceUpdated(targetPrice);

        // Ensure this contract has the tokens
        if (token.balanceOf(address(this)) < phase.tokenAmount) revert ZeroAmount();
        if (stablecoin.balanceOf(address(this)) < phase.stablecoinAmount) revert ZeroAmount();

        // Transfer tokens to liquidity provisioner if needed
        if (liquidityProvisioner != address(0)) {
            // Approve tokens for the provisioner
            token.approve(liquidityProvisioner, phase.tokenAmount);
            stablecoin.approve(liquidityProvisioner, phase.stablecoinAmount);

            // Execute via the provisioner
            ILiquidityProvisioner(liquidityProvisioner).createLiquidityAtTargetPrice(
                phase.tokenAmount,
                phase.stablecoinAmount
            );
        } else {
            // Direct implementation if provisioner not set
            _addLiquidityDirect(phase.tokenAmount, phase.stablecoinAmount);
        }

        // Mark as executed
        phase.executed = true;

        emit LiquidityPhaseExecuted(phaseId, phase.tokenAmount, phase.stablecoinAmount);
    }

    /**
     * @dev Deploys liquidity in phases
     * @param _phaseIds Array of phase IDs to execute
     */
    function deployLiquidityInPhases(uint96[] calldata _phaseIds) external override onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        for (uint256 i = 0; i < _phaseIds.length; i++) {
            uint96 phaseId = _phaseIds[i];
            if (phaseId == 0 || phaseId >= _phaseIdCounter) revert InvalidPhaseId(phaseId);

            LiquidityPhase storage phase = liquidityPhases[phaseId];
            if (phase.executed) revert PhaseAlreadyExecuted(phaseId);
            if (block.timestamp > phase.deadline) revert PhaseDeadlinePassed(phaseId, phase.deadline);

            // Set the target price for this phase
            targetPrice = phase.targetPrice;
            emit TargetPriceUpdated(targetPrice);

            // Ensure this contract has the tokens
            if (token.balanceOf(address(this)) < phase.tokenAmount) revert ZeroAmount();
            if (stablecoin.balanceOf(address(this)) < phase.stablecoinAmount) revert ZeroAmount();

            // Execute via the provisioner if available
            if (liquidityProvisioner != address(0)) {
                // Approve tokens for the provisioner
                token.approve(liquidityProvisioner, phase.tokenAmount);
                stablecoin.approve(liquidityProvisioner, phase.stablecoinAmount);

                // Create liquidity
                ILiquidityProvisioner(liquidityProvisioner).createLiquidityAtTargetPrice(
                    phase.tokenAmount,
                    phase.stablecoinAmount
                );
            } else {
                // Direct implementation if provisioner not set
                _addLiquidityDirect(phase.tokenAmount, phase.stablecoinAmount);
            }

            // Mark as executed
            phase.executed = true;

            emit LiquidityPhaseExecuted(phaseId, phase.tokenAmount, phase.stablecoinAmount);
        }
    }

    /**
     * @dev Swaps tokens with price floor protection
     * @param _dexId ID of the DEX to use
     * @param _amountIn Amount of input tokens
     * @param _minAmountOut Minimum amount of output tokens
     * @param _isTokenToStable Whether swapping from token to stablecoin
     * @return amountOut Amount of tokens received
     */
    function swapWithPriceFloor(
        uint16 _dexId,
        uint96 _amountIn,
        uint96 _minAmountOut,
        bool _isTokenToStable
    ) external override nonReentrant returns (uint96 amountOut) {
        if (_amountIn == 0) revert ZeroAmount();

        // Check if DEX registry is set
        if (dexRegistry == address(0)) revert ZeroAddress();

        // Get DEX information
        IDexRegistry registry = IDexRegistry(dexRegistry);
        IDexRegistry.DexInfo memory dex = registry.getDexInfo(_dexId);

        if (!dex.active) revert DexNotActive(_dexId);
        if (dex.pair == address(0)) revert ZeroAddress();

        // Check price if swapping token to stablecoin (to enforce price floor)
        if (_isTokenToStable) {
        IPair pair = IPair(dex.pair);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();

        address token0 = pair.token0();
        bool isToken0 = address(token) == token0;

        uint112 tokenReserve = isToken0 ? reserve0 : reserve1;
        uint112 stablecoinReserve = isToken0 ? reserve1 : reserve0;

        // Calculate current price
        uint96 currentPrice = uint96((uint256(stablecoinReserve) * 1e18) / uint256(tokenReserve));

        // Ensure price is above floor
        if (currentPrice < priceFloor) revert PriceFloorBreached(currentPrice, priceFloor);

        // Transfer tokens from sender to contract
        if (!token.transferFrom(msg.sender, address(this), _amountIn)) revert TransferFailed();

        // Approve router
        if (!token.approve(dex.router, _amountIn)) revert TransferFailed();

        // Setup path
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(stablecoin);

        // Execute swap
        try IRouter(dex.router).swapExactTokensForTokens(
        _amountIn,
        _minAmountOut,
        path,
        msg.sender,
        block.timestamp + 1800 // 30 minutes
        ) returns (uint256[] memory amounts) {
        amountOut = uint96(amounts[1]);
        } catch {
        revert SwapFailed();
        }
        } else {
        // Swapping stablecoin to token (no price floor check needed)

        // Transfer stablecoin from sender to contract
        if (!stablecoin.transferFrom(msg.sender, address(this), _amountIn)) revert TransferFailed();

        // Approve router
        if (!stablecoin.approve(dex.router, _amountIn)) revert TransferFailed();

        // Setup path
        address[] memory path = new address[](2);
        path[0] = address(stablecoin);
        path[1] = address(token);

        // Execute swap
        try IRouter(dex.router).swapExactTokensForTokens(
        _amountIn,
        _minAmountOut,
        path,
        msg.sender,
        block.timestamp + 1800 // 30 minutes
        ) returns (uint256[] memory amounts) {
        amountOut = uint96(amounts[1]);
        } catch {
        revert SwapFailed();
        }
        }

        if (amountOut < _minAmountOut) revert BelowMinReturn(amountOut, _minAmountOut);

        emit SwapExecuted(_dexId, _amountIn, amountOut, _isTokenToStable);

    return amountOut;
    }

    /**
     * @dev Updates the target token price
     * @param _newTargetPrice New target price in USD
     */
    function updateTargetPrice(uint96 _newTargetPrice) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_newTargetPrice == 0) revert InvalidTargetPrice();

        targetPrice = _newTargetPrice;

        emit TargetPriceUpdated(_newTargetPrice);
    }

    /**
     * @dev Updates the price floor for swaps
     * @param _newPriceFloor New price floor in USD
     */
    function updatePriceFloor(uint96 _newPriceFloor) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_newPriceFloor == 0) revert InvalidPriceFloor();
        if (_newPriceFloor > targetPrice) revert InvalidPriceFloor();

        priceFloor = _newPriceFloor;

        emit PriceFloorUpdated(_newPriceFloor);
    }

    /**
     * @dev Returns the next pending phase ID
     * @return Next pending phase ID or 0 if none
     */
    function _findNextPendingPhase() internal view returns (uint96) {
        for (uint96 i = 1; i < _phaseIdCounter; i++) {
            if (!liquidityPhases[i].executed && block.timestamp <= liquidityPhases[i].deadline) {
                return i;
            }
        }

        return 0; // No pending phases
    }

    /**
     * @dev Direct implementation of adding liquidity if no provisioner set
     * This is a fallback function with minimal implementation
     */
    function _addLiquidityDirect(uint96 _tokenAmount, uint96 _stablecoinAmount) internal {
        // This is a simplified version - in a real implementation,
        // we would need to distribute liquidity across DEXes based on allocation
        // Just an emergency fallback if the provisioner is not available

        if (dexRegistry == address(0)) {
            return; // Can't do anything without DEX registry
        }

        // Get first active DEX
        IDexRegistry registry = IDexRegistry(dexRegistry);
        uint16[] memory activeDexes = registry.getAllActiveDexes();

        if (activeDexes.length == 0) {
            return; // No active DEXes
        }

        IDexRegistry.DexInfo memory dex = registry.getDexInfo(activeDexes[0]);

        if (dex.router == address(0)) {
            return; // Invalid router
        }

        // Approve router
        token.approve(dex.router, _tokenAmount);
        stablecoin.approve(dex.router, _stablecoinAmount);

        // Add liquidity directly (simplified fallback)
        try IRouter(dex.router).addLiquidity(
        address(token),
        address(stablecoin),
        _tokenAmount,
        _stablecoinAmount,
        0, // Accept any token amount
        0, // Accept any stablecoin amount
        address(this),
        block.timestamp + 1800 // 30 minutes
        ) {
        // Success - no additional action needed
        } catch {
        // Failed - but this is fallback mode, so we don't revert
        }
    }

    /**
     * @dev Get the phase count
     * @return Number of phases
     */
    function getPhaseCount() external view override returns (uint96) {
        return _phaseIdCounter - 1;
    }

    /**
     * @dev Get phase details
     * @param _phaseId ID of the phase
     * @return Phase details
     */
    function getPhaseDetails(uint96 _phaseId) external view override returns (LiquidityPhase memory) {
        if (_phaseId == 0 || _phaseId >= _phaseIdCounter) revert InvalidPhaseId(_phaseId);
        return liquidityPhases[_phaseId];
    }

    /**
     * @dev Get current token price from DEXes
     * If token price feed is set, use that instead
     */
    function getTokenPrice() external view override returns (uint96) {
        // Try token price feed first if available
        if (tokenPriceFeed != address(0)) {
            try ITokenPriceFeed(tokenPriceFeed).getTokenPrice(address(token), address(stablecoin)) returns (uint96 price) {
                return price;
            } catch {
                // Fall through to DEX price if price feed fails
            }
        }

        // If no price feed or it failed, calculate from DEXes
        if (dexRegistry != address(0)) {
            IDexRegistry registry = IDexRegistry(dexRegistry);
            uint16[] memory activeDexes = registry.getAllActiveDexes();

            if (activeDexes.length == 0) {
                return targetPrice; // Return target price if no DEXes
            }

            uint96 totalPrice = 0;
            uint16 validPrices = 0;

            for (uint16 i = 0; i < activeDexes.length; i++) {
                IDexRegistry.DexInfo memory dex = registry.getDexInfo(activeDexes[i]);

                if (dex.pair != address(0)) {

                    IPair pair = IPair(dex.pair);
                    (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();

                    address token0 = pair.token0();
                    bool isToken0 = address(token) == token0;

                    uint112 tokenReserve = isToken0 ? reserve0 : reserve1;
                    uint112 stablecoinReserve = isToken0 ? reserve1 : reserve0;

                    if (tokenReserve > 0) {
                    uint96 price = uint96((uint256(stablecoinReserve) * 1e18) / uint256(tokenReserve));
                    totalPrice += price;
                    validPrices++;
                    }
                }
            }

            if (validPrices > 0) {
                return uint96(totalPrice / validPrices);
            }
        }

        // Default to target price if no other source available
        return targetPrice;
    }

    /**
     * @dev Set the DEX registry address
     * @param _registry Registry address
     */
    function setDexRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        if (_registry == address(0)) revert ZeroAddress();
        dexRegistry = _registry;
    }

    function getDexRegistry() external view returns (address){
        return dexRegistry;
    }
    
    /**
     * @dev Set the liquidity provisioner address
     * @param _provisioner Provisioner address
     */
    function setLiquidityProvisioner(address _provisioner) external onlyRole(Constants.ADMIN_ROLE) {
        liquidityProvisioner = _provisioner;
    }

    function getLiquidityProvisioner() external view returns (address){
        return liquidityProvisioner;
    }
    
    /**
     * @dev Set the liquidity rebalancer address
     * @param _rebalancer Rebalancer address
     */
    function setLiquidityRebalancer(address _rebalancer) external onlyRole(Constants.ADMIN_ROLE) {
        liquidityRebalancer = _rebalancer;
    }

    function getLiquidityRebalancer() external view returns (address){
        return liquidityRebalancer;
    }

    
    /**
     * @dev Set the token price feed address
     * @param _priceFeed Price feed address
     */
    function setTokenPriceFeed(address _priceFeed) external onlyRole(Constants.ADMIN_ROLE) {
        tokenPriceFeed = _priceFeed;
    }

    function getTokenPriceFeed() external view returns (address)
    {
        return tokenPriceFeed;
    }   
    
    /**
     * @dev Set the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.LIQUIDITY_MANAGER_NAME);
    } 
    
    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_token == address(token) || _token == address(stablecoin)) revert CannotRecoverCoreTokens();

        ERC20Upgradeable recoveryToken = ERC20Upgradeable(_token);
        uint256 balance = recoveryToken.balanceOf(address(this));
        if (balance == 0) revert NoTokensToRecover();

        recoveryToken.transfer(msg.sender, balance);
    }
}