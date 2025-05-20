// MockStabilityFund.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockStabilityFund
 * @dev Mock implementation of PlatformStabilityFund for testing
 */
contract MockStabilityFund {
    // Track burn notifications
    uint256 public lastBurnAmount;
    uint256 public burnNotificationCount;

    // Track fee processing
    uint256 public lastFeeAmount;
    uint256 public feeProcessingCount;

    // Conversion tracking
    mapping(address => uint256) public userConversionAmounts;
    mapping(address => uint256) public userUsdAmounts;

    // Current price
    uint96 public tokenPrice = 100000; // $0.10 default

    /**
     * @dev Process burned tokens notification
     */
    function processBurnedTokens(uint256 _burnedAmount) external {
        lastBurnAmount = _burnedAmount;
        burnNotificationCount++;
    }

    /**
     * @dev Process platform fees
     */
    function processPlatformFees(uint256 _feeAmount) external {
        lastFeeAmount = _feeAmount;
        feeProcessingCount++;
    }

    /**
     * @dev Record token purchase data
     */
    function recordTokenPurchase(address _user, uint256 _tokenAmount, uint256 _usdAmount) external {
        userConversionAmounts[_user] = _tokenAmount;
        userUsdAmounts[_user] = _usdAmount;
    }

    /**
     * @dev Get verified price
     */
    function getVerifiedPrice() external view returns (uint96) {
        return tokenPrice;
    }

    /**
     * @dev Set token price for testing
     */
    function setTokenPrice(uint96 _price) external {
        tokenPrice = _price;
    }
}