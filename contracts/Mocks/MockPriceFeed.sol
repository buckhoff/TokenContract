// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockPriceFeedEnhanced
 * @dev Enhanced mock implementation of ITokenPriceFeed for comprehensive testing
 */
contract MockPriceFeed {
    // Supported tokens
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    // Token conversion rates (token -> USD, scaled by 1e6)
    mapping(address => uint256) public tokenRates;

    // Collection tracking
    mapping(address => uint256) public collectedAmounts;
    mapping(address => uint256) public collectionCounts;

    // Enhanced features for testing
    mapping(address => bool) public tokensPaused;
    mapping(address => uint256) public lastUpdateTimes;
    uint256 public defaultSlippage = 100; // 1% default slippage

    // Price volatility simulation
    mapping(address => uint256) public priceVolatility; // Basis points
    mapping(address => uint256) public lastPriceUpdate;

    // Events
    event TokenAdded(address indexed token, uint256 rate);
    event TokenRemoved(address indexed token);
    event RateUpdated(address indexed token, uint256 oldRate, uint256 newRate);
    event PaymentCollected(address indexed token, uint256 amount);
    event TokenPaused(address indexed token, bool paused);

    /**
     * @dev Constructor to set up default token
     */
    constructor(address _defaultToken) {
        if (_defaultToken != address(0)) {
            addSupportedToken(_defaultToken, 1000000); // $1.00 per token
        }
    }

    /**
     * @dev Add a supported token with rate
     */
    function addSupportedToken(address _token, uint256 _rate) public {
        require(_token != address(0), "Zero token address");
        require(_rate > 0, "Rate must be positive");

        if (!supportedTokens[_token]) {
            supportedTokens[_token] = true;
            tokenList.push(_token);
            emit TokenAdded(_token, _rate);
        }

        uint256 oldRate = tokenRates[_token];
        tokenRates[_token] = _rate;
        lastUpdateTimes[_token] = block.timestamp;

        if (oldRate != _rate) {
            emit RateUpdated(_token, oldRate, _rate);
        }
    }

    /**
     * @dev Remove a supported token
     */
    function removeSupportedToken(address _token) external {
        require(supportedTokens[_token], "Token not supported");

        supportedTokens[_token] = false;
        tokenRates[_token] = 0;

        // Remove from token list
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == _token) {
                tokenList[i] = tokenList[tokenList.length - 1];
                tokenList.pop();
                break;
            }
        }

        emit TokenRemoved(_token);
    }

    /**
     * @dev Check if token is supported and not paused
     */
    function isTokenSupported(address _token) external view returns (bool) {
        return supportedTokens[_token] && !tokensPaused[_token];
    }

    /**
     * @dev Get all supported payment tokens (excluding paused ones)
     */
    function getSupportedPaymentTokens() external view returns (address[] memory) {
        uint256 activeCount = 0;

        // Count active tokens
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (supportedTokens[tokenList[i]] && !tokensPaused[tokenList[i]]) {
                activeCount++;
            }
        }

        // Create array of active tokens
        address[] memory activeTokens = new address[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (supportedTokens[tokenList[i]] && !tokensPaused[tokenList[i]]) {
                activeTokens[index] = tokenList[i];
                index++;
            }
        }

        return activeTokens;
    }

    /**
     * @dev Convert token amount to USD with volatility simulation
     */
    function convertTokenToUsd(address _token, uint256 _amount) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");
        require(!tokensPaused[_token], "Token is paused");

        uint256 baseRate = tokenRates[_token];
        uint256 adjustedRate = _applyVolatility(_token, baseRate);

        // Convert based on rate (amount * rate / 1e6 for 6-decimal tokens)
        return (_amount * adjustedRate) / 1e6;
    }

    /**
     * @dev Convert USD amount to token with slippage
     */
    function convertUsdToToken(address _token, uint256 _usdAmount) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");
        require(!tokensPaused[_token], "Token is paused");

        uint256 baseRate = tokenRates[_token];
        uint256 adjustedRate = _applyVolatility(_token, baseRate);

        // Apply slippage
        uint256 slippageAmount = (_usdAmount * defaultSlippage) / 10000;
        uint256 adjustedUsdAmount = _usdAmount + slippageAmount;

        // Convert based on rate
        return (adjustedUsdAmount * 1e6) / adjustedRate;
    }

    /**
     * @dev Record payment collection with enhanced tracking
     */
    function recordPaymentCollection(address _token, uint256 _amount) external {
        require(supportedTokens[_token], "Token not supported");

        collectedAmounts[_token] += _amount;
        collectionCounts[_token]++;

        emit PaymentCollected(_token, _amount);
    }

    /**
     * @dev Get token USD price with volatility
     */
    function getTokenUsdPrice(address _token) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");

        uint256 baseRate = tokenRates[_token];
        return _applyVolatility(_token, baseRate);
    }

    /**
     * @dev Set volatility for a token (for testing price fluctuations)
     */
    function setTokenVolatility(address _token, uint256 _volatilityBps) external {
        require(supportedTokens[_token], "Token not supported");
        require(_volatilityBps <= 5000, "Volatility too high"); // Max 50%

        priceVolatility[_token] = _volatilityBps;
        lastPriceUpdate[_token] = block.timestamp;
    }

    /**
     * @dev Pause/unpause a token
     */
    function pauseToken(address _token, bool _paused) external {
        require(supportedTokens[_token], "Token not supported");

        tokensPaused[_token] = _paused;
        emit TokenPaused(_token, _paused);
    }

    /**
     * @dev Set default slippage for conversions
     */
    function setDefaultSlippage(uint256 _slippageBps) external {
        require(_slippageBps <= 1000, "Slippage too high"); // Max 10%
        defaultSlippage = _slippageBps;
    }

    /**
     * @dev Batch update rates for multiple tokens
     */
    function batchUpdateRates(
        address[] calldata _tokens,
        uint256[] calldata _rates
    ) external {
        require(_tokens.length == _rates.length, "Arrays length mismatch");

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (supportedTokens[_tokens[i]]) {
                uint256 oldRate = tokenRates[_tokens[i]];
                tokenRates[_tokens[i]] = _rates[i];
                lastUpdateTimes[_tokens[i]] = block.timestamp;

                emit RateUpdated(_tokens[i], oldRate, _rates[i]);
            }
        }
    }

    /**
     * @dev Get collection statistics for a token
     */
    function getCollectionStats(address _token) external view returns (
        uint256 totalCollected,
        uint256 collectionCount,
        uint256 lastUpdate
    ) {
        return (
            collectedAmounts[_token],
            collectionCounts[_token],
            lastUpdateTimes[_token]
        );
    }

    /**
     * @dev Simulate market crash (emergency testing)
     */
    function simulateMarketCrash(uint256 _crashPercentage) external {
        require(_crashPercentage <= 9000, "Crash too severe"); // Max 90%

        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            if (supportedTokens[token]) {
                uint256 currentRate = tokenRates[token];
                uint256 newRate = currentRate - (currentRate * _crashPercentage) / 10000;
                tokenRates[token] = newRate;
                lastUpdateTimes[token] = block.timestamp;

                emit RateUpdated(token, currentRate, newRate);
            }
        }
    }

    /**
     * @dev Restore original rates (after crash simulation)
     */
    function restoreOriginalRates() external {
        // Reset to $1.00 for all tokens
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            if (supportedTokens[token]) {
                uint256 oldRate = tokenRates[token];
                tokenRates[token] = 1000000; // $1.00
                lastUpdateTimes[token] = block.timestamp;

                emit RateUpdated(token, oldRate, 1000000);
            }
        }
    }

    /**
     * @dev Internal function to apply volatility to price
     */
    function _applyVolatility(address _token, uint256 _baseRate) internal view returns (uint256) {
        uint256 volatility = priceVolatility[_token];
        if (volatility == 0) {
            return _baseRate;
        }

        // Simple pseudo-random volatility based on block.timestamp
        uint256 pseudoRandom = uint256(keccak256(abi.encodePacked(block.timestamp, _token))) % 10000;

        // Apply volatility as +/- percentage
        if (pseudoRandom % 2 == 0) {
            // Positive volatility
            return _baseRate + (_baseRate * volatility) / 10000;
        } else {
            // Negative volatility
            uint256 decrease = (_baseRate * volatility) / 10000;
            return _baseRate > decrease ? _baseRate - decrease : _baseRate / 2;
        }
    }

    /**
     * @dev Get all token information
     */
    function getAllTokenInfo() external view returns (
        address[] memory tokens,
        uint256[] memory rates,
        bool[] memory pausedStatus,
        uint256[] memory volatilities
    ) {
        uint256 length = tokenList.length;
        tokens = new address[](length);
        rates = new uint256[](length);
        pausedStatus = new bool[](length);
        volatilities = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = tokenList[i];
            tokens[i] = token;
            rates[i] = tokenRates[token];
            pausedStatus[i] = tokensPaused[token];
            volatilities[i] = priceVolatility[token];
        }

        return (tokens, rates, pausedStatus, volatilities);
    }

    /**
     * @dev Emergency function to reset all data
     */
    function resetAllData() external {
        // Clear all tokens
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            supportedTokens[token] = false;
            tokenRates[token] = 0;
            collectedAmounts[token] = 0;
            collectionCounts[token] = 0;
            tokensPaused[token] = false;
            priceVolatility[token] = 0;
            lastUpdateTimes[token] = 0;
            lastPriceUpdate[token] = 0;
        }

        // Clear token list
        delete tokenList;
        defaultSlippage = 100; // Reset to 1%
    }

    /**
     * @dev Get version
     */
    function getVersion() external pure returns (string memory) {
        return "MockPriceFeedEnhanced-v1.0.0";
    }

    /**
     * @dev Check if contract is operational
     */
    function isOperational() external view returns (bool) {
        return tokenList.length > 0;
    }
}