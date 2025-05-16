// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Interfaces/ILiquidityRebalancer.sol";
import "./Interfaces/IDexRegistry.sol";
import "./Interfaces/ILiquidityProvisioner.sol";

// Interface to uniswap-like routers
interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// Structure to hold DEX price info
    struct DexPriceInfo {
        uint16 dexId;
        uint96 price;
        uint96 tokenReserve;
        uint96 stableReserve;
    }

interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function totalSupply() external view returns (uint96);
}

/**
 * @title LiquidityRebalancer
 * @dev Handles cross-DEX arbitrage and automated rebalancing
 */
contract LiquidityRebalancer is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable,
ILiquidityRebalancer
{
    // DEX management
    IDexRegistry public dexRegistry;
    ILiquidityProvisioner public liquidityProvisioner;

    // Rebalancing parameters
    uint16 public maxPriceDivergence;    // Maximum allowed price divergence between DEXes (100 = 1%)
    uint16 public maxReserveImbalance;   // Maximum allowed reserve imbalance (100 = 1%)
    uint40 public rebalanceCooldown;     // Cooldown period between rebalancing operations
    uint40 public lastRebalanceTime;     // Timestamp of last rebalance

    // Error declarations
    error ZeroAddress();
    error InvalidParameters();
    error CooldownActive();
    error InsufficientActiveExchanges();
    error TransferFailed();
    error ApprovalFailed();
    error SwapFailed();
    error InvalidDexId(uint16 dexId);
    error NotEnoughDivergence();
    error NotAuthorized();

    // Events
    event RebalancingParametersUpdated(uint16 maxPriceDivergence, uint16 maxReserveImbalance, uint40 rebalanceCooldown);
    event TokenPriceFeedSet(address indexed priceFeed);
    event LiquidityProvisionerSet(address indexed provisioner);
    event DexRegistrySet(address indexed registry);

    /**
     * @dev Initializer
     * @param _dexRegistry Address of the DEX registry
     * @param _liquidityProvisioner Address of the liquidity provisioner
     */
    function initialize(
        address _dexRegistry,
        address _liquidityProvisioner
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        if (_dexRegistry == address(0) || _liquidityProvisioner == address(0)) revert ZeroAddress();

        dexRegistry = IDexRegistry(_dexRegistry);
        liquidityProvisioner = ILiquidityProvisioner(_liquidityProvisioner);

        // Set default rebalancing parameters
        maxPriceDivergence = 500;  // 5% divergence
        maxReserveImbalance = 1000; // 10% imbalance
        rebalanceCooldown = 1 days;
        lastRebalanceTime = 0;

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
     * @dev Performs rebalancing across DEXes if needed
     * This will adjust liquidity to keep prices aligned
     */
    function performRebalancing() external override nonReentrant {
        // Check cooldown
        if (block.timestamp < lastRebalanceTime + rebalanceCooldown) revert CooldownActive();

        // Get active DEXes
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();
        if (activeDexes.length < 2) revert InsufficientActiveExchanges();

        // Collect price and reserve info
        DexPriceInfo[] memory dexInfos = new DexPriceInfo[](activeDexes.length);

        for (uint16 i = 0; i < activeDexes.length; i++) {
            uint16 dexId = activeDexes[i];
            IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(dexId);

            if (dex.pair == address(0)) continue;

            (uint96 tokenReserve, uint96 stableReserve, uint96 price,) = getDexReserves(dexId);

            dexInfos[i] = DexPriceInfo({
                dexId: dexId,
                price: price,
                tokenReserve: tokenReserve,
                stableReserve: stableReserve
            });
        }

        // Find DEX with highest and lowest price
        uint16 lowestPriceDexIndex = 0;
        uint16 highestPriceDexIndex = 0;
        uint96 lowestPrice = type(uint96).max;
        uint96 highestPrice = 0;

        for (uint16 i = 0; i < dexInfos.length; i++) {
            if (dexInfos[i].price > 0) {  // Ensure price is valid
                if (dexInfos[i].price < lowestPrice) {
                    lowestPrice = dexInfos[i].price;
                    lowestPriceDexIndex = i;
                }
                if (dexInfos[i].price > highestPrice) {
                    highestPrice = dexInfos[i].price;
                    highestPriceDexIndex = i;
                }
            }
        }

        // Calculate price divergence
        uint16 divergence;
        if (lowestPrice == 0) {
            divergence = 0;
        } else {
            divergence = uint16(((highestPrice - lowestPrice) * 10000) / lowestPrice);
        }

        // Emit event for monitoring
        emit PriceDeviation(dexInfos[highestPriceDexIndex].dexId, divergence);

        // Only rebalance if divergence exceeds threshold
        if (divergence <= maxPriceDivergence) revert NotEnoughDivergence();

        // Rebalancing strategy: Perform swaps to balance prices between DEXes
        DexPriceInfo memory highPriceDex = dexInfos[highestPriceDexIndex];
        DexPriceInfo memory lowPriceDex = dexInfos[lowestPriceDexIndex];

        // Get DEX info for router addresses
        IDexRegistry.DexInfo memory highDex = dexRegistry.getDexInfo(highPriceDex.dexId);
        IDexRegistry.DexInfo memory lowDex = dexRegistry.getDexInfo(lowPriceDex.dexId);

        // Get token and stablecoin addresses
        (address tokenAddress, address stablecoinAddress) = liquidityProvisioner.getTokenAndStablecoin();
        ERC20Upgradeable token = ERC20Upgradeable(tokenAddress);
        ERC20Upgradeable stablecoin = ERC20Upgradeable(stablecoinAddress);

        // Calculate optimal swap amount (simplified)
        // This formula aims to move prices by about 25% of the gap between them
        uint96 priceGap = uint96(highPriceDex.price - lowPriceDex.price);
        uint96 swapAmount = uint96((priceGap * highPriceDex.tokenReserve) / (highPriceDex.price * 4));

        // Cap swap amount to 10% of reserves to avoid excessive price impact
        uint96 maxSwap = uint96(highPriceDex.tokenReserve / 10);
        if (swapAmount > maxSwap) {
            swapAmount = maxSwap;
        }

        // Execute arbitrage if swap amount is significant
        if (swapAmount > 0) {
            // 1. Swap tokens to stablecoin on high price DEX
            if (!token.approve(highDex.router, swapAmount)) revert ApprovalFailed();

            address[] memory path1 = new address[](2);
            path1[0] = tokenAddress;
            path1[1] = stablecoinAddress;

            try ISwapRouter(highDex.router).swapExactTokensForTokens(
                swapAmount,
                0, // Accept any output amount
                path1,
                address(this),
                block.timestamp + 300 // 5 minute deadline
            ) returns (uint256[] memory amounts1) {
                // 2. Swap stablecoin back to tokens on low price DEX
                if (!stablecoin.approve(lowDex.router, amounts1[1])) revert ApprovalFailed();

                address[] memory path2 = new address[](2);
                path2[0] = stablecoinAddress;
                path2[1] = tokenAddress;

                try ISwapRouter(lowDex.router).swapExactTokensForTokens(
                    amounts1[1],
                    0, // Accept any output amount
                    path2,
                    address(this),
                    block.timestamp + 300 // 5 minute deadline
                ) {
                    // Success
                } catch {
                    revert SwapFailed();
                }
            } catch {
                revert SwapFailed();
            }
        }

        // Update rebalancing time
        lastRebalanceTime = uint40(block.timestamp);

        emit RebalancingPerformed(uint40(block.timestamp));
    }

/**
 * @dev Checks liquidity health across all DEXes
     * @return isHealthy Whether the liquidity is healthy
     * @return warnings Array of warning messages
     * @return dexIds Array of DEX IDs with warnings
     */
    function checkLiquidityHealth() external view override returns (
        bool isHealthy,
        string[] memory warnings,
        uint16[] memory dexIds
    ) {
        // Get active DEXes
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();

        // Count active DEXes with pairs
        uint16 activeDexCount = 0;
        for (uint16 i = 0; i < activeDexes.length; i++) {
            IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(activeDexes[i]);
            if (dex.active && dex.pair != address(0)) {
                activeDexCount++;
            }
        }

        // If no active DEXes, return false
        if (activeDexCount == 0) {
            warnings = new string[](1);
            warnings[0] = "No active DEXes with pairs";
            return (false, warnings, new uint16[](0));
        }

        // Initialize arrays for warnings
        warnings = new string[](activeDexCount * 3); // Max 3 warnings per DEX
        dexIds = new uint16[](activeDexCount * 3);

        uint16 warningCount = 0;
        isHealthy = true;

        // Check each active DEX
        for (uint16 i = 0; i < activeDexes.length; i++) {
            uint16 dexId = activeDexes[i];
            IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(dexId);

            if (dex.active && dex.pair != address(0)) {
                (uint96 tokenReserve, uint96 stableReserve, uint96 currentPrice,) = getDexReserves(dexId);

                // Check reserve sizes
                if (tokenReserve == 0 || stableReserve == 0) {
                    warnings[warningCount] = "Zero reserves detected";
                    dexIds[warningCount] = dexId;
                    warningCount++;
                    isHealthy = false;
                    continue;
                }

                // Get target price from liquidity provisioner
                uint96 targetPrice = 0;
                try liquidityProvisioner.getTargetPrice() returns (uint96 _targetPrice) {
                    targetPrice = _targetPrice;
                } catch {
                    // Default target price if can't get from provisioner
                    targetPrice = currentPrice;
                }

                // Check price deviation from target
                uint16 priceDeviation;
                if (currentPrice > targetPrice) {
                    priceDeviation = uint16(((currentPrice - targetPrice) * 10000) / targetPrice);
                } else {
                    priceDeviation = uint16(((targetPrice - currentPrice) * 10000) / targetPrice);
                }

                if (priceDeviation > maxPriceDivergence) {
                    warnings[warningCount] = "Price deviation exceeds threshold";
                    dexIds[warningCount] = dexId;
                    warningCount++;
                    isHealthy = false;
                }

                // Check token reserve imbalance
                uint96 tokenValue = uint96((tokenReserve * currentPrice) / 1e18);
                uint16 imbalance;

                if (tokenValue > stableReserve) {
                    imbalance = uint16(((tokenValue - stableReserve) * 10000) / tokenValue);
                } else {
                    imbalance = uint16(((stableReserve - tokenValue) * 10000) / stableReserve);
                }

                if (imbalance > maxReserveImbalance) {
                    warnings[warningCount] = "Reserve imbalance exceeds threshold";
                    dexIds[warningCount] = dexId;
                    warningCount++;
                    isHealthy = false;
                }
            }
        }

        // Trim arrays to actual warning count
        assembly {
            mstore(warnings, warningCount)
            mstore(dexIds, warningCount)
        }

        return (isHealthy, warnings, dexIds);
    }

/**
 * @dev Updates rebalancing parameters
     * @param _maxPriceDivergence Maximum allowed price divergence between DEXes (100 = 1%)
     * @param _maxReserveImbalance Maximum allowed reserve imbalance (100 = 1%)
     * @param _rebalanceCooldown Cooldown period between rebalancing operations
     */
    function updateRebalancingParameters(
        uint16 _maxPriceDivergence,
        uint16 _maxReserveImbalance,
        uint40 _rebalanceCooldown
    ) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_maxPriceDivergence == 0 || _maxReserveImbalance == 0) revert InvalidParameters();

        maxPriceDivergence = _maxPriceDivergence;
        maxReserveImbalance = _maxReserveImbalance;
        rebalanceCooldown = _rebalanceCooldown;

        emit RebalancingParametersUpdated(_maxPriceDivergence, _maxReserveImbalance, _rebalanceCooldown);
    }

