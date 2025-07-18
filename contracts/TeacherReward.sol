// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

/**
 * @title TeacherReward
 * @dev Contract for incentivizing and rewarding teachers based on performance metrics
 */
contract TeacherReward is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    RegistryAwareUpgradeable,
    UUPSUpgradeable
{
    ERC20Upgradeable internal token;
    
    // Teacher registration status
    struct Teacher {
        bool isRegistered;
        uint256 totalRewards;
        uint256 reputation;
        uint256 lastClaimTime;
        bool isVerified;
    }

    // Enhanced reputation system
    struct ReputationData {
        uint256 totalReviewScore; // Sum of all review scores
        uint256 reviewCount;      // Number of reviews
        uint256 resourcesCreated; // Number of educational resources created
        uint256 saleCount;        // Number of sales from resources
        uint256 verificationLevel; // 0=None, 1=Basic, 2=Professional, 3=Expert
    }

    // Peer review system
    struct Review {
        address reviewer;
        uint256 score;  // 1-5 stars
        string comment;
        uint256 timestamp;
    }

    // Achievement milestone system
    struct Achievement {
        string name;
        string description;
        uint256 rewardAmount;
        bool repeatable;
    }
    
    bool internal paused;
    
    // Mapping from teacher address to Teacher struct
    mapping(address => Teacher) public teachers;
    
    // Mapping from teacher address to ReputationData
    mapping(address => ReputationData) public teacherReputation;

    // Mapping from teacher address to array of reviews
    mapping(address => Review[]) public teacherReviews;
    
    // Array of registered teacher addresses for iteration
    address[] public registeredTeachers;

    // Array of available achievements
    Achievement[] public achievements;

    // Mapping from teacher to achievement ID to earned count
    mapping(address => mapping(uint256 => uint256)) public achievementsEarned;
    
    // Reward parameters
    uint256 public baseRewardRate;         // Base tokens per day for verified teachers
    uint256 public reputationMultiplier;   // Reputation impact on rewards (100 = 1x)
    uint256 public maxDailyReward;         // Maximum rewards claimable per day
    uint256 public minimumClaimPeriod;     // Minimum time between claims in seconds
    
    // Total tokens allocated for rewards
    uint256 public rewardPool;
    
    // Admin roles for verification
    mapping(address => bool) public verifiers;

    // Reputation impact on reward calculation
    uint256 public performanceMultiplierBase; // multiplier base
    uint256 public maxPerformanceMultiplier;  // maximum multiplier

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;
    
    // Events
    event TeacherRegistered(address indexed teacher);
    event TeacherVerified(address indexed teacher, address indexed verifier);
    event RewardClaimed(address indexed teacher, uint256 amount);
    event ReputationUpdated(address indexed teacher, uint256 newReputation);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event RewardPoolIncreased(uint256 amount);
    event RewardParametersUpdated(uint256 baseRate, uint256 multiplier, uint256 maxDaily, uint256 minPeriod);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event AchievementAwarded(address indexed teacher, uint256 indexed achievementId, uint256 count);
    event PeerReviewSubmitted(address indexed teacher, address indexed reviewer, uint256 score);
    
    // Add custom errors at the top:
    error NotRegistered();
    error NotVerifier();
    error ZeroTokenAddress();
    error AlreadyRegistered();
    error AlreadyVerified();
    error InvalidReputationRange();
    error NoRewardsToClaim();
    error TransferFailed();
    error ZeroAmount();
    error AlreadyVerifier();
    error NotVerifierAddress();
    error SystemStillPaused();
    error EmptyName();
    error EmptyDescription();
    error InvalidAchievementId();
    error AlreadyEarned();
    error CannotReviewSelf();
    error InvalidScoreRange();
    error AlreadyReviewedRecently();
    error NotMarketplace();
    
    /**
     * @dev Constructor
     */
    //constructor(){
    //    _disableInitializers();
    //}

    /**
     * @dev Modifier to check if caller is a teacher
     */
    modifier onlyTeacher() {
        if (!teachers[msg.sender].isRegistered) revert NotRegistered();
        _;
    }

    /**
     * @dev Modifier to check if caller is a verifier
     */
    modifier onlyVerifier() {
        if (!verifiers[msg.sender]) revert NotVerifier();
        _;
    }

    /**
     * @dev Initializes the contract with initial parameters
     * @param _token Address of the platform token contract
     * @param _baseRewardRate Base tokens per day for verified teachers
     * @param _reputationMultiplier Reputation impact on rewards (100 = 1x)
     * @param _maxDailyReward Maximum rewards claimable per day
     * @param _minimumClaimPeriod Minimum time between claims in seconds
     */
    function initialize(
        address _token,
        uint256 _baseRewardRate,
        uint256 _reputationMultiplier,
        uint256 _maxDailyReward,
        uint256 _minimumClaimPeriod
    ) initializer public {
        if (_token == address(0)) revert ZeroTokenAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        token = ERC20Upgradeable(_token);
        baseRewardRate = _baseRewardRate;
        reputationMultiplier = _reputationMultiplier;
        maxDailyReward = _maxDailyReward;
        minimumClaimPeriod = _minimumClaimPeriod;

        // Default values for performance multipliers
        performanceMultiplierBase = 100; // 1.0x multiplier base
        maxPerformanceMultiplier = 300;  // 3.0x maximum multiplier

        // Make deployer the first verifier
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.VERIFIER_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        
        // Make deployer the first verifier
        verifiers[msg.sender] = true;
        emit VerifierAdded(msg.sender);
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
        _setRegistry(_registry, Constants.PLATFORM_REWARD_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyRole(Constants.ADMIN_ROLE) {
        if (address(registry) == address(0)) revert RegistryNotSet();

        // Update TeachToken reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newToken = registry.getContractAddress(Constants.TOKEN_NAME);
            address oldToken = address(token);

            if (newToken != oldToken) {
                token = ERC20Upgradeable(newToken);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, newToken);
            }
        }
    }
    
    /**
     * @dev Allows teachers to register in the reward system
     */
    function registerAsTeacher() external whenContractNotPaused {
        if (teachers[msg.sender].isRegistered) revert AlreadyRegistered();
        
        teachers[msg.sender] = Teacher({
            isRegistered: true,
            totalRewards: 0,
            reputation: 100, // Start with neutral reputation
            lastClaimTime: 0,
            isVerified: false
        });
        
        registeredTeachers.push(msg.sender);
        
        emit TeacherRegistered(msg.sender);
    }
    
    /**
     * @dev Verifiers can verify teachers' credentials
     * @param _teacher Address of the teacher to verify
     */
    function verifyTeacher(address _teacher) external onlyVerifier {
        if (!teachers[_teacher].isRegistered) revert NotRegistered();
        if (teachers[_teacher].isVerified) revert AlreadyVerified();
        
        teachers[_teacher].isVerified = true;
        
        emit TeacherVerified(_teacher, msg.sender);
    }
    
    /**
     * @dev Updates a teacher's reputation score
     * @param _teacher Address of the teacher
     * @param _newReputation New reputation score (1-200)
     */
    function updateReputation(address _teacher, uint256 _newReputation) external whenContractNotPaused onlyVerifier {
        if (!teachers[_teacher].isRegistered) revert NotRegistered();
        if (_newReputation < 1 || _newReputation > 200) revert InvalidReputationRange();
        
        teachers[_teacher].reputation = _newReputation;
        
        emit ReputationUpdated(_teacher, _newReputation);
    }
    
    /**
     * @dev Calculates rewards for a teacher based on time since last claim
     * @param _teacher Address of the teacher
     * @return pendingReward Amount of tokens the teacher can claim
     */
    function calculatePendingReward(address _teacher) public view returns (uint256 pendingReward) {
        Teacher storage teacher = teachers[_teacher];
        
        if (!teacher.isRegistered || !teacher.isVerified) {
            return 0;
        }
        
        // Calculate time since last claim
        uint256 lastClaim = teacher.lastClaimTime;
        if (lastClaim == 0) {
            lastClaim = block.timestamp - minimumClaimPeriod;
        }
        
        uint256 timeSinceLastClaim = block.timestamp - lastClaim;
        
        // If not enough time has passed, return 0
        if (timeSinceLastClaim < minimumClaimPeriod) {
            return 0;
        }
        
        // Calculate days since last claim (with precision)
        uint256 daysSinceLastClaim = timeSinceLastClaim / 1 days;

        // Get performance multiplier based on reputation and marketplace metrics
        uint256 performanceMultiplier = calculatePerformanceMultiplier(_teacher);
        
        pendingReward = (baseRewardRate * performanceMultiplier * daysSinceLastClaim) / performanceMultiplierBase;
        
        // Cap reward at maximum daily reward
        if (pendingReward > maxDailyReward * daysSinceLastClaim) {
            pendingReward = maxDailyReward * daysSinceLastClaim;
        }
        
        // Cap reward at available reward pool
        if (pendingReward > rewardPool) {
            pendingReward = rewardPool;
        }
        
        return pendingReward;
    }
    
    /**
     * @dev Teachers claim their pending rewards
     */
    function claimReward() external onlyTeacher nonReentrant whenContractNotPaused{
        uint256 pendingReward = calculatePendingReward(msg.sender);
        if (pendingReward == 0) revert NoRewardsToClaim();
        
        // Update teacher's reward data
        teachers[msg.sender].lastClaimTime = block.timestamp;
        teachers[msg.sender].totalRewards += pendingReward;
        
        // Update reward pool
        rewardPool -= pendingReward;
        
        // Transfer tokens
        if (!token.transfer(msg.sender, pendingReward)) revert TransferFailed();
        
        emit RewardClaimed(msg.sender, pendingReward);
    }
    
    /**
     * @dev Adds funds to the reward pool
     * @param _amount Amount of tokens to add to the reward pool
     */
    function increaseRewardPool(uint256 _amount) external whenContractNotPaused {
        if (_amount == 0) revert ZeroAmount();
        
        // Transfer tokens from caller to contract
        if (!token.transferFrom(msg.sender, address(this), _amount)) revert TransferFailed();
        
        // Increase reward pool
        rewardPool += _amount;
        
        emit RewardPoolIncreased(_amount);
    }
    
    /**
     * @dev Updates reward parameters
     * @param _baseRewardRate New base reward rate
     * @param _reputationMultiplier New reputation multiplier
     * @param _maxDailyReward New maximum daily reward
     * @param _minimumClaimPeriod New minimum claim period
     */
    function updateRewardParameters(
        uint256 _baseRewardRate,
        uint256 _reputationMultiplier,
        uint256 _maxDailyReward,
        uint256 _minimumClaimPeriod
    ) external onlyOwner {
        baseRewardRate = _baseRewardRate;
        reputationMultiplier = _reputationMultiplier;
        maxDailyReward = _maxDailyReward;
        minimumClaimPeriod = _minimumClaimPeriod;
        
        emit RewardParametersUpdated(_baseRewardRate, _reputationMultiplier, _maxDailyReward, _minimumClaimPeriod);
    }
    
    /**
     * @dev Adds a new verifier
     * @param _verifier Address of the new verifier
     */
    function addVerifier(address _verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_verifier == address(0)) revert NotVerifierAddress();
        if (verifiers[_verifier]) revert AlreadyVerifier();
        
        verifiers[_verifier] = true;
        _grantRole(Constants.VERIFIER_ROLE, _verifier);
        
        emit VerifierAdded(_verifier);
    }
    
    /**
     * @dev Removes a verifier
     * @param _verifier Address of the verifier to remove
     */
    function removeVerifier(address _verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!verifiers[_verifier]) revert NotVerifier();
        
        verifiers[_verifier] = false;
        revokeRole(Constants.VERIFIER_ROLE, _verifier);
        
        emit VerifierRemoved(_verifier);
    }
    
    /**
     * @dev Returns the number of registered teachers
     * @return uint256 Number of registered teachers
     */
    function getTeacherCount() external view returns (uint256) {
        return registeredTeachers.length;
    }
    
    /**
     * @dev Gets teacher data for a specific address
     * @param _teacher Address of the teacher
     * @return isRegistered Whether the teacher is registered
     * @return totalRewards Total rewards claimed by the teacher
     * @return reputation Teacher's reputation score
     * @return lastClaimTime Timestamp of the last reward claim
     * @return isVerified Whether the teacher is verified
     * @return pendingReward Amount of rewards available to claim
     */
    function getTeacherData(address _teacher) external view returns (
        bool isRegistered,
        uint256 totalRewards,
        uint256 reputation,
        uint256 lastClaimTime,
        bool isVerified,
        uint256 pendingReward
    ) {
        Teacher storage teacher = teachers[_teacher];
        return (
            teacher.isRegistered,
            teacher.totalRewards,
            teacher.reputation,
            teacher.lastClaimTime,
            teacher.isVerified,
            calculatePendingReward(_teacher)
        );
    }

    // Add pause and unpause functions
    function pauseRewards() external {
        if (address(registry) != address(0)) {
            if (registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
                address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

                if (registry.isContractActive(Constants.GOVERNANCE_NAME)) {
                    address governance = registry.getContractAddress(Constants.GOVERNANCE_NAME);

                    if (
                        msg.sender != stabilityFund &&
                        msg.sender != governance &&
                        !hasRole(Constants.EMERGENCY_ROLE, msg.sender)
                    ) revert NotAuthorized();
                    paused = true;
                } else {
                    if (
                        msg.sender != stabilityFund &&
                        !hasRole(Constants.EMERGENCY_ROLE, msg.sender)
                    ) revert NotAuthorized();
                    paused = true;
                }
            } else {
                if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
            }
        } else {
            if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
        }
    }

    function unpauseRewards() external onlyRole(Constants.EMERGENCY_ROLE) {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if (systemPaused) revert SystemStillPaused();
            } catch {
                // If registry call fails, proceed with unpause
            }
            
        if (registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

            if (registry.isContractActive(Constants.GOVERNANCE_NAME)) {
                address governance = registry.getContractAddress(Constants.GOVERNANCE_NAME);

                if (
                    msg.sender != stabilityFund &&
                    msg.sender != governance &&
                    !hasRole(Constants.EMERGENCY_ROLE, msg.sender)
                ) revert NotAuthorized();
                paused = false;
            } else {
                if (
                    msg.sender != stabilityFund &&
                    !hasRole(Constants.EMERGENCY_ROLE, msg.sender)
                ) revert NotAuthorized();
                paused = false;
            }
            } else {
                if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
            }
        } else {
            if (!hasRole(Constants.EMERGENCY_ROLE, msg.sender)) revert NotAuthorized();
        }
    }

    function _isContractPaused() internal override view returns (bool) {
        return paused;
    }

    /**
     * @dev Register a new achievement milestone
     * @param _name Name of the achievement
     * @param _description Description of the achievement
     * @param _rewardAmount Reward amount for completing the achievement
     * @param _repeatable Whether the achievement can be earned multiple times
     * @return uint256 ID of the newly created achievement
     */
    function registerAchievement(
        string memory _name,
        string memory _description,
        uint256 _rewardAmount,
        bool _repeatable
    ) external onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        if (bytes(_name).length == 0) revert EmptyName();
        if (bytes(_description).length == 0) revert EmptyDescription();

        uint256 achievementId = achievements.length;

        achievements.push(Achievement({
            name: _name,
            description: _description,
            rewardAmount: _rewardAmount,
            repeatable: _repeatable
        }));

        return achievementId;
    }

    /**
     * @dev Award an achievement to a teacher
     * @param _teacher Address of the teacher
     * @param _achievementId ID of the achievement
     */
    function awardAchievement(address _teacher, uint256 _achievementId) external onlyVerifier {
        if (_teacher == address(0)) revert NotRegistered();
        if (_achievementId >= achievements.length) revert InvalidAchievementId();
        if (!teachers[_teacher].isRegistered) revert NotRegistered();

        Achievement storage achievement = achievements[_achievementId];

        // Check if repeatable or not yet earned
        if (achievement.repeatable) {
            if (achievementsEarned[_teacher][_achievementId] > 0) revert AlreadyEarned();
        }

        // Increment earned count
        achievementsEarned[_teacher][_achievementId]++;

        // Award tokens if reward amount > 0
        if (achievement.rewardAmount > 0 && rewardPool >= achievement.rewardAmount) {
            // Reduce reward pool
            rewardPool -= achievement.rewardAmount;

            // Get token from registry if available
            if (address(registry) != address(0) && registry.isContractActive(Constants.TOKEN_NAME)) {
                token = ERC20Upgradeable(registry.getContractAddress(Constants.TOKEN_NAME));
            }

            // Transfer tokens
            if (!token.transfer(_teacher, achievement.rewardAmount)) revert TransferFailed();

            // Update teacher's total rewards
            teachers[_teacher].totalRewards += achievement.rewardAmount;
        }

        emit AchievementAwarded(_teacher, _achievementId, achievementsEarned[_teacher][_achievementId]);
    }

    /**
     * @dev Submit a peer review for a teacher
     * @param _teacher Address of the teacher being reviewed
     * @param _score Review score (1-5)
     * @param _comment Review comment
     */
    function submitPeerReview(address _teacher, uint256 _score, string memory _comment) external whenContractNotPaused{
        if (_teacher == address(0)) revert NotRegistered();
        if (_teacher == msg.sender) revert CannotReviewSelf();
        if (!teachers[_teacher].isRegistered) revert NotRegistered();
        if (!teachers[msg.sender].isRegistered) revert NotRegistered();
        if (_score < 1 || _score > 5) revert InvalidScoreRange();

        // Check if the reviewer has already reviewed this teacher recently
        bool hasRecentReview = false;
        for (uint256 i = 0; i < teacherReviews[_teacher].length; i++) {
            if (teacherReviews[_teacher][i].reviewer == msg.sender &&
                block.timestamp - teacherReviews[_teacher][i].timestamp < 30 days) {
                hasRecentReview = true;
                break;
            }
        }

        if (hasRecentReview) revert AlreadyReviewedRecently();

        // Add the review
        teacherReviews[_teacher].push(Review({
            reviewer: msg.sender,
            score: _score,
            comment: _comment,
            timestamp: block.timestamp
        }));

        // Update teacher's reputation data
        teacherReputation[_teacher].totalReviewScore += _score;
        teacherReputation[_teacher].reviewCount++;

        // Calculate new average reputation
        uint256 newReputation = (teacherReputation[_teacher].totalReviewScore * 100) /
                            teacherReputation[_teacher].reviewCount;

        // Scale to 1-200 range (20-100 from 1-5 stars)
        newReputation = 20 * newReputation;

        // Ensure it's within bounds
        if (newReputation < 20) newReputation = 20;
        if (newReputation > 200) newReputation = 200;

        // Update teacher's reputation
        teachers[_teacher].reputation = newReputation;

        emit PeerReviewSubmitted(_teacher, msg.sender, _score);
        emit ReputationUpdated(_teacher, newReputation);
    }

    /**
     * @dev Calculate performance multiplier based on reputation and metrics
     * @param _teacher Address of the teacher
     * @return multiplier Performance multiplier (scaled by performanceMultiplierBase)
     */
    function calculatePerformanceMultiplier(address _teacher) public view returns (uint256 multiplier) {
        Teacher storage teacher = teachers[_teacher];
        ReputationData storage repData = teacherReputation[_teacher];

        // Start with base multiplier
        multiplier = performanceMultiplierBase;

        // Factor 1: Reputation score (0-100% boost)
        uint256 reputationBoost = ((teacher.reputation - 100) * performanceMultiplierBase) / 100;
        if (reputationBoost > performanceMultiplierBase) {
            reputationBoost = performanceMultiplierBase;
        }

        // Factor 2: Resource creation and sales (up to 50% boost)
        uint256 resourceBoost = 0;
        if (repData.resourcesCreated > 0) {
            // Calculate boost based on resources and sales
            uint256 baseResourceBoost = (repData.resourcesCreated * 5 * performanceMultiplierBase) / 100;
            uint256 salesBoost = (repData.saleCount * 2 * performanceMultiplierBase) / 100;

            resourceBoost = baseResourceBoost + salesBoost;

            // Cap at 50%
            if (resourceBoost > performanceMultiplierBase / 2) {
                resourceBoost = performanceMultiplierBase / 2;
            }
        }

        // Factor 3: Verification level (0-50% boost)
        uint256 verificationBoost = (repData.verificationLevel * 15 * performanceMultiplierBase) / 100;
        if (verificationBoost > performanceMultiplierBase / 2) {
            verificationBoost = performanceMultiplierBase / 2;
        }

        // Apply all boosts
        multiplier += reputationBoost + resourceBoost + verificationBoost;

        // Cap at maximum multiplier
        if (multiplier > maxPerformanceMultiplier) {
            multiplier = maxPerformanceMultiplier;
        }

        return multiplier;
    }

    /**
     * @dev Update marketplace metrics from marketplace contract
     * This function should be called by the marketplace contract when teachers
     * create resources or make sales
     * @param _teacher Address of the teacher
     * @param _resourceCreated Whether a resource was created
     * @param _saleCount Number of new sales
     */
    function updateMarketplaceMetrics(
        address _teacher,
        bool _resourceCreated,
        uint256 _saleCount
    ) external whenContractNotPaused{
        // Check if caller is the marketplace contract
        if (address(registry) != address(0) && registry.isContractActive(Constants.MARKETPLACE_NAME)) {
            address marketplace = registry.getContractAddress(Constants.MARKETPLACE_NAME);
            if (msg.sender != marketplace) revert NotMarketplace();
        } else {
            if (!hasRole(Constants.ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        }

        if (!teachers[_teacher].isRegistered) revert NotRegistered();

        // Update metrics
        if (_resourceCreated) {
            teacherReputation[_teacher].resourcesCreated++;
        }

        if (_saleCount > 0) {
            teacherReputation[_teacher].saleCount += _saleCount;
        }

        // Check for achievement triggers
        // checkResourceAchievements(_teacher);
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
}