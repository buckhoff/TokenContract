// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStabilityFund
 * @dev Interface for the Platform Stability Fund
 */
interface IStabilityFund {
    /**
     * @dev Process burned tokens and add value to reserves
     */
    function processBurnedTokens(uint256 _amount) external;

    /**
     * @dev Get the verified token price
     */
    function getVerifiedPrice() external view returns (uint256);

    /**
     * @dev Process platform fees and add portion to reserves
     */
    function processPlatformFees(uint256 _feeAmount) external;

    /**
     * @dev Emergency pause function
     */
    function emergencyPause() external;
}