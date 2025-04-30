// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "../Libraries/Constants.sol";
/**
 * @title IStabilityFund
 * @dev Interface for the Platform Stability Fund
 */
interface IStabilityFund {

    /**
   * @dev Sets the registry contract address
    * @param _registry Address of the registry contract
    */
    function setRegistry(address _registry) external;

    /**
     * @dev Updates the token price and checks if low value mode should be activated
     * @param _newPrice New token price in stable coin units (scaled by 1e18)
     */
    function updatePrice(uint256 _newPrice) external;

    /**
     * @dev Updates the baseline price (governance function)
     * @param _newBaselinePrice New baseline price in stable coin units (scaled by 1e18)
     */
    function updateBaselinePrice(uint256 _newBaselinePrice) external;

    /**
    * @dev Updates the current fee based on token price relative to baseline
    * @return uint16 The newly calculated fee percentage
    */
    function updateCurrentFee() external returns (uint16);

    /**
     * @dev Adds stable coins to the stability reserves
     * @param _amount Amount of stable coins to add
     */
    function addReserves(uint256 _amount) external;

    /**
     * @dev Withdraws stable coins from reserves (only owner)
     * @param _amount Amount of stable coins to withdraw
     */
    function withdrawReserves(uint256 _amount) external;

    /**
     * @dev Converts ERC20 tokens to stable coins for project funding with stability protection
     * @param _project Address of the project receiving funds
     * @param _tokenAmount Amount of ERC20 tokens to convert
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins sent to the project
     */
    function convertTokensToFunding(
        address _project,
        uint256 _tokenAmount,
        uint256 _minReturn
    ) external returns (uint256 stableAmount);

    /**
     * @dev Get the reserve ratio health of the fund
     * @return uint256 Current reserve ratio (10000 = 100%)
     */
    function getReserveRatioHealth() external view returns (uint256);

/**
     * @dev Simulates a token conversion without executing it
     * @param _tokenAmount Amount of ERC20 tokens to convert
     * @return expectedValue Expected stable coin value based on current price
     * @return subsidyAmount Expected subsidy amount (if any)
     * @return finalAmount Final amount after subsidy
     * @return feeAmount Platform fee amount
     */
    function simulateConversion(uint256 _tokenAmount) external view returns (uint256 expectedValue, uint256 subsidyAmount,
        uint256 finalAmount, uint256 feeAmount);

    /**
     * @dev Updates fund parameters (only owner)
     * @param _reserveRatio New target reserve ratio
     * @param _minReserveRatio New minimum reserve ratio
     * @param _platformFeePercent New regular platform fee percentage
     * @param _lowValueFeePercent New reduced fee percentage
     * @param _valueThreshold New threshold for low value detection
     */
    function updateFundParameters(uint256 _reserveRatio, uint256 _minReserveRatio, uint256 _platformFeePercent, 
        uint256 _lowValueFeePercent, uint256 _valueThreshold) external;

    /**
     * @dev Updates the price oracle address
     * @param _newOracle New price oracle address
     */
    function updatePriceOracle(address _newOracle) external;

    /**
    * @dev Swap platform tokens for stable coins
     * @param _tokenAmount Amount of platform tokens to swap
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins received
     */
    function swapTokensForStable(uint256 _tokenAmount, uint256 _minReturn) external returns (uint256 stableAmount);

    /**
    * @dev Checks if reserve ratio is below critical threshold and pauses if needed
    * @return bool True if paused due to critical reserve ratio
    */
    function checkAndPauseIfCritical() external returns (bool);

    /**
    * @dev Manually pauses the fund in case of emergency
    */
    function emergencyPause() external;

    /**
    * @dev Resumes the fund from pause state
    */
    function resumeFromPause() external;

    /**
    * @dev Sets the critical reserve threshold percentage
    * @param _threshold New threshold as percentage of min reserve ratio
    */
    function setCriticalReserveThreshold(uint16 _threshold) external;

    /**
    * @dev Updates the emergency admin address
    * @param _newAdmin New emergency admin address
    */
    function setEmergencyAdmin(address _newAdmin) external;

    /**
     * @dev Updates fee adjustment parameters
     * @param _baseFee Base fee percentage
     * @param _maxFee Maximum fee percentage
     * @param _minFee Minimum fee percentage
     * @param _adjustmentFactor Fee adjustment curve factor
     * @param _dropThreshold Price drop threshold to begin fee adjustment
     * @param _maxDropPercent Price drop percentage for maximum fee reduction
     */
    function updateFeeParameters(uint16 _baseFee, uint16 _maxFee, uint16 _minFee, uint16 _adjustmentFactor, uint16 _dropThreshold,
        uint16 _maxDropPercent) external;

    /**
    * @dev Process burned tokens and convert a portion to reserves
    * @param _burnedAmount Amount of platform tokens that were burned
    */
    function processBurnedTokens(uint256 _burnedAmount) external;
    
    /**
     * @dev Get the verified token price
     */
    function getVerifiedPrice() external view returns (uint256);

    /**
     * @dev Process platform fees and add portion to reserves
     */
    function processPlatformFees(uint256 _feeAmount) external;

    /**
   * @dev Updates replenishment parameters
    * @param _burnPercent Percentage of burned tokens to convert to reserves
    * @param _feePercent Percentage of platform fees to add to reserves
    */
    function updateReplenishmentParameters(uint16 _burnPercent, uint16 _feePercent) external;

    /**
    * @dev Authorize or deauthorize a token burner
    * @param _burner Address of the burner
    * @param _authorized Whether the address is authorized
    */
    function setAuthBurner(address _burner, bool _authorized) external;

    function configureFlashLoanProtection(uint256 _maxDailyUserVolume, uint256 _maxSingleConversionAmount, uint256 _minTimeBetweenActions, 
        bool _enabled) external;

    function placeSuspiciousAddressInCooldown(address _suspiciousAddress) external;
    
    function removeSuspiciousAddressCooldown(address _address) external;
    
    function recordPriceObservation() external;

    // Calculate time-weighted average price
    function calculateTWAP() external view returns (uint256);

    // Configure TWAP parameters
    function configureTWAP(uint256 _windowSize, uint256 _interval, bool _enabled) external;

    /**
     * @dev Emergency notification to all connected contracts
     * Called when critical stability issues are detected
     */
    function notifyEmergencyToConnectedContracts() external;

    // Add initialization
    function initializeEmergencyRecovery(uint256 _requiredApprovals) external;

    // Add recovery function
    function initiateEmergencyRecovery() external;

    function approveRecovery() external;
    
}