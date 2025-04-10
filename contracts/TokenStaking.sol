// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenStaking
 * @dev Contract for staking TEACH tokens to earn rewards with 50/50 split between users and schools
 */
contract TokenStaking is Ownable, ReentrancyGuard, AccessControl {
    using Math for uint256;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    // The TeachToken contract
    IERC20 public teachToken;
    
    // Struct for staking pool information
    struct StakingPool {
        string name;
        uint256 rewardRate;           // Tokens per block per staked token (scaled by 1e18)
        uint256 lockDuration;         // Lock period in seconds
        uint256 earlyWithdrawalFee;   // Fee percentage for early withdrawals (100 = 1%)
        uint256 totalStaked;          // Total tokens staked in this pool
        bool isActive;                // Whether the pool is active
    }
    
    // Struct for user stake information
    struct UserStake {
        uint256 amount;               // Amount of tokens staked
        uint256 startTime;            // Timestamp when staking started
        uint256 lastClaimTime;        // Timestamp of last reward claim
        uint256 accumulatedRewards;   // Unclaimed rewards
        address schoolBeneficiary;    // School address to receive 50% of rewards
    }
    
    // Struct for school information
    struct School {
        string name;                  // School name
        bool isRegistered;            // Whether school is registered
        uint256 totalRewards;         // Total rewards earned by school
        bool isActive;                // Whether school is active
    }

    struct UnstakingRequest {
        uint96 amount;            // Amount requested to unstake
        uint96 requestTime;       // Timestamp when unstaking was requested
        bool claimed;             // Whether the unstaked tokens have been claimed
    }

    mapping(address => mapping(uint256 => UnstakingRequest[])) public unstakingRequests;
    
    // School registry
    mapping(address => School) public schools;
    address[] public registeredSchools;
    
    uint16 public emergencyUnstakeFee;
    
    // Platform managed school rewards
    address public platformRewardsManager;
    
    // Array of staking pools
    StakingPool[] public stakingPools;
    
    // Mapping from pool ID to user address to stake details
    mapping(uint256 => mapping(address => UserStake)) public userStakes;
    
    // Total rewards paid out
    uint256 public totalRewardsPaid;
    
    // Total staking rewards pool (tokens allocated for rewards)
    uint256 public rewardsPool;
    
    // Timestamp of last reward rate adjustment
    uint256 public lastRewardAdjustment;

    uint96 public cooldownPeriod;
    
    // Events
    event StakingPoolCreated(uint256 indexed poolId, string name, uint256 rewardRate, uint256 lockDuration);
    event StakingPoolUpdated(uint256 indexed poolId, uint256 rewardRate, uint256 lockDuration, uint256 earlyWithdrawalFee, bool isActive);
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount, address indexed schoolBeneficiary);
    event Unstaked(address indexed user, uint256 indexed poolId, uint256 amount, uint256 fee);
    event RewardClaimed(address indexed user, uint256 indexed poolId, uint256 userReward, address indexed schoolBeneficiary, uint256 schoolReward);
    event SchoolRewardWithdrawn(address indexed school, uint256 amount);
    event SchoolRegistered(address indexed schoolAddress, string name);
    event SchoolUpdated(address indexed schoolAddress, string name, bool isActive);
    event RewardsAdded(uint256 amount);
    event RewardRatesAdjusted();
    event PlatformRewardsManagerUpdated(address indexed oldManager, address indexed newManager);
    event UnstakingRequested(address indexed user, uint256 indexed poolId, uint256 amount, uint256 requestTime);
    event UnstakedTokensClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    
    /**
     * @dev Modifier to restrict school reward withdrawals to platform manager
     */
    modifier onlyPlatformManager() {
        require(msg.sender == platformRewardsManager, "TokenStaking: not platform manager");
        _;
    }
    
    /**
     * @dev Constructor sets the token address and platform rewards manager
     * @param _teachToken Address of the TEACH token
     * @param _platformRewardsManager Address of the platform rewards manager
     */
    constructor(address _teachToken, address _platformRewardsManager) Ownable(msg.sender) {
        require(_teachToken != address(0), "TokenStaking: zero token address");
        require(_platformRewardsManager != address(0), "TokenStaking: zero platform manager address");
        
        teachToken = IERC20(_teachToken);
        platformRewardsManager = _platformRewardsManager;
        lastRewardAdjustment = block.timestamp;
        cooldownPeriod = 2 days; // 2-day cooldown by default
        emergencyUnstakeFee = 2000; // 20% fee by default
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, _platformRewardsManager);
        _setupRole(EMERGENCY_ROLE, msg.sender);
    }
    
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
    ) external onlyRole(ADMIN_ROLE) returns (uint256) {
        require(bytes(_name).length > 0, "TokenStaking: empty pool name");
        require(_earlyWithdrawalFee <= 3000, "TokenStaking: fee too high");
        
        uint256 poolId = stakingPools.length;
        
        stakingPools.push(StakingPool({
            name: _name,
            rewardRate: _rewardRate,
            lockDuration: _lockDuration,
            earlyWithdrawalFee: _earlyWithdrawalFee,
            totalStaked: 0,
            isActive: true
        }));
        
        emit StakingPoolCreated(poolId, _name, _rewardRate, _lockDuration);
        
        return poolId;
    }
    
    /**
     * @dev Registers a new school in the system
     * @param _schoolAddress Address of the school
     * @param _name Name of the school
     */
    function registerSchool(address _schoolAddress, string memory _name) external onlyRole(ADMIN_ROLE) {
        require(_schoolAddress != address(0), "TokenStaking: zero school address");
        require(bytes(_name).length > 0, "TokenStaking: empty school name");
        require(!schools[_schoolAddress].isRegistered, "TokenStaking: already registered");
        
        schools[_schoolAddress] = School({
            name: _name,
            isRegistered: true,
            totalRewards: 0,
            isActive: true
        });
        
        registeredSchools.push(_schoolAddress);
        
        emit SchoolRegistered(_schoolAddress, _name);
    }
    
    /**
     * @dev Updates school information
     * @param _schoolAddress Address of the school
     * @param _name New name of the school
     * @param _isActive Whether the school is active
     */
    function updateSchool(address _schoolAddress, string memory _name, bool _isActive) external onlyRole(ADMIN_ROLE) {
        require(schools[_schoolAddress].isRegistered, "TokenStaking: school not registered");
        
        schools[_schoolAddress].name = _name;
        schools[_schoolAddress].isActive = _isActive;
        
        emit SchoolUpdated(_schoolAddress, _name, _isActive);
    }
    
    /**
     * @dev Updates the platform rewards manager address
     * @param _newManager New platform rewards manager address
     */
    function updatePlatformRewardsManager(address _newManager) external onlyRole(ADMIN_ROLE) {
        require(_newManager != address(0), "TokenStaking: zero manager address");
        
        emit PlatformRewardsManagerUpdated(platformRewardsManager, _newManager);
        
        platformRewardsManager = _newManager;
    }
    
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
    ) external onlyRole(ADMIN_ROLE) {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        require(_earlyWithdrawalFee <= 3000, "TokenStaking: fee too high");
        
        StakingPool storage pool = stakingPools[_poolId];
        
        pool.rewardRate = _rewardRate;
        pool.lockDuration = _lockDuration;
        pool.earlyWithdrawalFee = _earlyWithdrawalFee;
        pool.isActive = _isActive;
        
        emit StakingPoolUpdated(_poolId, _rewardRate, _lockDuration, _earlyWithdrawalFee, _isActive);
    }
    
    /**
     * @dev Stakes tokens in a specific pool with school beneficiary
     * @param _poolId ID of the pool to stake in
     * @param _amount Amount of tokens to stake
     * @param _schoolBeneficiary Address of the school to receive 50% of rewards
     */
    function stake(uint256 _poolId, uint256 _amount, address _schoolBeneficiary) external nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        require(_amount > 0, "TokenStaking: zero amount");
        require(_amount <= teachToken.balanceOf(msg.sender), "TokenStaking: insufficient balance");
        require(_amount <= teachToken.allowance(msg.sender, address(this)), "TokenStaking: insufficient allowance");
        require(schools[_schoolBeneficiary].isRegistered, "TokenStaking: school not registered");
        require(schools[_schoolBeneficiary].isActive, "TokenStaking: school not active");
        
        StakingPool storage pool = stakingPools[_poolId];
        require(pool.isActive, "TokenStaking: pool not active");
        
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        
        // If user already has a stake, claim pending rewards first
        if (userStake.amount > 0) {
            _claimReward(_poolId, msg.sender);
        }
        
        // Update user stake
        if (userStake.amount == 0) {
            // New stake
            userStake.startTime = block.timestamp;
            userStake.lastClaimTime = block.timestamp;
        }
        
        userStake.amount += _amount;
        userStake.schoolBeneficiary = _schoolBeneficiary;
        
        // Update pool total staked
        pool.totalStaked += _amount;
        
        // Transfer tokens from user to contract
        require(teachToken.transferFrom(msg.sender, address(this), _amount), "TokenStaking: transfer failed");
        
        emit Staked(msg.sender, _poolId, _amount, _schoolBeneficiary);

        assert(userStake.amount <= pool.totalStaked);
    }
    
    /**
     * @dev Unstakes tokens from a specific pool
     * @param _poolId ID of the pool to unstake from
     * @param _amount Amount of tokens to unstake
     */
    function unstake(uint256 _poolId, uint256 _amount) external nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        require(_amount > 0, "TokenStaking: zero amount");
        
        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        
        require(userStake.amount >= _amount, "TokenStaking: insufficient stake");
        
        // Claim pending rewards first
        _claimReward(_poolId, msg.sender);
        
        // Calculate early withdrawal fee if applicable
        uint256 fee = 0;
        if (block.timestamp < userStake.startTime + pool.lockDuration) {
            fee = (_amount * pool.earlyWithdrawalFee) / 10000;
        }
        
        uint256 amountToReturn = _amount - fee;
        
        // Update user stake
        userStake.amount -= _amount;
        
        // Update pool total staked
        pool.totalStaked -= _amount;
        
        // If fee is applied, it stays in the contract as part of the rewards pool
        if (fee > 0) {
            rewardsPool += fee;
        }
        
        // Transfer tokens back to user
        require(teachToken.transfer(msg.sender, amountToReturn), "TokenStaking: transfer failed");
        
        emit Unstaked(msg.sender, _poolId, _amount, fee);
    }
    
    /**
     * @dev Claims reward from a specific pool
     * @param _poolId ID of the pool to claim from
     */
    function claimReward(uint256 _poolId) external nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        
        uint256 reward = _claimReward(_poolId, msg.sender);
        require(reward > 0, "TokenStaking: no rewards");
    }
    
    /**
     * @dev Internal function to calculate and distribute rewards (50/50 split)
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return uint256 Total reward amount (user portion + school portion)
     */
    function _claimReward(uint256 _poolId, address _user) internal returns (uint256) {
        UserStake storage userStake = userStakes[_poolId][_user];
        
        if (userStake.amount == 0) {
            return 0;
        }
        
        // Calculate pending rewards
        uint256 totalReward = calculatePendingReward(_poolId, _user);
        
        if (totalReward == 0) {
            return 0;
        }
        
        // Get school beneficiary
        address schoolBeneficiary = userStake.schoolBeneficiary;
        require(schools[schoolBeneficiary].isRegistered, "TokenStaking: school not registered");
        
        // Split rewards 50/50
        uint256 userReward = totalReward / 2;
        uint256 schoolReward = totalReward - userReward; // Use subtraction to handle odd numbers
        
        // Update user's last claim time
        userStake.lastClaimTime = block.timestamp;
        
        // Update total rewards paid
        totalRewardsPaid += totalReward;
        
        // Ensure we have enough rewards to pay out
        require(totalReward <= rewardsPool, "TokenStaking: insufficient rewards");
        
        // Update rewards pool
        rewardsPool -= totalReward;
        
        // Update school's total rewards
        schools[schoolBeneficiary].totalRewards += schoolReward;
        
        // Transfer user portion to user
        require(teachToken.transfer(_user, userReward), "TokenStaking: user transfer failed");
        
        // School portion remains in contract to be managed by platform
        
        emit RewardClaimed(_user, _poolId, userReward, schoolBeneficiary, schoolReward);

        assert(rewardsPool == oldRewardsPool - totalReward);
        assert(teachToken.balanceOf(_user) == oldUserBalance + userReward);
        
        return totalReward;
    }
    
    /**
     * @dev Withdraws school rewards to platform manager for conversion to fiat
     * @param _school Address of the school
     * @param _amount Amount to withdraw
     */
    function withdrawSchoolRewards(address _school, uint256 _amount) external onlyRole(MANAGER_ROLE) nonReentrant {
        require(schools[_school].isRegistered, "TokenStaking: school not registered");
        require(_amount > 0, "TokenStaking: zero amount");
        require(_amount <= schools[_school].totalRewards, "TokenStaking: insufficient school rewards");
        
        // Update school's total rewards
        schools[_school].totalRewards -= _amount;
        
        // Transfer tokens to platform manager for conversion
        require(teachToken.transfer(platformRewardsManager, _amount), "TokenStaking: transfer failed");
        
        emit SchoolRewardWithdrawn(_school, _amount);
    }
    
    /**
     * @dev Calculates pending reward for a user in a specific pool
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return uint256 Pending reward amount (total, before 50/50 split)
     */
    function calculatePendingReward(uint256 _poolId, address _user) public view returns (uint256) {
        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][_user];
        
        if (userStake.amount == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp - userStake.lastClaimTime;
        
        // Calculate rewards based on staked amount, time elapsed, and reward rate
        // Simplified calculation: amount * rewardRate * timeElapsed / (365 days)
        uint256 pendingReward = (userStake.amount * pool.rewardRate * timeElapsed) / (365 days) / 1e18;
        
        return pendingReward;
    }
    
    /**
     * @dev Adds tokens to the rewards pool
     * @param _amount Amount of tokens to add
     */
    function addRewardsToPool(uint256 _amount) external nonReentrant {
        require(_amount > 0, "TokenStaking: zero amount");
        
        // Transfer tokens to the contract
        require(teachToken.transferFrom(msg.sender, address(this), _amount), "TokenStaking: transfer failed");
        
        // Update rewards pool
        rewardsPool += _amount;
        
        emit RewardsAdded(_amount);
    }
    
    /**
     * @dev Adjusts reward rates based on total staked tokens and available rewards
     */
    function adjustRewardRates() external onlyOwner {
        uint256 totalStakedAcrossPools = 0;
        
        // Calculate total staked tokens across all pools
        for (uint256 i = 0; i < stakingPools.length; i++) {
            if (stakingPools[i].isActive) {
                totalStakedAcrossPools += stakingPools[i].totalStaked;
            }
        }
        
        if (totalStakedAcrossPools == 0) {
            return; // No adjustments needed if no tokens are staked
        }
        
        // Calculate sustainable reward rate based on rewards pool and total staked
        uint256 timeUntilDepletion = 365 days; // Target 1 year depletion timeline
        uint256 sustainableRewardRate = (rewardsPool * 1e18) / totalStakedAcrossPools / timeUntilDepletion * 365 days;
        
        // Adjust rates for each pool
        for (uint256 i = 0; i < stakingPools.length; i++) {
            if (stakingPools[i].isActive) {
                // Apply adjustment based on pool's current rate relative to others
                StakingPool storage pool = stakingPools[i];
                pool.rewardRate = sustainableRewardRate;
            }
        }
        
        lastRewardAdjustment = block.timestamp;
        
        emit RewardRatesAdjusted();
    }
    
    /**
     * @dev Gets the number of staking pools
     * @return uint256 Number of staking pools
     */
    function getPoolCount() external view returns (uint256) {
        return stakingPools.length;
    }
    
    /**
     * @dev Gets the number of registered schools
     * @return uint256 Number of registered schools
     */
    function getSchoolCount() external view returns (uint256) {
        return registeredSchools.length;
    }
    
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
    function getPoolDetails(uint256 _poolId) external view returns (
        string memory name,
        uint256 rewardRate,
        uint256 lockDuration,
        uint256 earlyWithdrawalFee,
        uint256 totalStaked,
        bool isActive
    ) {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        
        StakingPool storage pool = stakingPools[_poolId];
        
        return (
            pool.name,
            pool.rewardRate,
            pool.lockDuration,
            pool.earlyWithdrawalFee,
            pool.totalStaked,
            pool.isActive
        );
    }
    
    /**
     * @dev Gets stake details for a specific user in a specific pool
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return amount Amount staked
     * @return startTime Timestamp when staking started
     * @return lastClaimTime Timestamp of last reward claim
     * @return pendingReward Pending reward amount (total, before 50/50 split)
     * @return schoolBeneficiary School beneficiary address
     * @return userRewardPortion User portion of pending rewards (50%)
     * @return schoolRewardPortion School portion of pending rewards (50%)
     */
    function getUserStake(uint256 _poolId, address _user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 lastClaimTime,
        uint256 pendingReward,
        address schoolBeneficiary,
        uint256 userRewardPortion,
        uint256 schoolRewardPortion
    ) {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        
        UserStake storage userStake = userStakes[_poolId][_user];
        pendingReward = calculatePendingReward(_poolId, _user);
        
        // Calculate 50/50 split
        userRewardPortion = pendingReward / 2;
        schoolRewardPortion = pendingReward - userRewardPortion; // Use subtraction to handle odd numbers
        
        return (
            userStake.amount,
            userStake.startTime,
            userStake.lastClaimTime,
            pendingReward,
            userStake.schoolBeneficiary,
            userRewardPortion,
            schoolRewardPortion
        );
    }
    
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
    ) {
        School storage school = schools[_school];
        
        return (
            school.name,
            school.isRegistered,
            school.totalRewards,
            school.isActive
        );
    }
    
    /**
     * @dev Gets the total amount staked by a user across all pools
     * @param _user Address of the user
     * @return uint256 Total amount staked
     */
    function getTotalUserStake(address _user) external view returns (uint256) {
        uint256 totalStake = 0;
        
        for (uint256 i = 0; i < stakingPools.length; i++) {
            totalStake += userStakes[i][_user].amount;
        }
        
        return totalStake;
    }
    
    /**
     * @dev Gets the estimated annual percentage yield (APY) for a pool
     * @param _poolId ID of the pool
     * @return uint256 APY percentage (scaled by 100, e.g., 1500 = 15%)
     */
    function getPoolAPY(uint256 _poolId) external view returns (uint256) {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        
        StakingPool storage pool = stakingPools[_poolId];
        
        // Calculate APY based on the reward rate
        // rewardRate is tokens per staked token per year (scaled by 1e18)
        // We convert it to a percentage by multiplying by 100
        return (pool.rewardRate * 100) / 1e18;
    }
    
    /**
     * @dev Calculates the time remaining until a user's stake is unlocked
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return uint256 Time remaining in seconds (0 if already unlocked)
     */
    function getTimeUntilUnlock(uint256 _poolId, address _user) external view returns (uint256) {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        
        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][_user];
        
        if (userStake.amount == 0) {
            return 0;
        }
        
        uint256 unlockTime = userStake.startTime + pool.lockDuration;
        
        if (block.timestamp >= unlockTime) {
            return 0;
        }
        
        return unlockTime - block.timestamp;
    }
    
    /**
     * @dev Emergency function to recover tokens sent to the contract by mistake
     * @param _token Address of the token to recover
     * @param _amount Amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(teachToken), "TokenStaking: cannot recover staking token");
        
        IERC20 token = IERC20(_token);
        require(token.transfer(owner(), _amount), "TokenStaking: transfer failed");
    }

    /**
    * @dev Updates the cooldown period for unstaking
    * @param _cooldownPeriod New cooldown period in seconds
    */
    function setCooldownPeriod(uint96 _cooldownPeriod) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
    }

    /**
    * @dev Requests to unstake tokens from a specific pool
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function requestUnstake(uint256 _poolId, uint256 _amount) external nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        require(_amount > 0, "TokenStaking: zero amount");

        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];

        require(userStake.amount >= _amount, "TokenStaking: insufficient stake");

        // Claim pending rewards first
        _claimReward(_poolId, msg.sender);

        // Calculate early withdrawal fee if applicable
        uint256 fee = 0;
        if (block.timestamp < userStake.startTime + pool.lockDuration) {
            fee = (_amount * pool.earlyWithdrawalFee) / 10000;
        }

        uint256 amountAfterFee = _amount - fee;

        // Update user stake
        userStake.amount -= _amount;

        // Update pool total staked
        pool.totalStaked -= _amount;

        // If fee is applied, it stays in the contract as part of the rewards pool
        if (fee > 0) {
            rewardsPool += fee;
        }

        // Create unstaking request
        unstakingRequests[msg.sender][_poolId].push(UnstakingRequest({
            amount: uint96(amountAfterFee),
            requestTime: uint96(block.timestamp),
            claimed: false
        }));

        emit UnstakingRequested(msg.sender, _poolId, _amount, block.timestamp);
    }

    /**
    * @dev Claims tokens from unstaking requests that have passed the cooldown period
    * @param _poolId ID of the pool
    * @param _requestIndex Index of the unstaking request
    */
    function claimUnstakedTokens(uint256 _poolId, uint256 _requestIndex) external nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");

        UnstakingRequest[] storage requests = unstakingRequests[msg.sender][_poolId];
        require(_requestIndex < requests.length, "TokenStaking: invalid request index");

        UnstakingRequest storage request = requests[_requestIndex];
        require(!request.claimed, "TokenStaking: already claimed");
        require(block.timestamp >= request.requestTime + cooldownPeriod, "TokenStaking: cooldown not over");

        uint96 amountToClaim = request.amount;

        // Mark as claimed
        request.claimed = true;

        // Transfer tokens back to user
        require(teachToken.transfer(msg.sender, amountToClaim), "TokenStaking: transfer failed");

        emit UnstakedTokensClaimed(msg.sender, _poolId, amountToClaim);
    }

    /**
    * @dev Get unstaking requests for a user in a specific pool
    * @param _user Address of the user
    * @param _poolId ID of the pool
    * @return requests Array of unstaking requests
    */
    function getUnstakingRequests(address _user, uint256 _poolId) external view returns (UnstakingRequest[] memory) {
        return unstakingRequests[_user][_poolId];
    }

    /**
    * @dev Sets the emergency unstake fee
    * @param _fee Fee percentage (scaled by 100)
    */
    function setEmergencyUnstakeFee(uint16 _fee) external onlyOwner {
        require(_fee <= 5000, "TokenStaking: fee too high"); // Max 50%
        emergencyUnstakeFee = _fee;
    }

    /**
    * @dev Emergency unstake function for urgent situations
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function emergencyUnstake(uint256 _poolId, uint256 _amount) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(_poolId < stakingPools.length, "TokenStaking: invalid pool ID");
        require(_amount > 0, "TokenStaking: zero amount");

        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];

        require(userStake.amount >= _amount, "TokenStaking: insufficient stake");

        // Claim pending rewards first
        _claimReward(_poolId, msg.sender);

        // Calculate emergency fee (higher than regular early withdrawal fee)
        uint256 emergencyFee = (_amount * emergencyUnstakeFee) / 10000;
        uint256 amountToReturn = _amount - emergencyFee;

        // Update user stake
        userStake.amount -= _amount;

        // Update pool total staked
        pool.totalStaked -= _amount;

        // Add fee to rewards pool
        rewardsPool += emergencyFee;

        // Transfer tokens immediately to user (no cooldown)
        require(teachToken.transfer(msg.sender, amountToReturn), "TokenStaking: transfer failed");

        emit Unstaked(msg.sender, _poolId, _amount, emergencyFee);
    }

    function _verifyTokenBalanceInvariant() internal view {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < stakingPools.length; i++) {
            totalStaked += stakingPools[i].totalStaked;
        }
        assert(teachToken.balanceOf(address(this)) == totalStaked + rewardsPool);
    }
}