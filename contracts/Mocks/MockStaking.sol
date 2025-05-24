// MockStaking.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockStaking
 * @dev Mock implementation of ITokenStaking for testing
 */
contract MockStaking {
    // Staking pool structure
    struct StakingPool {
        uint256 totalStaked;
        uint256 rewardRate; // APY in basis points
        uint256 lockPeriod;
        uint256 minStake;
        uint256 maxStake;
        bool isActive;
        bool allowCompounding;
    }

    // User stake information
    struct UserStake {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 poolId;
        uint256 pendingRewards;
        bool isCompounding;
    }

    // Mapping of pool ID to pool info
    mapping(uint256 => StakingPool) public pools;

    // User stakes mapping (user => stake ID => stake info)
    mapping(address => mapping(uint256 => UserStake)) public userStakes;
    mapping(address => uint256) public userStakeCount;

    // Global tracking
    uint256 public totalStakedGlobal;
    uint256 public totalRewardsDistributed;
    uint256 public nextPoolId = 1;

    // Emergency controls
    bool public emergencyWithdrawalEnabled;
    bool public stakingPaused;

    // Slashing
    mapping(address => uint256) public slashedAmounts;
    uint256 public slashingRate = 1000; // 10% in basis points

    // Last operation tracking for tests
    address public lastStaker;
    uint256 public lastStakeAmount;
    uint256 public lastRewardClaimed;
    uint256 public lastUnstakeAmount;

    /**
     * @dev Create a new staking pool
     */
    function createPool(
        uint256 _rewardRate,
        uint256 _lockPeriod,
        uint256 _minStake,
        uint256 _maxStake,
        bool _allowCompounding
    ) external returns (uint256) {
        uint256 poolId = nextPoolId++;

        pools[poolId] = StakingPool({
            totalStaked: 0,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod,
            minStake: _minStake,
            maxStake: _maxStake,
            isActive: true,
            allowCompounding: _allowCompounding
        });

        return poolId;
    }

    /**
     * @dev Stake tokens in a pool
     */
    function stake(uint256 _poolId, uint256 _amount) external {
        require(pools[_poolId].isActive, "Pool not active");
        require(!stakingPaused, "Staking paused");
        require(_amount >= pools[_poolId].minStake, "Below minimum stake");
        require(_amount <= pools[_poolId].maxStake, "Above maximum stake");

        uint256 stakeId = userStakeCount[msg.sender];

        userStakes[msg.sender][stakeId] = UserStake({
            amount: _amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
            poolId: _poolId,
            pendingRewards: 0,
            isCompounding: false
        });

        userStakeCount[msg.sender]++;
        pools[_poolId].totalStaked += _amount;
        totalStakedGlobal += _amount;

        // Track for testing
        lastStaker = msg.sender;
        lastStakeAmount = _amount;
    }

    /**
     * @dev Unstake tokens
     */
    function unstake(uint256 _stakeId) external returns (uint256) {
        UserStake storage userStake = userStakes[msg.sender][_stakeId];
        require(userStake.amount > 0, "No stake found");

        StakingPool storage pool = pools[userStake.poolId];

        // Check lock period
        if (block.timestamp < userStake.startTime + pool.lockPeriod) {
            // Early withdrawal with penalty
            uint256 penalty = (userStake.amount * slashingRate) / 10000;
            slashedAmounts[msg.sender] += penalty;
            userStake.amount -= penalty;
        }

        uint256 amount = userStake.amount;

        pool.totalStaked -= amount;
        totalStakedGlobal -= amount;

        // Clear stake
        delete userStakes[msg.sender][_stakeId];

        // Track for testing
        lastUnstakeAmount = amount;

        return amount;
    }

    /**
     * @dev Claim rewards
     */
    function claimRewards(uint256 _stakeId) external returns (uint256) {
        UserStake storage userStake = userStakes[msg.sender][_stakeId];
        require(userStake.amount > 0, "No stake found");

        uint256 rewards = calculateRewards(msg.sender, _stakeId);

        userStake.lastClaimTime = block.timestamp;
        userStake.pendingRewards = 0;
        totalRewardsDistributed += rewards;

        // Track for testing
        lastRewardClaimed = rewards;

        return rewards;
    }

    /**
     * @dev Calculate pending rewards
     */
    function calculateRewards(address _user, uint256 _stakeId) public view returns (uint256) {
        UserStake storage userStake = userStakes[_user][_stakeId];
        if (userStake.amount == 0) return 0;

        StakingPool storage pool = pools[userStake.poolId];

        uint256 timeStaked = block.timestamp - userStake.lastClaimTime;
        uint256 annualReward = (userStake.amount * pool.rewardRate) / 10000;
        uint256 reward = (annualReward * timeStaked) / 365 days;

        return reward + userStake.pendingRewards;
    }

    /**
     * @dev Get user's total staked amount
     */
    function getUserTotalStaked(address _user) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < userStakeCount[_user]; i++) {
            total += userStakes[_user][i].amount;
        }
        return total;
    }

    /**
     * @dev Get user's total pending rewards
     */
    function getUserTotalRewards(address _user) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < userStakeCount[_user]; i++) {
            total += calculateRewards(_user, i);
        }
        return total;
    }

    /**
     * @dev Get pool information
     */
    function getPoolInfo(uint256 _poolId) external view returns (StakingPool memory) {
        return pools[_poolId];
    }

    /**
     * @dev Get user stake information
     */
    function getUserStake(address _user, uint256 _stakeId) external view returns (UserStake memory) {
        return userStakes[_user][_stakeId];
    }

    /**
     * @dev Enable compound staking
     */
    function enableCompounding(uint256 _stakeId) external {
        UserStake storage userStake = userStakes[msg.sender][_stakeId];
        require(userStake.amount > 0, "No stake found");
        require(pools[userStake.poolId].allowCompounding, "Compounding not allowed");

        userStake.isCompounding = true;
    }

    /**
     * @dev Compound rewards back into stake
     */
    function compoundRewards(uint256 _stakeId) external {
        UserStake storage userStake = userStakes[msg.sender][_stakeId];
        require(userStake.isCompounding, "Compounding not enabled");

        uint256 rewards = calculateRewards(msg.sender, _stakeId);

        userStake.amount += rewards;
        userStake.lastClaimTime = block.timestamp;
        userStake.pendingRewards = 0;

        pools[userStake.poolId].totalStaked += rewards;
        totalStakedGlobal += rewards;
    }

    /**
     * @dev Emergency withdrawal (admin function)
     */
    function enableEmergencyWithdrawal() external {
        emergencyWithdrawalEnabled = true;
    }

    /**
     * @dev Emergency unstake without penalties
     */
    function emergencyUnstake(uint256 _stakeId) external returns (uint256) {
        require(emergencyWithdrawalEnabled, "Emergency withdrawal not enabled");

        UserStake storage userStake = userStakes[msg.sender][_stakeId];
        require(userStake.amount > 0, "No stake found");

        uint256 amount = userStake.amount;

        pools[userStake.poolId].totalStaked -= amount;
        totalStakedGlobal -= amount;

        delete userStakes[msg.sender][_stakeId];

        return amount;
    }

    /**
     * @dev Pause/unpause staking
     */
    function pauseStaking() external {
        stakingPaused = true;
    }

    function unpauseStaking() external {
        stakingPaused = false;
    }

    /**
     * @dev Slash a user's stake (for testing governance)
     */
    function slashStake(address _user, uint256 _stakeId, uint256 _percentage) external {
        UserStake storage userStake = userStakes[_user][_stakeId];
        require(userStake.amount > 0, "No stake found");

        uint256 slashAmount = (userStake.amount * _percentage) / 10000;
        userStake.amount -= slashAmount;
        slashedAmounts[_user] += slashAmount;

        pools[userStake.poolId].totalStaked -= slashAmount;
        totalStakedGlobal -= slashAmount;
    }

    /**
     * @dev Get staking APY for a pool
     */
    function getPoolAPY(uint256 _poolId) external view returns (uint256) {
        return pools[_poolId].rewardRate;
    }

    /**
     * @dev Check if user can unstake without penalty
     */
    function canUnstakeWithoutPenalty(address _user, uint256 _stakeId) external view returns (bool) {
        UserStake storage userStake = userStakes[_user][_stakeId];
        if (userStake.amount == 0) return false;

        StakingPool storage pool = pools[userStake.poolId];
        return block.timestamp >= userStake.startTime + pool.lockPeriod;
    }

    /**
     * @dev Get total staking statistics
     */
    function getGlobalStats() external view returns (uint256, uint256, uint256) {
        return (totalStakedGlobal, totalRewardsDistributed, nextPoolId - 1);
    }
}