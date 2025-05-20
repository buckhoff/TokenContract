// MockPriceFeed.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockPriceFeed
 * @dev Mock implementation of ITokenPriceFeed for testing
 */
contract MockPriceFeed {
    // Supported tokens
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    // Token conversion rates (token -> USD, scaled by 1e6)
    mapping(address => uint256) public tokenRates;

    // Collection tracking
    mapping(address => uint256) public collectedAmounts;

    /**
     * @dev Constructor to set up default token
     */
    constructor(address _defaultToken) {
        addSupportedToken(_defaultToken, 1000000); // $1.00 per token
    }

    /**
     * @dev Add a supported token
     */
    function addSupportedToken(address _token, uint256 _rate) public {
        if (!supportedTokens[_token]) {
            supportedTokens[_token] = true;
            tokenList.push(_token);
        }
        tokenRates[_token] = _rate;
    }

    /**
     * @dev Check if token is supported
     */
    function isTokenSupported(address _token) external view returns (bool) {
        return supportedTokens[_token];
    }

    /**
     * @dev Get all supported payment tokens
     */
    function getSupportedPaymentTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /**
     * @dev Convert token amount to USD
     */
    function convertTokenToUsd(address _token, uint256 _amount) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");

        // Convert based on rate (1 token = rate USD)
        return (_amount * tokenRates[_token]) / 1e18;
    }

    /**
     * @dev Convert USD amount to token
     */
    function convertUsdToToken(address _token, uint256 _usdAmount) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");

        // Convert based on rate (rate USD = 1 token)
        return (_usdAmount * 1e18) / tokenRates[_token];
    }

    /**
     * @dev Record payment collection
     */
    function recordPaymentCollection(address _token, uint256 _amount) external {
        require(supportedTokens[_token], "Token not supported");
        collectedAmounts[_token] += _amount;
    }

    /**
     * @dev Get token USD price
     */
    function getTokenUsdPrice(address _token) external view returns (uint256) {
        require(supportedTokens[_token], "Token not supported");
        return tokenRates[_token];
    }
}