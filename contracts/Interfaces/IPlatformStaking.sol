// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Constants} from "../Libraries/Constants.sol";
/**
 * @title IPlatformStaking
 * @dev Interface for the TokenStaking contract
 */
interface IPlatformStaking {

    struct UnstakingRequest {
        uint96 amount;            // Amount requested to unstake
        uint96 requestTime;       // Timestamp when unstaking was requested
        bool claimed;             // Whether the unstaked tokens have been claimed
    }
    
    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external;

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external;
    
    /**
    * @dev Pause staking operations in case of emergency
     * Can be called by emergency role or automatically by StabilityFund
     */
    function pauseStaking() external;
    
    /**
    * @dev Resume staking operations after emergency
     */
    function unpauseStaking() external;

/**
     * @dev Creates a new staking pool
     * @param _name Name of the staking pool
     * @param _rewardRate Initial reward rate (tokens per block per staked token, scaled by 1e18)
     * @param _lockDuration Lock duration in seconds
     * @param _earlyWithdrawalFee Fee percentage for early withdrawals (100 = 1%)
     * @return uint256 ID of the newly created pool
     */
    function createStakingPool(
        string memory _name,
        uint256 _rewardRate,
        uint256 _lockDuration,
        uint256 _earlyWithdrawalFee
    ) external returns (uint256);

    /**
     * @dev Gets the number of registered schools
     * @return uint256 Number of registered schools
     */
    function getSchoolCount() external view returns (uint256);

    /**
     * @dev Gets details for a specific school
     * @param _school Address of the school
     * @return name School name
     * @return isRegistered Whether the school is registered
     * @return totalRewards Total rewards earned by the school
     * @return isActive Whether the school is active
     */
    function getSchoolDetails(address _school) external view returns (
        string memory name,
        bool isRegistered,
        uint256 totalRewards,
        bool isActive
    );
    
    /**
     * @dev Registers a new school in the system
     * @param _schoolAddress Address of the school
     * @param _name Name of the school
     */
    function registerSchool(address _schoolAddress, string memory _name) external;

    /**
     * @dev Updates school information
     * @param _schoolAddress Address of the school
     * @param _name New name of the school
     * @param _isActive Whether the school is active
     */
    function updateSchool(address _schoolAddress, string memory _name, bool _isActive) external;

    /**
     * @dev Withdraws school rewards to platform manager for conversion to fiat
     * @param _school Address of the school
     * @param _amount Amount to withdraw
     */
    function withdrawSchoolRewards(address _school, uint256 _amount) external;
    
    /**
    * @dev Updates the platform rewards manager address
     * @param _newManager New platform rewards manager address
     */
    function updatePlatformRewardsManager(address _newManager) external;

    /**
     * @dev Updates a staking pool's parameters
     * @param _poolId ID of the pool to update
     * @param _rewardRate New reward rate
     * @param _lockDuration New lock duration
     * @param _earlyWithdrawalFee New early withdrawal fee
     * @param _isActive Whether the pool is active
     */
    function updateStakingPool(
        uint256 _poolId,
        uint256 _rewardRate,
        uint256 _lockDuration,
        uint256 _earlyWithdrawalFee,
        bool _isActive
    ) external;

    /**
     * @dev Stakes tokens in a specific pool with school beneficiary
     * @param _poolId ID of the pool to stake in
     * @param _amount Amount of tokens to stake
     * @param _schoolBeneficiary Address of the school to receive 50% of rewards
     */
    function stake(uint256 _poolId, uint256 _amount, address _schoolBeneficiary) external;

    /**
    * @dev Unstakes tokens from a specific pool
     * @param _poolId ID of the pool to unstake from
     * @param _amount Amount of tokens to unstake
     */
    function unstake(uint256 _poolId, uint256 _amount) external;

    /**
     * @dev Claims reward from a specific pool
     * @param _poolId ID of the pool to claim from
     */
    function claimReward(uint256 _poolId) external;

    /**
     * @dev Calculates pending reward for a user in a specific pool
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return uint256 Pending reward amount (total, before 50/50 split)
     */
    function calculatePendingReward(uint256 _poolId, address _user) public view returns (uint256);

    /**
     * @dev Adjusts reward rates based on total staked tokens and available rewards
     */
    function adjustRewardRates() external;
    
    /**
    * @dev Adds tokens to the rewards pool
     * @param _amount Amount of tokens to add
     */
    function addRewardsToPool(uint256 _amount) external;

    /**
    * @dev Gets details for a specific pool
     * @param _poolId ID of the pool
     * @return name Pool name
     * @return rewardRate Reward rate
     * @return lockDuration Lock duration
     * @return earlyWithdrawalFee Early withdrawal fee
     * @return totalStaked Total amount staked in the pool
     * @return isActive Whether the pool is active
     */
    function getPoolDetails(uint256 _poolId) external view returns(
        string memory name,
        uint256 rewardRate,
        uint256 lockDuration,
        uint256 earlyWithdrawalFee,
        uint256 totalStaked,
        bool isActive
    );

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
        * @dev Gets the total amount staked by a user across all pools
     * @param _user Address of the user
     * @return uint256 Total amount staked
     */
    function getTotalUserStake(address _user) external view returns (uint256);

    /**
    * @dev Gets the estimated annual percentage yield (APY) for a pool
     * @param _poolId ID of the pool
     * @return uint256 APY percentage (scaled by 100, e.g., 1500 = 15%)
     */
    function getPoolAPY(uint256 _poolId) external view returns (uint256);
    
    /**
     * @dev Get number of staking pools
     */
    function getPoolCount() external view returns (uint256);

    /**
     * @dev Update voting power for a user
     */
    function updateVotingPower(address _user) external;

    /**
     * @dev Calculates the time remaining until a user's stake is unlocked
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return uint256 Time remaining in seconds (0 if already unlocked)
     */
    function getTimeUntilUnlock(uint256 _poolId, address _user) external view returns (uint256);

    /**
    * @dev Emergency function to recover tokens sent to the contract by mistake
     * @param _token Address of the token to recover
     * @param _amount Amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external;

    /**
    * @dev Updates the cooldown period for unstaking
    * @param _cooldownPeriod New cooldown period in seconds
    */
    function setCooldownPeriod(uint96 _cooldownPeriod) external;

    /**
    * @dev Requests to unstake tokens from a specific pool
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function requestUnstake(uint256 _poolId, uint256 _amount) external;

    /**
    * @dev Claims tokens from unstaking requests that have passed the cooldown period
    * @param _poolId ID of the pool
    * @param _requestIndex Index of the unstaking request
    */
    function claimUnstakedTokens(uint256 _poolId, uint256 _requestIndex) external;

    /**
   * @dev Get unstaking requests for a user in a specific pool
    * @param _user Address of the user
    * @param _poolId ID of the pool
    * @return requests Array of unstaking requests
    */
    function getUnstakingRequests(address _user, uint256 _poolId) external view returns (UnstakingRequest[] memory);

    /**
    * @dev Sets the emergency unstake fee
    * @param _fee Fee percentage (scaled by 100)
    */
    function setEmergencyUnstakeFee(uint16 _fee) external;

    /**
    * @dev Emergency unstake function for urgent situations
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function emergencyUnstake(uint256 _poolId, uint256 _amount) external;

    /**
     * @dev Internal helper to notify governance of stake change
     * This ensures voting power is up to date
     * @param _user User whose stake changed
     */
    function notifyGovernanceOfStakeChange(address _user) external;
}