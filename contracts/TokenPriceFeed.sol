// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;


import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import "./Registry/RegistryAwareUpgradeable.sol";

// DEX registry interface
interface IDexRegistry {
    struct DexInfo {
        string name;
        address router;
        address factory;
        address pair;
        address stakingRewards;
        uint8 allocationPercentage;
        bool active;
    }

    function getDexInfo(uint16 _dexId) external view returns (DexInfo memory);

    function getAllActiveDexes() external view returns (uint16[] memory);
}

// Price oracle interface (external price feed)
interface IPriceOracle {
    function getLatestPrice(address base, address quote) external view returns (uint256 price, uint256 timestamp);
}

// Interface to pair contract
interface IUniswapPair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @title TokenPriceFeed
 * @dev Enhanced price feed for token/stablecoin pairs across multiple DEXes
 */
contract TokenPriceFeed is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Pricing settings
    struct PriceSettings {
        bool enabled;              // Whether this token pair is enabled
        uint96 fallbackPrice;      // Fallback price to use when no DEX data available
        uint40 lastUpdateTime;     // Last time the price was updated
        uint40 priceValidPeriod;   // How long a price is considered valid for
        uint16 maxPriceDeviation;  // Maximum allowed price deviation between updates (100 = 1%)
        address[] supportedDexes;  // List of DEX pairs to check
    }

    // Price history data
    struct PriceData {
        uint96 price;              // Price value
        uint40 timestamp;          // When price was recorded
        string source;             // Source of the price (DEX name, oracle, etc.)
    }

    // Currently active prices per token pair
    mapping(address => mapping(address => uint96)) public currentPrices;

    // Price settings per token pair
    mapping(address => mapping(address => PriceSettings)) public priceSettings;

    // Recent price history (circular buffer, last 10 prices)
    mapping(address => mapping(address => PriceData[10])) public priceHistory;
    mapping(address => mapping(address => uint8)) public historyIndex;

    // Time-weighted average price (TWAP) settings
    uint32 public twapWindow;         // Window for TWAP calculation (in seconds)
    bool public twapEnabled;          // Whether to enable TWAP calculations

// Registry addresses
    address public dexRegistry;
    address public externalPriceOracle;

// Events
    event PriceUpdated(address indexed token, address indexed stablecoin, uint96 oldPrice, uint96 newPrice, string source);
    event PairConfigured(address indexed token, address indexed stablecoin, bool enabled);
    event FallbackPriceSet(address indexed token, address indexed stablecoin, uint96 fallbackPrice);
    event TWAPConfigUpdated(uint32 window, bool enabled);
    event DexRegistrySet(address indexed registry);
    event PriceOracleSet(address indexed oracle);

// Errors
    error ZeroAddress();
    error PairNotEnabled();
    error InvalidPriceDeviation(uint96 oldPrice, uint96 newPrice, uint16 maxDeviation);
    error NoValidPrice();
    error InvalidPrice();
    error InvalidDex(uint16 dexId);
    error InvalidParameters();

