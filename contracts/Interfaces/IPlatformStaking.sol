// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "./Libraries/Constants.sol";
/**
 * @title IPlatformStaking
 * @dev Interface for the TokenStaking contract
 */
interface IPlatformStaking {
    /**
     * @dev Get user stake information
     * @param _poolId The ID of the staking pool
     * @param _user The user address
     * @return amount The amount of tokens staked
     * @return startTime The timestamp when staking began
     * @return lastClaimTime The timestamp of the last reward claim
     * @return pendingReward The unclaimed reward amount
     * @return schoolBeneficiary The school address receiving 50% of rewards
     * @return userRewardPortion The user's share of the pending reward
     * @return schoolRewardPortion The school's share of the pending reward
     */
    function getUserStake(uint256 _poolId, address _user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 lastClaimTime,
        uint256 pendingReward,
        address schoolBeneficiary,
        uint256 userRewardPortion,
        uint256 schoolRewardPortion
    );

    /**
     * @dev Get number of staking pools
     */
    function getPoolCount() external view returns (uint256);

    /**
     * @dev Pause staking operations
     */
    function pauseStaking() external;

    /**
     * @dev Update voting power for a user
     */
    function updateVotingPower(address _user) external;
}