/**
 * @dev Get the timestamp of the last rebalance
     * @return Last rebalance timestamp
     */
    function getLastRebalanceTime() external view override returns (uint40) {
        return lastRebalanceTime;
    }

/**
 * @dev Get DEX reserves and price information
     * @param _dexId ID of the DEX
     * @return tokenReserve Token reserve
     * @return stableReserve Stablecoin reserve
     * @return currentPrice Current token price
     * @return lpSupply Total LP token supply
     */
    function getDexReserves(uint16 _dexId) public view override returns (
        uint96 tokenReserve,
        uint96 stableReserve,
        uint96 currentPrice,
        uint96 lpSupply
    ) {
        IDexRegistry.DexInfo memory dex = dexRegistry.getDexInfo(_dexId);
        if (!dex.active) revert InvalidDexId(_dexId);

        if (dex.pair == address(0)) {
            return (0, 0, 0, 0);
        }

        // Get token and stablecoin
        (address tokenAddress, address stablecoinAddress) = liquidityProvisioner.getTokenAndStablecoin();

        IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);

        // Get reserves
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        // Determine token order
        address token0 = pair.token0();
        bool isToken0 = token0 == tokenAddress;

        tokenReserve = uint96(isToken0 ? reserve0 : reserve1);
        stableReserve = uint96(isToken0 ? reserve1 : reserve0);

        // Calculate current price (stablecoin/token)
        if (tokenReserve > 0) {
            // Scale by 1e18 for precision
            currentPrice = uint96((uint256(stableReserve) * 1e18) / uint256(tokenReserve));
        }

        // Get LP token supply
        lpSupply = pair.totalSupply();

        return (tokenReserve, stableReserve, currentPrice, lpSupply);
    }

