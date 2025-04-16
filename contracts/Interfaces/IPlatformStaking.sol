// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title IPlatformStaking
 * @dev Interface for the TokenStaking contract
 */
interface IPlatformStaking {
    /**
     * @dev Get user stake information
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