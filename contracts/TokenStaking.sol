// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import {IPlatformStaking} from "./Interfaces/IPlatformStaking.sol";

/**
 * @title TokenStaking
 * @dev Contract for staking tokens to earn rewards with 50/50 split between users and schools
 */
contract TokenStaking is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    RegistryAwareUpgradeable,
    IPlatformStaking,
    UUPSUpgradeable
{
    
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

    ERC20Upgradeable internal token;
    
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

    // Flag for emergency pause
    bool public paused;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;
    
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
    event PlatformGovernanceUpdateFailed(address indexed user, string error);
    event UnstakingRequested(address indexed user, uint256 indexed poolId, uint256 amount, uint256 requestTime);
    event UnstakedTokensClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event AddressPlacedInCooldown(address indexed suspiciousAddress, uint256 endTime);
    event AddressRemovedFromCooldown(address indexed cooldownaddress);
    event FlashLoanProtectionConfigured(uint256 maxDailyUserVolume, uint256 maxSingleConversionAmount, uint256 minTimeBetweenActions, bool enabled);
    event ExternalCallFailed(string method, address target);

    error NotPlatformManager();
    error ZeroTokenAddress();
    error ZeroPlatformManagerAddress();
    error SystemStillPaused();
    error EmptyPoolName();
    error FeeTooHigh();
    error ZeroSchoolAddress();
    error EmptySchoolName();
    error SchoolAlreadyRegistered();
    error SchoolNotRegistered();
    error ZeroManagerAddress();
    error InvalidPoolId();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error SchoolNotActive();
    error PoolNotActive();
    error TransferFailed();
    error InsufficientStake();
    error NoRewards();
    error InsufficientRewards();
    error UserTransferFailed();
    error InsufficientSchoolRewards();
    error AlreadyClaimed();
    error CooldownNotOver();
    error CannotRecoverStakingToken();
    error InvalidRequestIndex();
    error FeeTooHighEmergency();
    error OnlySelf();

    /**
     * @dev Modifier to restrict school reward withdrawals to platform manager
     */
    modifier onlyPlatformManager() {
        if (msg.sender != platformRewardsManager) revert NotPlatformManager();
        _;
    }

    /**
     * @dev Initializes the contract with initial parameters
     * @param _token Address of the platform token
     * @param _platformRewardsManager Address of the platform rewards manager
     */
    function initialize(
    address _token, address _platformRewardsManager) initializer public {
        if (_token == address(0)) revert ZeroTokenAddress();
        if (_platformRewardsManager == address(0)) revert ZeroPlatformManagerAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        token = ERC20Upgradeable(_token);
        platformRewardsManager = _platformRewardsManager;
        lastRewardAdjustment = block.timestamp;
        cooldownPeriod = 2 days; // 2-day cooldown by default
        emergencyUnstakeFee = 2000; // 20% fee by default
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.MANAGER_ROLE, _platformRewardsManager);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }
    
    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRegistry(_registry, keccak256("TOKEN_STAKING"));
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyRole(Constants.ADMIN_ROLE) {
        if (address(registry) == address(0)) revert RegistryNotSet();

        // Update Token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newToken = registry.getContractAddress(Constants.TOKEN_NAME);
            if (newToken== address(0)) revert ZeroTokenAddress();
            
            address oldToken = address(token);

            if (newToken != oldToken) {
                token = ERC20Upgradeable(newToken);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, newToken);
            }
        }
    }

    /**
     * @dev Pause staking operations in case of emergency
     * Can be called by emergency role or automatically by StabilityFund
     */
    function pauseStaking() external {
        if (address(registry) != address(0)) {
            if (registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
                address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

                if (stabilityFund== address(0)) revert ZeroTokenAddress();
                
                if (registry.isContractActive(Constants.GOVERNANCE_NAME)) {
                    address governance = registry.getContractAddress(Constants.GOVERNANCE_NAME);
                    if (governance == address(0)) revert ZeroTokenAddress();

                    if (
                        msg.sender != stabilityFund &&
                        msg.sender != governance &&
                        !hasRole(Constants.EMERGENCY_ROLE, msg.sender)) {
                        revert NotAuthorized();
                    }
                } else {
                    if (
                        msg.sender != stabilityFund &&
                        !hasRole(Constants.EMERGENCY_ROLE, msg.sender)) {
                        revert NotAuthorized();
                    }
                }
            } else {
                if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
            }
        } else {
            if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
        }

        paused = true;
    }

    /**
     * @dev Resume staking operations after emergency
     */
    function unpauseStaking() external onlyRole(Constants.EMERGENCY_ROLE) {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if (systemPaused) revert SystemStillPaused();
            } catch {
                // If registry call fails, proceed with unpause
            }
        }

        paused = false;
    }

    function _isContractPaused() internal override view returns (bool) {
        return paused;
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
    ) external onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        if (bytes(_name).length == 0) revert EmptyPoolName();
        if (_earlyWithdrawalFee > 3000) revert FeeTooHigh();
        
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
    function registerSchool(address _schoolAddress, string memory _name) external onlyRole(Constants.ADMIN_ROLE) {
        if (_schoolAddress == address(0)) revert ZeroSchoolAddress();
        if (bytes(_name).length == 0) revert EmptySchoolName();
        if (schools[_schoolAddress].isRegistered) revert SchoolAlreadyRegistered();
        
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
    function updateSchool(address _schoolAddress, string memory _name, bool _isActive) external onlyRole(Constants.ADMIN_ROLE) {
        if (!schools[_schoolAddress].isRegistered) revert SchoolNotRegistered();
        
        schools[_schoolAddress].name = _name;
        schools[_schoolAddress].isActive = _isActive;
        
        emit SchoolUpdated(_schoolAddress, _name, _isActive);
    }
    
    /**
     * @dev Updates the platform rewards manager address
     * @param _newManager New platform rewards manager address
     */
    function updatePlatformRewardsManager(address _newManager) external onlyRole(Constants.ADMIN_ROLE) {
        if (_newManager == address(0)) revert ZeroManagerAddress();
        
        emit PlatformRewardsManagerUpdated(platformRewardsManager, _newManager);
        
        platformRewardsManager = _newManager;
        _grantRole(Constants.MANAGER_ROLE, _newManager);
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
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        if (_earlyWithdrawalFee > 3000) revert FeeTooHigh();
        
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
    function stake(uint256 _poolId, uint256 _amount, address _schoolBeneficiary) external nonReentrant whenContractNotPaused {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        if (_amount == 0) revert ZeroAmount();

        // Get token from registry if available
        if (address(registry) != address(0) && registry.isContractActive(Constants.TOKEN_NAME)) {
            token = ERC20Upgradeable(registry.getContractAddress(Constants.TOKEN_NAME));
        }

        if (address(token) == address(0)) revert ZeroTokenAddress();
        
        if (_amount > token.balanceOf(msg.sender)) revert InsufficientBalance();
        if (_amount > token.allowance(msg.sender, address(this))) revert InsufficientAllowance();
        if (!schools[_schoolBeneficiary].isRegistered) revert SchoolNotRegistered();
        if (!schools[_schoolBeneficiary].isActive) revert SchoolNotActive();
        
        StakingPool storage pool = stakingPools[_poolId];
        if (!pool.isActive) revert PoolNotActive();
        
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
        if (!token.transferFrom(msg.sender, address(this), _amount)) revert TransferFailed();
        
        // Notify governance about stake update if it's registered
        if (address(registry) != address(0) && registry.isContractActive(Constants.GOVERNANCE_NAME)) {
            try this.notifyGovernanceOfStakeChange(msg.sender) {} catch {}
        }
        
        emit Staked(msg.sender, _poolId, _amount, _schoolBeneficiary);

        assert(userStake.amount <= pool.totalStaked);
    }
    
    /**
     * @dev Unstakes tokens from a specific pool
     * @param _poolId ID of the pool to unstake from
     * @param _amount Amount of tokens to unstake
     */
    function unstake(uint256 _poolId, uint256 _amount) external nonReentrant whenContractNotPaused {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        if (_amount == 0) revert ZeroAmount();
        
        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        
        if (userStake.amount < _amount) revert InsufficientStake();
        
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

        // Get token from registry if available
        if (address(registry) != address(0) && registry.isContractActive(Constants.TOKEN_NAME)) {
            token = ERC20Upgradeable(registry.getContractAddress(Constants.TOKEN_NAME));
        }
        
        // Transfer tokens back to user
        if (!token.transfer(msg.sender, amountToReturn)) revert TransferFailed();
        
        emit Unstaked(msg.sender, _poolId, _amount, fee);
    }
    
    /**
     * @dev Claims reward from a specific pool
     * @param _poolId ID of the pool to claim from
     */
    function claimReward(uint256 _poolId) external nonReentrant {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        
        uint256 reward = _claimReward(_poolId, msg.sender);
        if (reward == 0) revert NoRewards();
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
        if (!schools[schoolBeneficiary].isRegistered) revert SchoolNotRegistered();
        
        // Split rewards 50/50
        uint256 userReward = totalReward / 2;
        uint256 schoolReward = totalReward - userReward; // Use subtraction to handle odd numbers
        
        // Update user's last claim time
        userStake.lastClaimTime = block.timestamp;
        
        // Update total rewards paid
        totalRewardsPaid += totalReward;
        
        // Ensure we have enough rewards to pay out
        if (totalReward > rewardsPool) revert InsufficientRewards();

        // Store the old rewards pool for assertion
        uint256 oldRewardsPool = rewardsPool;
        uint256 oldUserBalance = token.balanceOf(_user);
        
        // Update rewards pool
        rewardsPool -= totalReward;
        
        // Update school's total rewards
        schools[schoolBeneficiary].totalRewards += schoolReward;
        
        // Transfer user portion to user
        if (!token.transfer(_user, userReward)) revert UserTransferFailed();
        
        // School portion remains in contract to be managed by platform
        
        emit RewardClaimed(_user, _poolId, userReward, schoolBeneficiary, schoolReward);

        assert(rewardsPool == oldRewardsPool - totalReward);
        assert(token.balanceOf(_user) == oldUserBalance + userReward);
        
        return totalReward;
    }
    
    /**
     * @dev Withdraws school rewards to platform manager for conversion to fiat
     * @param _school Address of the school
     * @param _amount Amount to withdraw
     */
    function withdrawSchoolRewards(address _school, uint256 _amount) external onlyRole(Constants.MANAGER_ROLE) nonReentrant {
        if (!schools[_school].isRegistered) revert SchoolNotRegistered();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > schools[_school].totalRewards) revert InsufficientSchoolRewards();
        
        // Update school's total rewards
        schools[_school].totalRewards -= _amount;
        
        // Transfer tokens to platform manager for conversion
        if (!token.transfer(platformRewardsManager, _amount)) revert TransferFailed();
        
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
        if (_amount == 0) revert ZeroAmount();
        
        // Transfer tokens to the contract
        if (!token.transferFrom(msg.sender, address(this), _amount)) revert TransferFailed();
        
        // Update rewards pool
        rewardsPool += _amount;
        
        emit RewardsAdded(_amount);
    }
    
    /**
     * @dev Adjusts reward rates based on total staked tokens and available rewards
     */
    function adjustRewardRates() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        
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
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        
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
     * @dev Gets stake details for a specific user in a specific pool
     * @param _poolId ID of the pool
     * @param _user Address of the user
     * @return amount Amount staked
     * @return startTime Timestamp when staking started
     */
    function getUserStakeforVoting(uint256 _poolId, address _user) external view returns (
        uint256 amount,
        uint256 startTime
    ) {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();

        UserStake storage userStake = userStakes[_poolId][_user];

        return (
            userStake.amount,
            userStake.startTime
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
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        
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
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        
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
    function recoverTokens(address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(token)) revert CannotRecoverStakingToken();

        token = ERC20Upgradeable(_token);
        if (!token.transfer(owner(), _amount)) revert TransferFailed();
    }

    /**
    * @dev Updates the cooldown period for unstaking
    * @param _cooldownPeriod New cooldown period in seconds
    */
    function setCooldownPeriod(uint96 _cooldownPeriod) external onlyRole(Constants.ADMIN_ROLE) {
        cooldownPeriod = _cooldownPeriod;
    }

    /**
    * @dev Requests to unstake tokens from a specific pool
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function requestUnstake(uint256 _poolId, uint256 _amount) external nonReentrant {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        if (_amount == 0) revert ZeroAmount();

        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];

        if (userStake.amount < _amount) revert InsufficientStake();

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
        if (_poolId >= stakingPools.length) revert InvalidPoolId();

        UnstakingRequest[] storage requests = unstakingRequests[msg.sender][_poolId];
        if (_requestIndex >= requests.length) revert InvalidRequestIndex();

        UnstakingRequest storage request = requests[_requestIndex];
        if (request.claimed) revert AlreadyClaimed();
        if (block.timestamp < request.requestTime + cooldownPeriod) revert CooldownNotOver();

        uint96 amountToClaim = request.amount;

        // Mark as claimed
        request.claimed = true;

        // Transfer tokens back to user
        if (!token.transfer(msg.sender, amountToClaim)) revert TransferFailed();

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
    function setEmergencyUnstakeFee(uint16 _fee) external onlyRole(Constants.ADMIN_ROLE) {
        if (_fee > 5000) revert FeeTooHighEmergency(); // Max 50%
        emergencyUnstakeFee = _fee;
    }

    /**
    * @dev Emergency unstake function for urgent situations
    * @param _poolId ID of the pool to unstake from
    * @param _amount Amount of tokens to unstake
    */
    function emergencyUnstake(uint256 _poolId, uint256 _amount) external onlyRole(Constants.EMERGENCY_ROLE) nonReentrant {
        if (_poolId >= stakingPools.length) revert InvalidPoolId();
        if (_amount == 0) revert ZeroAmount();

        StakingPool storage pool = stakingPools[_poolId];
        UserStake storage userStake = userStakes[_poolId][msg.sender];

        if (userStake.amount < _amount) revert InsufficientStake();

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
        if (!token.transfer(msg.sender, amountToReturn)) revert TransferFailed();

        emit Unstaked(msg.sender, _poolId, _amount, emergencyFee);
    }

    function _verifyTokenBalanceInvariant() internal view {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < stakingPools.length; i++) {
            totalStaked += stakingPools[i].totalStaked;
        }
        assert(token.balanceOf(address(this)) == totalStaked + rewardsPool);
    }

    /**
     * @dev Internal helper to notify governance of stake change
     * This ensures voting power is up to date
     * @param _user User whose stake changed
     */
    function notifyGovernanceOfStakeChange(address _user) external nonReentrant {
        if (msg.sender != address(this)) revert OnlySelf();

        if (address(registry) != address(0) && registry.isContractActive(Constants.GOVERNANCE_NAME)) {
            address governance = registry.getContractAddress(Constants.GOVERNANCE_NAME);

            // Call the updateVotingPower function in Governance
            (bool success, ) = governance.call(
                abi.encodeWithSignature(
                    "updateVotingPower(address)",
                    _user
                )
            );

            if (!success) {
                emit ExternalCallFailed("updateVotingPower", governance);
            }

            // We don't revert on failure since this is a non-critical operation
        }
    }

    /**
     * @dev Retrieves the address of the token contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getTokenAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    // Update cache with successful lookup
                    _cachedTokenAddress = tokenAddress;
                    _lastCacheUpdate = block.timestamp;
                    return tokenAddress;
                }
            } catch {
                // Registry lookup failed, continue to fallbacks
            }
        }

        // Second attempt: Use cached address if available and not too old
        if (_cachedTokenAddress != address(0) && block.timestamp - _lastCacheUpdate < 1 days) {
            return _cachedTokenAddress;
        }

        
        revert ("Token Contract Unknown");
    }

    /**
     * @dev Update voting power for a user in the governance contract
     * This function updates the user's voting power in the governance contract
     * @param _user User whose voting power should be updated
     */
    function updateVotingPower(address _user) external nonReentrant override {
        // Only the contract itself can call this function
        if (msg.sender != address(this)) revert OnlySelf();

        // Notify governance of stake change if governance is registered
        if (address(registry) != address(0) && registry.isContractActive(Constants.GOVERNANCE_NAME)) {
            address governance = registry.getContractAddress(Constants.GOVERNANCE_NAME);

            // Call the updateVotingPower function in Governance
            (bool success, ) = governance.call(
                abi.encodeWithSignature(
                    "updateVotingPower(address)",
                    _user
                )
            );
            if(!success){
                emit PlatformGovernanceUpdateFailed(_user,"TokenStaking: could not update voting power");
            }
            // We don't revert on failure since this is a non-critical operation
        }
    }
}