/**
 * @dev Initializer replaces constructor
     * @param _dexRegistry The DEX registry address
     * @param _externalPriceOracle External price oracle (optional)
     */
    function initialize(
        address _dexRegistry,
        address _externalPriceOracle
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Set registry and oracle
        dexRegistry = _dexRegistry;
        externalPriceOracle = _externalPriceOracle;

        // Default TWAP settings
        twapWindow = 1 hours;
        twapEnabled = true;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ORACLE_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Configure pricing settings for a token pair
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @param _enabled Whether the pair is enabled
     * @param _fallbackPrice Fallback price if no DEX data available
     * @param _priceValidPeriod How long a price is valid for
     * @param _maxPriceDeviation Maximum allowed price deviation
     * @param _supportedDexIds Array of DEX IDs to include
     */
    function configurePricePair(
        address _token,
        address _stablecoin,
        bool _enabled,
        uint96 _fallbackPrice,
        uint40 _priceValidPeriod,
        uint16 _maxPriceDeviation,
        uint16[] calldata _supportedDexIds
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_token == address(0) || _stablecoin == address(0)) revert ZeroAddress();

        // Convert DEX IDs to addresses
        address[] memory supportedDexes = new address[](_supportedDexIds.length);

        if (dexRegistry != address(0)) {
            IDexRegistry registry = IDexRegistry(dexRegistry);

            for (uint16 i = 0; i < _supportedDexIds.length; i++) {
                try registry.getDexInfo(_supportedDexIds[i]) returns (IDexRegistry.DexInfo memory dex) {
                    supportedDexes[i] = dex.pair;
                } catch {
                    revert InvalidDex(_supportedDexIds[i]);
                }
            }
        }

        // Update price settings
        priceSettings[_token][_stablecoin] = PriceSettings({
            enabled: _enabled,
            fallbackPrice: _fallbackPrice,
            lastUpdateTime: uint40(block.timestamp),
            priceValidPeriod: _priceValidPeriod,
            maxPriceDeviation: _maxPriceDeviation,
            supportedDexes: supportedDexes
        });

        // Also set a default current price if none exists
        if (currentPrices[_token][_stablecoin] == 0) {
            currentPrices[_token][_stablecoin] = _fallbackPrice;

            // Record in history
            uint8 index = historyIndex[_token][_stablecoin];
            priceHistory[_token][_stablecoin][index] = PriceData({
                price: _fallbackPrice,
                timestamp: uint40(block.timestamp),
                source: "Fallback"
            });

            // Update history index
            historyIndex[_token][_stablecoin] = (index + 1) % 10;
        }

        emit PairConfigured(_token, _stablecoin, _enabled);
        emit FallbackPriceSet(_token, _stablecoin, _fallbackPrice);
    }

    /**
     * @dev Update price for a token pair using on-chain DEX data and/or external oracle
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @return price Updated token price
     */
    function updatePrice(
        address _token,
        address _stablecoin
    ) public onlyRole(Constants.ORACLE_ROLE) returns (uint96 price) {
        if (!priceSettings[_token][_stablecoin].enabled) revert PairNotEnabled();

        uint96 oldPrice = currentPrices[_token][_stablecoin];
        uint96 newPrice = 0;
        string memory source = "";

        // Get price from DEXes
        (uint96 dexPrice, string memory dexSource) = _getPriceFromDexes(_token, _stablecoin);

        if (dexPrice > 0) {
            newPrice = dexPrice;
            source = dexSource;
        }

        // If DEX price is not available, try external oracle
        if (newPrice == 0 && externalPriceOracle != address(0)) {
            try IPriceOracle(externalPriceOracle).getLatestPrice(_token, _stablecoin) returns (uint256 oraclePrice, uint256 timestamp) {
                if (oraclePrice > 0 && block.timestamp - timestamp < 24 hours) {
                    newPrice = uint96(oraclePrice);
                    source = "Oracle";
                }
            } catch {
            // Continue if oracle call fails
            }
        }

        // If no price available, use fallback
        if (newPrice == 0) {
            newPrice = priceSettings[_token][_stablecoin].fallbackPrice;
            source = "Fallback";
        }

        // Verify price doesn't deviate too much from previous (if previous exists)
        if (oldPrice > 0) {
            uint16 maxDeviation = priceSettings[_token][_stablecoin].maxPriceDeviation;
            uint96 deviation;

            if (newPrice > oldPrice) {
                deviation = uint96(((newPrice - oldPrice) * 10000) / oldPrice);
            } else {
                deviation = uint96(((oldPrice - newPrice) * 10000) / oldPrice);
            }

            if (deviation > maxDeviation) {
                // Calculate limited new price
                if (newPrice > oldPrice) {
                    newPrice = uint96(oldPrice + ((oldPrice * maxDeviation) / 10000));
                } else {
                    newPrice = uint96(oldPrice - ((oldPrice * maxDeviation) / 10000));
                }
                source = string(abi.encodePacked(source, " (Limited)"));
            }
        }

        // Update price
        currentPrices[_token][_stablecoin] = newPrice;
        priceSettings[_token][_stablecoin].lastUpdateTime = uint40(block.timestamp);

        // Record in history
        uint8 index = historyIndex[_token][_stablecoin];
        priceHistory[_token][_stablecoin][index] = PriceData({
            price: newPrice,
            timestamp: uint40(block.timestamp),
            source: source
        });

        // Update history index
        historyIndex[_token][_stablecoin] = (index + 1) % 10;

        emit PriceUpdated(_token, _stablecoin, oldPrice, newPrice, source);

        return newPrice;
    }

    /**
     * @dev Get the current price of a token in terms of stablecoin
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @return price Current price
     */
    function getTokenPrice(
        address _token,
        address _stablecoin
    ) public view returns (uint96 price) {
        if (!priceSettings[_token][_stablecoin].enabled) revert PairNotEnabled();

        // If TWAP is enabled, calculate and use TWAP
        if (twapEnabled) {
            uint96 twapPrice = calculateTWAP(_token, _stablecoin);
            if (twapPrice > 0) {
                return twapPrice;
            }
        }

        // Use current price if valid
        uint40 lastUpdate = priceSettings[_token][_stablecoin].lastUpdateTime;
        uint40 validPeriod = priceSettings[_token][_stablecoin].priceValidPeriod;

        if (block.timestamp <= lastUpdate + validPeriod) {
            return currentPrices[_token][_stablecoin];
        }

        // If current price is not valid, try to get a fresh price
        (uint96 dexPrice,) = _getPriceFromDexes(_token, _stablecoin);
        if (dexPrice > 0) {
            return dexPrice;
        }

        // If no fresh price available, use fallback
        return priceSettings[_token][_stablecoin].fallbackPrice;
    }

    /**
     * @dev Calculate Time-Weighted Average Price (TWAP) for a token pair
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @return twapPrice The time-weighted average price
     */
    function calculateTWAP(
        address _token,
        address _stablecoin
    ) public view returns (uint96 twapPrice) {
        if (!priceSettings[_token][_stablecoin].enabled) revert PairNotEnabled();

        uint256 totalWeight = 0;
        uint256 weightedPriceSum = 0;
        uint40 windowStart = uint40(block.timestamp) - uint40(twapWindow);

        for (uint8 i = 0; i < 10; i++) {
            PriceData memory data = priceHistory[_token][_stablecoin][i];

            // Skip if no data or outside window
            if (data.price == 0 || data.timestamp < windowStart) {
                continue;
            }

            // Calculate weight (time difference from previous valid data point)
            uint40 prevTimestamp = 0;
            for (uint8 j = 1; j < 10; j++) {
                uint8 prevIndex = (i + 10 - j) % 10;
                if (priceHistory[_token][_stablecoin][prevIndex].price > 0 &&
                    priceHistory[_token][_stablecoin][prevIndex].timestamp >= windowStart) {
                    prevTimestamp = priceHistory[_token][_stablecoin][prevIndex].timestamp;
                    break;
                }
            }

            uint40 weight;
            if (prevTimestamp == 0) {
                // First data point in window, use time from window start
                weight = data.timestamp - windowStart;
            } else {
                // Use time difference from previous data point
                weight = data.timestamp - prevTimestamp;
            }

            // Add to weighted sum
            weightedPriceSum += uint256(data.price) * weight;
            totalWeight += weight;
        }

        // Calculate TWAP
        if (totalWeight > 0) {
            return uint96(weightedPriceSum / totalWeight);
        }

        // If no valid data points in window, return 0
        return 0;
    }

    /**
     * @dev Internal function to get price from DEXes
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @return price The price from DEXes
     * @return source Source of the price
     */
    function _getPriceFromDexes(
        address _token,
        address _stablecoin
    ) internal view returns (uint96 price, string memory source) {
        if (dexRegistry == address(0)) {
            return (0, "");
        }

        address[] storage supportedDexes = priceSettings[_token][_stablecoin].supportedDexes;

        if (supportedDexes.length == 0) {
            // If no specific DEXes configured, use all active DEXes
            IDexRegistry registry = IDexRegistry(dexRegistry);
            uint16[] memory activeDexes;

            try registry.getAllActiveDexes() returns (uint16[] memory dexes) {
                activeDexes = dexes;
            } catch {
                return (0, "");
            }

            if (activeDexes.length == 0) {
                return (0, "");
            }

            uint96 totalPrice = 0;
            uint16 validPrices = 0;
            string memory bestSource = "";
            uint96 bestLiquidity = 0;

            for (uint16 i = 0; i < activeDexes.length; i++) {
                try registry.getDexInfo(activeDexes[i]) returns (IDexRegistry.DexInfo memory dex) {
                    if (dex.active && dex.pair != address(0)) {
                        (uint96 dexPrice, uint96 liquidity) = _getPriceFromPair(dex.pair, _token, _stablecoin);

                        if (dexPrice > 0) {
                            totalPrice += dexPrice;
                            validPrices++;

                            // Track the DEX with the most liquidity as the source
                            if (liquidity > bestLiquidity) {
                                bestLiquidity = liquidity;
                                bestSource = dex.name;
                            }
                        }
                    }
                } catch {
                // Skip on error
                }
            }

            if (validPrices > 0) {
                return (uint96(totalPrice / validPrices), bestSource);
            }
        } else {
            // Use configured DEXes
            uint96 totalPrice = 0;
            uint16 validPrices = 0;
            uint96 bestLiquidity = 0;

            for (uint16 i = 0; i < supportedDexes.length; i++) {
                address pair = supportedDexes[i];
                if (pair != address(0)) {
                    (uint96 dexPrice, uint96 liquidity) = _getPriceFromPair(pair, _token, _stablecoin);

                    if (dexPrice > 0) {
                        totalPrice += dexPrice;
                        validPrices++;

                        // Track the DEX with the most liquidity as the source
                        if (liquidity > bestLiquidity) {
                            bestLiquidity = liquidity;
                            source = string(abi.encodePacked("DEX ", toString(i)));
                        }
                    }
                }
            }

            if (validPrices > 0) {
                return (uint96(totalPrice / validPrices), source);
            }
        }

        return (0, "");
    }

    /**
     * @dev Get price from a DEX pair
     * @param _pair Pair address
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @return price Price from the pair
     * @return liquidity Liquidity value (used to weight sources)
     */
    function _getPriceFromPair(
        address _pair,
        address _token,
        address _stablecoin
    ) internal view returns (uint96 price, uint96 liquidity) {

        try IUniswapPair(_pair).token0() returns (address token0) {
            try IUniswapPair(_pair).token1() returns (address token1) {
                // Verify pair contains our tokens
                bool containsToken = (token0 == _token || token1 == _token);
                bool containsStable = (token0 == _stablecoin || token1 == _stablecoin);

                if (containsToken && containsStable) {
                    try IUniswapPair(_pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32 /*blockTimestampLast*/) {
                        bool token0IsToken = token0 == _token;

                        uint112 tokenReserve = token0IsToken ? reserve0 : reserve1;
                        uint112 stableReserve = token0IsToken ? reserve1 : reserve0;

                        if (tokenReserve > 0) {
                            // Calculate price
                            price = uint96((uint256(stableReserve) * 1e18) / uint256(tokenReserve));

                            // Calculate liquidity (in stablecoin terms)
                            liquidity = uint96(stableReserve * 2);

                            return (price, liquidity);
                        }
                    } catch {
                        // Continue if getReserves fails
                    }
                }
            } catch {
                // Continue if token1 call fails
            }
        } catch {
            // Continue if token0 call fails
        }

        return (0, 0);
    }

    /**
     * @dev Set the DEX registry address
     * @param _registry New registry address
     */
    function setDexRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        dexRegistry = _registry;
        emit DexRegistrySet(_registry);
    }

    /**
     * @dev Set the external price oracle address
     * @param _oracle New oracle address
     */
    function setExternalPriceOracle(address _oracle) external onlyRole(Constants.ADMIN_ROLE) {
        externalPriceOracle = _oracle;
        emit PriceOracleSet(_oracle);
    }

    /**
     * @dev Configure TWAP settings
     * @param _window TWAP window in seconds
     * @param _enabled Whether TWAP is enabled
     */
    function configureTWAP(uint32 _window, bool _enabled) external onlyRole(Constants.ADMIN_ROLE) {
        if (_window == 0) revert InvalidParameters();

        twapWindow = _window;
        twapEnabled = _enabled;

        emit TWAPConfigUpdated(_window, _enabled);
    }

    /**
     * @dev Set the fallback price for a token pair
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @param _fallbackPrice New fallback price
     */
    function setFallbackPrice(
        address _token,
        address _stablecoin,
        uint96 _fallbackPrice
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_token == address(0) || _stablecoin == address(0)) revert ZeroAddress();
        if (_fallbackPrice == 0) revert InvalidPrice();

        priceSettings[_token][_stablecoin].fallbackPrice = _fallbackPrice;

        emit FallbackPriceSet(_token, _stablecoin, _fallbackPrice);
    }

    /**
     * @dev Force update price for a token pair (emergency function)
     * @param _token Token address
     * @param _stablecoin Stablecoin address
     * @param _price New price
     */
    function forceUpdatePrice(
        address _token,
        address _stablecoin,
        uint96 _price
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_token == address(0) || _stablecoin == address(0)) revert ZeroAddress();
        if (_price == 0) revert InvalidPrice();

        uint96 oldPrice = currentPrices[_token][_stablecoin];
        currentPrices[_token][_stablecoin] = _price;
        priceSettings[_token][_stablecoin].lastUpdateTime = uint40(block.timestamp);

        // Record in history
        uint8 index = historyIndex[_token][_stablecoin];
        priceHistory[_token][_stablecoin][index] = PriceData({
            price: _price,
            timestamp: uint40(block.timestamp),
            source: "Admin"
        });

        // Update history index
        historyIndex[_token][_stablecoin] = (index + 1) % 10;

        emit PriceUpdated(_token, _stablecoin, oldPrice, _price, "Admin");
    }

    /**
     * @dev Set the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.TOKEN_PRICE_FEED_NAME);
    }

    /**
     * @dev Helper function to convert uint to string
     */
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;

        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);

        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}