/**
 * @dev Get the current price deviation percentage between DEXes
     * @return Deviation percentage (100 = 1%)
     */
    function getPriceDeviation() external view override returns (uint16) {
        uint16[] memory activeDexes = dexRegistry.getAllActiveDexes();
        if (activeDexes.length < 2) return 0;

        uint96 lowestPrice = type(uint96).max;
        uint96 highestPrice = 0;

        for (uint16 i = 0; i < activeDexes.length; i++) {
            (,, uint96 price,) = getDexReserves(activeDexes[i]);

            if (price > 0) {
                if (price < lowestPrice) lowestPrice = price;
                if (price > highestPrice) highestPrice = price;
            }
        }

        if (lowestPrice == type(uint96).max || lowestPrice == 0) return 0;

        return uint16(((highestPrice - lowestPrice) * 10000) / lowestPrice);
    }

/**
 * @dev Check if rebalancing is needed based on price deviation
     * @return Whether rebalancing is needed
     */
    function isRebalancingNeeded() external view override returns (bool) {
        // Check cooldown
        if (block.timestamp < lastRebalanceTime + rebalanceCooldown) {
            return false;
        }

        // Get current price deviation
        uint16 deviation = this.getPriceDeviation();

        // Compare with threshold
        return deviation > maxPriceDivergence;
    }

