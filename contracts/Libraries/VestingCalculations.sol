// In a new file: VestingCalculations.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title VestingCalculations
 * @dev Library for vesting-related calculations
 */
library VestingCalculations {
    /**
     * @dev Calculates the vested amount based on vesting parameters
     * @param totalAmount Total tokens to vest
     * @param tgePercentage Percentage released at TGE (scaled by 100)
     * @param vestingMonths Vesting period in months
     * @param startTime Start time of vesting
     * @param currentTime Current time to calculate vesting for
     * @return Vested amount of tokens
     */
    function calculateVestedAmount(
        uint96 totalAmount,
        uint16 tgePercentage,
        uint16 vestingMonths,
        uint96 startTime,
        uint96 currentTime
    ) internal pure returns (uint96) {
        // Handle immediate vesting case
        if (vestingMonths == 0) {
            return totalAmount;
        }

        // Calculate TGE amount
        uint96 tgeAmount = (totalAmount * tgePercentage) / 100;

        // Calculate remaining amount to vest
        uint96 vestingAmount = totalAmount - tgeAmount;

        // Calculate elapsed time in precise units (seconds)
        uint96 elapsed = currentTime > startTime ? currentTime - startTime : 0;
        uint96 vestingPeriod = uint96(vestingMonths) * 30 days;

        // If past vesting period, return full amount
        if (elapsed >= vestingPeriod) {
            return totalAmount;
        }

        // Calculate vested portion with higher precision
        // Use fixed point math with 10^18 precision
        uint96 precision = 10**18;
        uint96 vestedPortion = (elapsed * precision) / vestingPeriod;
        uint96 vestedVestingAmount = (vestingAmount * vestedPortion) / precision;

        return tgeAmount + vestedVestingAmount;
    }
}