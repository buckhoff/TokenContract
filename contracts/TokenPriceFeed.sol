// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

interface ILiquidityManager {
    function getTokenPrice(address _token, address _stablecoin) external view returns (uint96 price);
}

interface IPlatformStabilityFund {
    function getVerifiedPrice() external view returns (uint96);
}

/**
 * @title TokenPriceFeed
 * @dev Manages token pricing, conversion, and payment token support for the crowdsale
 */
contract TokenPriceFeed is
AccessControlEnumerableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Mapping of supported payment tokens to their details
    struct PaymentTokenInfo {
        bool isActive;           // Whether the token is active
        uint256 minAmount;       // Minimum purchase amount in USD
        uint256 maxAmount;       // Maximum purchase amount in USD
        address priceOracle;     // Custom price oracle (if any)
        uint8 decimals;          // Token decimals (cached)
        uint256 totalCollected;  // Total amount collected
    }

    // Payment token mapping and tracking
    mapping(address => PaymentTokenInfo) public paymentTokens;
    address[] public supportedPaymentTokensArray;

    // Default stablecoin (reference for prices)
    address public defaultStablecoin;

    // LiquidityManager reference for price discovery
    ILiquidityManager public liquidityManager;

    // Dynamic pricing settings
    bool public useDynamicPricing;
    uint32 public priceCacheTimeout;
    uint16 public maxPriceDeviationThreshold;

    // Price caching
    mapping(address => uint256) public cachedPriceRates;
    mapping(address => uint256) public lastPriceUpdate;
    mapping(address => uint256) public fallbackPriceRates;

    // USD price scaling factor (6 decimal places)
    uint256 public constant PRICE_DECIMALS = 1e6;

    // Crowdsale reference
    address public crowdsaleContract;

    // Events
    event PaymentTokenAdded(address indexed token, uint256 minAmount, uint256 maxAmount);
    event PaymentTokenRemoved(address indexed token);
    event PaymentTokenUpdated(address indexed token, uint256 minAmount, uint256 maxAmount);
    event PriceOracleSet(address indexed token, address indexed oracle);
    event PriceRateUpdated(address indexed token, uint256 oldRate, uint256 newRate);
    event LiquidityManagerSet(address indexed liquidityManager);
    event CrowdsaleSet(address indexed crowdsale);

    // Errors
    error UnauthorizedCaller();
    error NoPriceSourceAvailable(address token);
    error UnsupportedPaymentToken(address token);
    error ZeroPriceRate();
    error InvalidPriceOracle(address oracle);
    error PriceDeviationTooHigh(uint256 oraclePrice, uint256 fallbackPrice, uint256 deviation);

    modifier onlyCrowdsale() {
        if (msg.sender != crowdsaleContract) revert UnauthorizedCaller();
        _;
    }

    /**
     * @dev Initializer function to replace constructor
     * @param _defaultStablecoin Address of the default stablecoin
     */
    function initialize(
        address _defaultStablecoin
    ) initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        defaultStablecoin = _defaultStablecoin;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);

        // Default settings
        priceCacheTimeout = 1 hours;
        maxPriceDeviationThreshold = 1000; // 10%
        useDynamicPricing = true;

        // Setup default stablecoin
        uint8 decimals = ERC20Upgradeable(_defaultStablecoin).decimals();

        paymentTokens[_defaultStablecoin] = PaymentTokenInfo({
            isActive: true,
            minAmount: 100 * PRICE_DECIMALS, // $100 min
            maxAmount: 50_000 * PRICE_DECIMALS, // $50,000 max
            priceOracle: address(0),
            decimals: decimals,
            totalCollected: 0
        });

        supportedPaymentTokensArray.push(_defaultStablecoin);
        fallbackPriceRates[_defaultStablecoin] = 10**decimals; // 1:1 rate for stablecoin
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Set the crowdsale contract address
     * @param _crowdsale Address of the crowdsale contract
     */
    function setCrowdsale(address _crowdsale) external onlyRole(Constants.ADMIN_ROLE) {
        require(_crowdsale != address(0), "Zero address");
        crowdsaleContract = _crowdsale;
        emit CrowdsaleSet(_crowdsale);
    }

    /**
     * @dev Set the LiquidityManager for price discovery
     * @param _liquidityManager Address of the LiquidityManager contract
     */
    function setLiquidityManager(address _liquidityManager) external onlyRole(Constants.ADMIN_ROLE) {
        require(_liquidityManager != address(0), "Zero address");
        liquidityManager = ILiquidityManager(_liquidityManager);
        emit LiquidityManagerSet(_liquidityManager);
    }

    /**
     * @dev Configure dynamic pricing settings
     * @param _useDynamicPricing Whether to use dynamic pricing
     * @param _priceCacheTimeout Cache timeout in seconds
     * @param _maxDeviationThreshold Max deviation threshold (scaled by 10000)
     */
    function configureDynamicPricing(
        bool _useDynamicPricing,
        uint32 _priceCacheTimeout,
        uint16 _maxDeviationThreshold
    ) external onlyRole(Constants.ADMIN_ROLE) {
        useDynamicPricing = _useDynamicPricing;
        priceCacheTimeout = _priceCacheTimeout;
        maxPriceDeviationThreshold = _maxDeviationThreshold;
    }

    /**
     * @dev Add a payment token with custom configurations
     * @param _token Token address
     * @param _minAmount Minimum purchase amount in USD
     * @param _maxAmount Maximum purchase amount in USD
     * @param _priceOracle Custom price oracle (can be zero)
     */
    function addPaymentToken(
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        address _priceOracle
    ) external onlyRole(Constants.ADMIN_ROLE) {
        _addPaymentToken(_token, _minAmount, _maxAmount, _priceOracle);
    }

    /**
     * @dev Internal function to add payment token
     */
    function _addPaymentToken(
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        address _priceOracle
    ) internal {
        require(_token != address(0), "Zero token address");
        require(_minAmount > 0, "Min amount must be > 0");
        require(_maxAmount >= _minAmount, "Max amount must be >= min");

        // Check if token is already supported
        if (!paymentTokens[_token].isActive) {
            supportedPaymentTokensArray.push(_token);
        }

        // Get token decimals
        uint8 decimals = ERC20Upgradeable(_token).decimals();

        // Store token info
        paymentTokens[_token] = PaymentTokenInfo({
            isActive: true,
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            priceOracle: _priceOracle,
            decimals: decimals,
            totalCollected: 0
        });

        // Set fallback price rate (1:1 for stablecoins, 0 for others)
        if (_token == defaultStablecoin) {
            // Default stablecoin has 1:1 rate
            fallbackPriceRates[_token] = 10**decimals;
        } else {
            // Other tokens will use oracle pricing
            fallbackPriceRates[_token] = 0;
        }

        // Emit event
        emit PaymentTokenAdded(_token, _minAmount, _maxAmount);

        // If custom price oracle provided
        if (_priceOracle != address(0)) {
            emit PriceOracleSet(_token, _priceOracle);
        }
    }

    /**
     * @dev Remove a payment token
     * @param _token Token address to remove
     */
    function removePaymentToken(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        // Cannot remove default stablecoin
        require(_token != defaultStablecoin, "Cannot remove default stablecoin");

        // Deactivate token
        paymentTokens[_token].isActive = false;

        // Remove from array (swap and pop)
        for (uint i = 0; i < supportedPaymentTokensArray.length; i++) {
            if (supportedPaymentTokensArray[i] == _token) {
                // Swap with last element and pop
                supportedPaymentTokensArray[i] = supportedPaymentTokensArray[supportedPaymentTokensArray.length - 1];
                supportedPaymentTokensArray.pop();
                break;
            }
        }

        emit PaymentTokenRemoved(_token);
    }

    /**
     * @dev Set fallback price rate for a token
     * @param _token Token address
     * @param _rate Price rate relative to USD (scaled by token decimals)
     */
    function setFallbackPriceRate(address _token, uint256 _rate) external onlyRole(Constants.ADMIN_ROLE) {
        require(paymentTokens[_token].isActive, "Token not active");
        require(_rate > 0, "Rate must be > 0");

        uint256 oldRate = fallbackPriceRates[_token];
        fallbackPriceRates[_token] = _rate;

        emit PriceRateUpdated(_token, oldRate, _rate);
    }

    /**
     * @dev Get current USD price of a token
     * @param _token Token address
     * @return price Token price in USD (scaled by PRICE_DECIMALS)
     */
    function getTokenUsdPrice(address _token) public view returns (uint256 price) {
        // For default stablecoin, return 1:1
        if (_token == defaultStablecoin) {
            return 10**6; // $1 with 6 decimals precision
        }

        // Check if we should use dynamic pricing
        if (!useDynamicPricing) {
            // Use fallback rates directly
            return _convertTokenPriceToUsd(_token, fallbackPriceRates[_token]);
        }

        // Check if we have a cached price that's still valid
        if (lastPriceUpdate[_token] > 0 &&
            block.timestamp < lastPriceUpdate[_token] + priceCacheTimeout) {
            return cachedPriceRates[_token];
        }

        // Try to get price from custom oracle if available
        if (paymentTokens[_token].priceOracle != address(0)) {
            try ILiquidityManager(paymentTokens[_token].priceOracle).getTokenPrice(
                _token, defaultStablecoin
            ) returns (uint96 oraclePrice) {
                return _convertTokenPriceToUsd(_token, oraclePrice);
            } catch {
                // Oracle failed, continue to next price source
            }
        }

        // Try to get price from liquidity manager if available
        if (address(liquidityManager) != address(0)) {
            try liquidityManager.getTokenPrice(_token, defaultStablecoin) returns (uint96 lmPrice) {
                return _convertTokenPriceToUsd(_token, lmPrice);
            } catch {
                // Liquidity manager failed, continue to next price source
            }
        }

        // Try to get price from StabilityFund if this is a main token
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.STABILITY_FUND_NAME) returns (address stabilityFund) {
                try IPlatformStabilityFund(stabilityFund).getVerifiedPrice() returns (uint96 sfPrice) {
                    return _convertTokenPriceToUsd(_token, sfPrice);
                } catch {
                    // Stability fund failed, continue to fallback
                }
            } catch {
                // Registry lookup failed, continue to fallback
            }
        }

        // Fall back to manual rate if all oracles fail
        if (fallbackPriceRates[_token] > 0) {
            return _convertTokenPriceToUsd(_token, fallbackPriceRates[_token]);
        }

        // If we get here, we cannot price the token
        revert NoPriceSourceAvailable(_token);
    }

    /**
     * @dev Convert token amount to USD equivalent
     * @param _token Token address
     * @param _amount Amount of tokens
     * @return usdAmount USD equivalent (scaled by PRICE_DECIMALS)
     */
    function convertTokenToUsd(address _token, uint256 _amount) public view returns (uint256 usdAmount) {
        if (!paymentTokens[_token].isActive) revert UnsupportedPaymentToken(_token);

        // Get token's USD price
        uint256 tokenUsdPrice = getTokenUsdPrice(_token);

        // Get token decimals
        uint8 decimals = paymentTokens[_token].decimals;

        // Calculate USD amount
        // usdAmount = _amount * tokenUsdPrice / 10^decimals
        usdAmount = (_amount * tokenUsdPrice) / (10**decimals);

        return usdAmount;
    }

    /**
     * @dev Convert USD amount to token amount
     * @param _token Token address
     * @param _usdAmount USD amount (scaled by PRICE_DECIMALS)
     * @return tokenAmount Equivalent token amount
     */
    function convertUsdToToken(address _token, uint256 _usdAmount) public view returns (uint256 tokenAmount) {
        if (!paymentTokens[_token].isActive) revert UnsupportedPaymentToken(_token);

        // Get token's USD price
        uint256 tokenUsdPrice = getTokenUsdPrice(_token);

        // Get token decimals
        uint8 decimals = paymentTokens[_token].decimals;

        // Calculate token amount
        // tokenAmount = _usdAmount * 10^decimals / tokenUsdPrice
        tokenAmount = (_usdAmount * (10**decimals)) / tokenUsdPrice;

        return tokenAmount;
    }

    /**
     * @dev Helper function to convert token price to USD format
     * @param _token Token address
     * @param _tokenPrice Token price
     * @return usdPrice USD price (scaled by PRICE_DECIMALS)
     */
    function _convertTokenPriceToUsd(address _token, uint256 _tokenPrice) internal view returns (uint256 usdPrice) {
        // Get token decimals
        uint8 decimals = paymentTokens[_token].decimals;

        // Convert price to our standard USD format with 6 decimals
        if (decimals > PRICE_DECIMALS) {
            usdPrice = _tokenPrice / (10**(decimals - PRICE_DECIMALS));
        } else if (decimals < PRICE_DECIMALS) {
            usdPrice = _tokenPrice * (10**(PRICE_DECIMALS - decimals));
        } else {
            usdPrice = _tokenPrice;
        }

        return usdPrice;
    }

    /**
     * @dev Update cached token price
     * @param _token Token address
     */
    function updateTokenPrice(address _token) external {
        require(paymentTokens[_token].isActive, "Token not active");

        // Check if timeout has elapsed
        if (lastPriceUpdate[_token] > 0 &&
            block.timestamp < lastPriceUpdate[_token] + priceCacheTimeout) {
            revert("Cache too recent");
        }

        // Get current price
        uint256 price = getTokenUsdPrice(_token);

        // Check for large deviation from fallback price
        if (fallbackPriceRates[_token] > 0) {
            uint256 fallbackUsdPrice = _convertTokenPriceToUsd(_token, fallbackPriceRates[_token]);

            uint256 deviation;
            if (price > fallbackUsdPrice) {
                deviation = ((price - fallbackUsdPrice) * 10000) / fallbackUsdPrice;
            } else {
                deviation = ((fallbackUsdPrice - price) * 10000) / fallbackUsdPrice;
            }

            // If deviation is too high, revert or use fallback
            if (deviation > maxPriceDeviationThreshold) {
                revert PriceDeviationTooHigh(price, fallbackUsdPrice, deviation);
            }
        }

        // Update cache
        cachedPriceRates[_token] = price;
        lastPriceUpdate[_token] = block.timestamp;

        emit PriceRateUpdated(_token, cachedPriceRates[_token], price);
    }

    /**
     * @dev Update payment token configuration
     * @param _token Token address
     * @param _minAmount New minimum purchase amount
     * @param _maxAmount New maximum purchase amount
     * @param _priceOracle New price oracle (or zero for default)
     */
    function updatePaymentToken(
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        address _priceOracle
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(paymentTokens[_token].isActive, "Token not active");
        require(_minAmount > 0, "Min amount must be > 0");
        require(_maxAmount >= _minAmount, "Max amount must be >= min");

        // Update token info
        paymentTokens[_token].minAmount = _minAmount;
        paymentTokens[_token].maxAmount = _maxAmount;

        // Update price oracle if provided
        if (_priceOracle != paymentTokens[_token].priceOracle) {
            paymentTokens[_token].priceOracle = _priceOracle;
            emit PriceOracleSet(_token, _priceOracle);
        }

        emit PaymentTokenUpdated(_token, _minAmount, _maxAmount);
    }

    /**
     * @dev Record payment collection for a token
     * @param _token Token address
     * @param _amount Amount collected
     */
    function recordPaymentCollection(address _token, uint256 _amount) external onlyCrowdsale {
        require(paymentTokens[_token].isActive, "Token not active");
        paymentTokens[_token].totalCollected += _amount;
    }

    /**
     * @dev Get list of supported payment tokens
     * @return tokens Array of supported payment token addresses
     */
    function getSupportedPaymentTokens() public view returns (address[] memory) {
        return supportedPaymentTokensArray;
    }

    /**
     * @dev Get payment token details
     * @param _token Token address
     * @return isActive Whether token is active
     * @return minAmount Minimum purchase amount in USD
     * @return maxAmount Maximum purchase amount in USD
     * @return priceOracle Address of custom price oracle
     * @return totalCollected Total amount collected in this token
     * @return currentPrice Current USD price (scaled by PRICE_DECIMALS)
     */
    function getPaymentTokenDetails(address _token) external view returns (
        bool isActive,
        uint256 minAmount,
        uint256 maxAmount,
        address priceOracle,
        uint256 totalCollected,
        uint256 currentPrice
    ) {
        PaymentTokenInfo storage tokenInfo = paymentTokens[_token];

        return (
            tokenInfo.isActive,
            tokenInfo.minAmount,
            tokenInfo.maxAmount,
            tokenInfo.priceOracle,
            tokenInfo.totalCollected,
            getTokenUsdPrice(_token)
        );
    }

    /**
     * @dev Check if a token is supported for payment
     * @param _token Token address
     * @return isSupported Whether the token is supported
     */
    function isTokenSupported(address _token) external view returns (bool) {
        return paymentTokens[_token].isActive;
    }

    /**
     * @dev Get token decimals
     * @param _token Token address
     * @return decimals Number of decimals
     */
    function getTokenDecimals(address _token) external view returns (uint8) {
        require(paymentTokens[_token].isActive, "Token not active");
        return paymentTokens[_token].decimals;
    }
}