/**
 * @dev Get the DEX registry address
     * @return DEX registry address
     */
    function getDexRegistry() external view override returns (address) {
        return address(dexRegistry);
    }

/**
 * @dev Set the DEX registry
     * @param _registry New DEX registry address
     */
    function setDexRegistry(address _registry) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_registry == address(0)) revert ZeroAddress();
        dexRegistry = IDexRegistry(_registry);
        emit DexRegistrySet(_registry);
    }

/**
 * @dev Get the liquidity provisioner address
     * @return Liquidity provisioner address
     */
    function getLiquidityProvisioner() external view override returns (address) {
        return address(liquidityProvisioner);
    }

/**
 * @dev Set the liquidity provisioner
     * @param _provisioner New liquidity provisioner address
     */
    function setLiquidityProvisioner(address _provisioner) external override onlyRole(Constants.ADMIN_ROLE) {
        if (_provisioner == address(0)) revert ZeroAddress();
        liquidityProvisioner = ILiquidityProvisioner(_provisioner);
        emit LiquidityProvisionerSet(_provisioner);
    }

/**
 * @dev This contract doesn't use a token price feed directly, but implements this
     * function to maintain interface compatibility
     */
    function getTokenPriceFeed() external view override returns (address) {
        return address(0);
    }

/**
 * @dev This contract doesn't use a token price feed directly, but implements this
     * function to maintain interface compatibility
     */
    function setTokenPriceFeed(address _priceFeed) external override onlyRole(Constants.ADMIN_ROLE) {
        // No implementation needed
        emit TokenPriceFeedSet(_priceFeed);
    }

/**
 * @dev Set the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.LIQUIDITY_REBALANCER_NAME);
    }

/**
 * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        (address tokenAddress, address stablecoinAddress) = liquidityProvisioner.getTokenAndStablecoin();

        // Allow recovery of any token except platform token and stablecoin
        if (_token == tokenAddress || _token == stablecoinAddress) revert NotAuthorized();

        ERC20Upgradeable recoveryToken = ERC20Upgradeable(_token);
        uint256 balance = recoveryToken.balanceOf(address(this));
        if (balance == 0) revert ZeroAddress();

        bool success = recoveryToken.transfer(owner(), balance);
        if (!success) revert TransferFailed();
    }
}