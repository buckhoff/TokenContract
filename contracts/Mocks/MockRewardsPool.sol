// MockRewardsPool.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockRewardsPool
 * @dev Mock implementation of rewards pool for testing
 */
contract MockRewardsPool {
    // Reward distribution tracking
    mapping(address => uint256) public userRewards;
    mapping(address => uint256) public claimedRewards;
    mapping(address => uint256) public lastRewardUpdate;

    // Pool statistics
    uint256 public totalRewardsDistributed;
    uint256 public totalRewardsClaimed;
    uint256 public rewardRate = 1000; // 10% APY in basis points
    uint256 public poolBalance;

    // Reward multipliers based on different factors
    mapping(address => uint256) public stakingMultiplier; // Based on staking amount
    mapping(address => uint256) public loyaltyMultiplier; // Based on duration
    mapping(address => uint256) public activityMultiplier; // Based on platform activity

    // Platform activity tracking
    mapping(address => uint256) public platformActivity;
    mapping(address => uint256) public lastActivityTime;

    // Special reward events
    struct RewardEvent {
        string eventType;
        uint256 rewardAmount;
        uint256 timestamp;
        bool isActive;
    }

    mapping(uint256 => RewardEvent) public rewardEvents;
    mapping(address => mapping(uint256 => bool)) public userEventParticipation;
    uint256 public nextEventId = 1;

    // Emergency controls
    bool public rewardsDistributionPaused;

    /**
     * @dev Add rewards for a user
     */
    function addRewards(address _user, uint256 _amount) external {
        require(!rewardsDistributionPaused, "Rewards distribution paused");

        userRewards[_user] += _amount;
        totalRewardsDistributed += _amount;
        lastRewardUpdate[_user] = block.timestamp;
    }

    /**
     * @dev Calculate rewards based on staking amount and duration
     */
    function calculateRewards(address _user, uint256 _stakingAmount, uint256 _duration) external view returns (uint256) {
        uint256 baseReward = (_stakingAmount * rewardRate * _duration) / (10000 * 365 days);

        // Apply multipliers
        uint256 stakingMult = stakingMultiplier[_user] > 0 ? stakingMultiplier[_user] : 10000; // Default 100%
        uint256 loyaltyMult = loyaltyMultiplier[_user] > 0 ? loyaltyMultiplier[_user] : 10000;
        uint256 activityMult = activityMultiplier[_user] > 0 ? activityMultiplier[_user] : 10000;

        uint256 totalReward = (baseReward * stakingMult * loyaltyMult * activityMult) / (10000 * 10000 * 10000);

        return totalReward;
    }

    /**
     * @dev Claim pending rewards
     */
    function claimRewards() external returns (uint256) {
        uint256 pendingRewards = userRewards[msg.sender] - claimedRewards[msg.sender];
        require(pendingRewards > 0, "No rewards to claim");

        claimedRewards[msg.sender] += pendingRewards;
        totalRewardsClaimed += pendingRewards;

        return pendingRewards;
    }

    /**
     * @dev Get pending rewards for a user
     */
    function getPendingRewards(address _user) external view returns (uint256) {
        return userRewards[_user] - claimedRewards[_user];
    }

    /**
     * @dev Set reward multipliers
     */
    function setStakingMultiplier(address _user, uint256 _multiplier) external {
        stakingMultiplier[_user] = _multiplier;
    }

    function setLoyaltyMultiplier(address _user, uint256 _multiplier) external {
        loyaltyMultiplier[_user] = _multiplier;
    }

    function setActivityMultiplier(address _user, uint256 _multiplier) external {
        activityMultiplier[_user] = _multiplier;
    }

    /**
     * @dev Record platform activity
     */
    function recordActivity(address _user, uint256 _activityScore) external {
        platformActivity[_user] += _activityScore;
        lastActivityTime[_user] = block.timestamp;

        // Update activity multiplier based on activity score
        if (platformActivity[_user] >= 10000) {
            activityMultiplier[_user] = 12000; // 20% bonus
        } else if (platformActivity[_user] >= 5000) {
            activityMultiplier[_user] = 11000; // 10% bonus
        } else {
            activityMultiplier[_user] = 10000; // No bonus
        }
    }

    /**
     * @dev Create a special reward event
     */
    function createRewardEvent(
        string memory _eventType,
        uint256 _rewardAmount
    ) external returns (uint256) {
        uint256 eventId = nextEventId++;

        rewardEvents[eventId] = RewardEvent({
            eventType: _eventType,
            rewardAmount: _rewardAmount,
            timestamp: block.timestamp,
            isActive: true
        });

        return eventId;
    }

    /**
     * @dev Participate in a reward event
     */
    function participateInEvent(uint256 _eventId) external {
        require(rewardEvents[_eventId].isActive, "Event not active");
        require(!userEventParticipation[msg.sender][_eventId], "Already participated");

        userRewards[msg.sender] += rewardEvents[_eventId].rewardAmount;
        userEventParticipation[msg.sender][_eventId] = true;
        totalRewardsDistributed += rewardEvents[_eventId].rewardAmount;
    }

    /**
     * @dev End a reward event
     */
    function endRewardEvent(uint256 _eventId) external {
        rewardEvents[_eventId].isActive = false;
    }

    /**
     * @dev Batch distribute rewards to multiple users
     */
    function batchDistributeRewards(
        address[] memory _users,
        uint256[] memory _amounts
    ) external {
        require(_users.length == _amounts.length, "Array length mismatch");
        require(!rewardsDistributionPaused, "Rewards distribution paused");

        for (uint256 i = 0; i < _users.length; i++) {
            userRewards[_users[i]] += _amounts[i];
            totalRewardsDistributed += _amounts[i];
            lastRewardUpdate[_users[i]] = block.timestamp;
        }
    }

    /**
     * @dev Calculate loyalty bonus based on staking duration
     */
    function calculateLoyaltyBonus(address _user, uint256 _stakingDuration) external view returns (uint256) {
        if (_stakingDuration >= 365 days) {
            return 15000; // 50% bonus for 1+ year
        } else if (_stakingDuration >= 180 days) {
            return 12000; // 20% bonus for 6+ months
        } else if (_stakingDuration >= 90 days) {
            return 11000; // 10% bonus for 3+ months
        } else if (_stakingDuration >= 30 days) {
            return 10500; // 5% bonus for 1+ month
        } else {
            return 10000; // No bonus
        }
    }

    /**
     * @dev Set reward rate (APY in basis points)
     */
    function setRewardRate(uint256 _newRate) external {
        require(_newRate <= 50000, "Rate too high"); // Max 500% APY
        rewardRate = _newRate;
    }

    /**
     * @dev Add funds to the reward pool
     */
    function addPoolFunds(uint256 _amount) external {
        poolBalance += _amount;
    }

    /**
     * @dev Get user's reward statistics
     */
    function getUserRewardStats(address _user) external view returns (
        uint256 totalRewards,
        uint256 claimedAmount,
        uint256 pendingAmount,
        uint256 lastUpdate,
        uint256 stakingMult,
        uint256 loyaltyMult,
        uint256 activityMult
    ) {
        totalRewards = userRewards[_user];
        claimedAmount = claimedRewards[_user];
        pendingAmount = totalRewards - claimedAmount;
        lastUpdate = lastRewardUpdate[_user];
        stakingMult = stakingMultiplier[_user];
        loyaltyMult = loyaltyMultiplier[_user];
        activityMult = activityMultiplier[_user];
    }

    /**
     * @dev Get pool statistics
     */
    function getPoolStats() external view returns (
        uint256 totalDistributed,
        uint256 totalClaimed,
        uint256 currentRate,
        uint256 balance,
        bool isPaused
    ) {
        totalDistributed = totalRewardsDistributed;
        totalClaimed = totalRewardsClaimed;
        currentRate = rewardRate;
        balance = poolBalance;
        isPaused = rewardsDistributionPaused;
    }

    /**
     * @dev Emergency pause/unpause rewards distribution
     */
    function pauseRewardsDistribution() external {
        rewardsDistributionPaused = true;
    }

    function unpauseRewardsDistribution() external {
        rewardsDistributionPaused = false;
    }

    /**
     * @dev Emergency drain pool (admin function)
     */
    function emergencyDrainPool() external returns (uint256) {
        uint256 amount = poolBalance;
        poolBalance = 0;
        return amount;
    }

    /**
     * @dev Check if user participated in event
     */
    function hasParticipatedInEvent(address _user, uint256 _eventId) external view returns (bool) {
        return userEventParticipation[_user][_eventId];
    }

    /**
     * @dev Get event details
     */
    function getEventDetails(uint256 _eventId) external view returns (RewardEvent memory) {
        return rewardEvents[_eventId];
    }

    /**
     * @dev Calculate projected rewards for a period
     */
    function calculateProjectedRewards(
        address _user,
        uint256 _stakingAmount,
        uint256 _projectionPeriod
    ) external view returns (uint256) {
        uint256 baseProjection = (_stakingAmount * rewardRate * _projectionPeriod) / (10000 * 365 days);

        // Apply current multipliers
        uint256 stakingMult = stakingMultiplier[_user] > 0 ? stakingMultiplier[_user] : 10000;
        uint256 loyaltyMult = loyaltyMultiplier[_user] > 0 ? loyaltyMultiplier[_user] : 10000;
        uint256 activityMult = activityMultiplier[_user] > 0 ? activityMultiplier[_user] : 10000;

        return (baseProjection * stakingMult * loyaltyMult * activityMult) / (10000 * 10000 * 10000);
    }
}