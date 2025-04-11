// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./RegistryAware.sol";

/**
 * @title TeacherReward
 * @dev Contract for incentivizing and rewarding teachers based on performance metrics
 */
contract TeacherReward is Ownable, ReentrancyGuard, Pausable, AccessControl, RegistryAware {
    bytes32 public constant TEACH_TOKEN_NAME = keccak256("TEACH_TOKEN");
    bytes32 public constant STABILITY_FUND_NAME = keccak256("PLATFORM_STABILITY_FUND");
    bytes32 public constant GOVERNANCE_NAME = keccak256("TEACHER_GOVERNANCE");
    bytes32 public constant MARKETPLACE_NAME = keccak256("TEACHER_MARKETPLACE");

    // Role constants
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // The TeachToken contract
    IERC20 public teachToken;
    
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
    uint256 public performanceMultiplierBase = 100; // 1.0x multiplier base
    uint256 public maxPerformanceMultiplier = 300;  // 3.0x maximum multiplier
    
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
    
    /**
     * @dev Modifier to check if caller is a teacher
     */
    modifier onlyTeacher() {
        require(teachers[msg.sender].isRegistered, "TeacherReward: not registered");
        _;
    }
    
    /**
     * @dev Modifier to check if caller is a verifier
     */
    modifier onlyVerifier() {
        require(verifiers[msg.sender], "TeacherReward: not a verifier");
        _;
    }
    
    /**
     * @dev Constructor sets the token address and initial reward parameters
     * @param _teachToken Address of the TEACH token contract
     * @param _baseRewardRate Base tokens per day for verified teachers
     * @param _reputationMultiplier Reputation impact on rewards (100 = 1x)
     * @param _maxDailyReward Maximum rewards claimable per day
     * @param _minimumClaimPeriod Minimum time between claims in seconds
     */
    constructor(
        address _teachToken,
        uint256 _baseRewardRate,
        uint256 _reputationMultiplier,
        uint256 _maxDailyReward,
        uint256 _minimumClaimPeriod
    ) Ownable(msg.sender) {
        require(_teachToken != address(0), "TeacherReward: zero token address");
        
        teachToken = IERC20(_teachToken);
        baseRewardRate = _baseRewardRate;
        reputationMultiplier = _reputationMultiplier;
        maxDailyReward = _maxDailyReward;
        minimumClaimPeriod = _minimumClaimPeriod;
        
        // Make deployer the first verifier
        verifiers[msg.sender] = true;
        emit VerifierAdded(msg.sender);
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyOwner {
        _setRegistry(_registry, keccak256("TEACHER_REWARD"));
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyRole(ADMIN_ROLE) {
        require(address(registry) != address(0), "TeacherReward: registry not set");

        // Update TeachToken reference
        if (registry.isContractActive(TEACH_TOKEN_NAME)) {
            address newTeachToken = registry.getContractAddress(TEACH_TOKEN_NAME);
            address oldTeachToken = address(teachToken);

            if (newTeachToken != oldTeachToken) {
                teachToken = IERC20(newTeachToken);
                emit ContractReferenceUpdated(TEACH_TOKEN_NAME, oldTeachToken, newTeachToken);
            }
        }
    }
    
    /**
     * @dev Allows teachers to register in the reward system
     */
    function registerAsTeacher() external whenNotPaused {
        require(!teachers[msg.sender].isRegistered, "TeacherReward: already registered");
        
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
        require(teachers[_teacher].isRegistered, "TeacherReward: teacher not registered");
        require(!teachers[_teacher].isVerified, "TeacherReward: already verified");
        
        teachers[_teacher].isVerified = true;
        
        emit TeacherVerified(_teacher, msg.sender);
    }
    
    /**
     * @dev Updates a teacher's reputation score
     * @param _teacher Address of the teacher
     * @param _newReputation New reputation score (1-200)
     */
    function updateReputation(address _teacher, uint256 _newReputation) external whenNotPaused onlyVerifier {
        require(teachers[_teacher].isRegistered, "TeacherReward: teacher not registered");
        require(_newReputation >= 1 && _newReputation <= 200, "TeacherReward: invalid reputation range");
        
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
        
        // Calculate reward based on reputation and time
        uint256 reputationFactor = (teacher.reputation * reputationMultiplier) / 100;
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
    function claimReward() external onlyTeacher nonReentrant whenNotPaused {
        uint256 pendingReward = calculatePendingReward(msg.sender);
        require(pendingReward > 0, "TeacherReward: no rewards to claim");
        
        // Update teacher's reward data
        teachers[msg.sender].lastClaimTime = block.timestamp;
        teachers[msg.sender].totalRewards += pendingReward;
        
        // Update reward pool
        rewardPool -= pendingReward;
        
        // Transfer tokens
        require(teachToken.transfer(msg.sender, pendingReward), "TeacherReward: transfer failed");
        
        emit RewardClaimed(msg.sender, pendingReward);
    }
    
    /**
     * @dev Adds funds to the reward pool
     * @param _amount Amount of tokens to add to the reward pool
     */
    function increaseRewardPool(uint256 _amount) external whenNotPaused {
        require(_amount > 0, "TeacherReward: zero amount");
        
        // Transfer tokens from caller to contract
        require(teachToken.transferFrom(msg.sender, address(this), _amount), "TeacherReward: transfer failed");
        
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
    function addVerifier(address _verifier) external onlyOwner {
        require(_verifier != address(0), "TeacherReward: zero address");
        require(!verifiers[_verifier], "TeacherReward: already a verifier");
        
        verifiers[_verifier] = true;
        
        emit VerifierAdded(_verifier);
    }
    
    /**
     * @dev Removes a verifier
     * @param _verifier Address of the verifier to remove
     */
    function removeVerifier(address _verifier) external onlyOwner {
        require(verifiers[_verifier], "TeacherReward: not a verifier");
        
        verifiers[_verifier] = false;
        
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
    function pauseRewards() external onlyOwner {
        _pause();
    }

    function unpauseRewards() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency pause for rewards system, can be triggered by StabilityFund
     */
    function pauseRewards() external {
        // Check if caller is StabilityFund, has EMERGENCY_ROLE, or is the governance contract
        if (address(registry) != address(0)) {
            if (registry.isContractActive(STABILITY_FUND_NAME)) {
                address stabilityFund = registry.getContractAddress(STABILITY_FUND_NAME);

                if (registry.isContractActive(GOVERNANCE_NAME)) {
                    address governance = registry.getContractAddress(GOVERNANCE_NAME);

                    require(
                        msg.sender == stabilityFund ||
                        msg.sender == governance ||
                        hasRole(EMERGENCY_ROLE, msg.sender),
                        "TeacherReward: not authorized"
                    );
                } else {
                    require(
                        msg.sender == stabilityFund ||
                        hasRole(EMERGENCY_ROLE, msg.sender),
                        "TeacherReward: not authorized"
                    );
                }
            } else {
                require(hasRole(EMERGENCY_ROLE, msg.sender), "TeacherReward: not authorized");
            }
        } else {
            require(hasRole(EMERGENCY_ROLE, msg.sender), "TeacherReward: not authorized");
        }

        _pause();
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
    ) external onlyRole(ADMIN_ROLE) returns (uint256) {
        require(bytes(_name).length > 0, "TeacherReward: empty name");
        require(bytes(_description).length > 0, "TeacherReward: empty description");

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
    function awardAchievement(address _teacher, uint256 _achievementId) external onlyRole(VERIFIER_ROLE) {
        require(_teacher != address(0), "TeacherReward: zero address");
        require(_achievementId < achievements.length, "TeacherReward: invalid achievement ID");
        require(teachers[_teacher].isRegistered, "TeacherReward: teacher not registered");

        Achievement storage achievement = achievements[_achievementId];

        // Check if repeatable or not yet earned
        if (!achievement.repeatable) {
            require(achievementsEarned[_teacher][_achievementId] == 0, "TeacherReward: already earned");
        }

        // Increment earned count
        achievementsEarned[_teacher][_achievementId]++;

        // Award tokens if reward amount > 0
        if (achievement.rewardAmount > 0 && rewardPool >= achievement.rewardAmount) {
            // Reduce reward pool
            rewardPool -= achievement.rewardAmount;

            // Get token from registry if available
            IERC20 token = teachToken;
            if (address(registry) != address(0) && registry.isContractActive(TEACH_TOKEN_NAME)) {
                token = IERC20(registry.getContractAddress(TEACH_TOKEN_NAME));
            }

            // Transfer tokens
            require(token.transfer(_teacher, achievement.rewardAmount), "TeacherReward: transfer failed");

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
    function submitPeerReview(address _teacher, uint256 _score, string memory _comment) external whenNotPaused {
        require(_teacher != address(0), "TeacherReward: zero address");
        require(_teacher != msg.sender, "TeacherReward: cannot review self");
        require(teachers[_teacher].isRegistered, "TeacherReward: teacher not registered");
        require(teachers[msg.sender].isRegistered, "TeacherReward: reviewer not registered");
        require(_score >= 1 && _score <= 5, "TeacherReward: invalid score range");

        // Check if the reviewer has already reviewed this teacher recently
        bool hasRecentReview = false;
        for (uint256 i = 0; i < teacherReviews[_teacher].length; i++) {
            if (teacherReviews[_teacher][i].reviewer == msg.sender &&
                block.timestamp - teacherReviews[_teacher][i].timestamp < 30 days) {
                hasRecentReview = true;
                break;
            }
        }

        require(!hasRecentReview, "TeacherReward: already reviewed recently");

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
    ) external whenNotPaused {
        // Check if caller is the marketplace contract
        if (address(registry) != address(0) && registry.isContractActive(MARKETPLACE_NAME)) {
            address marketplace = registry.getContractAddress(MARKETPLACE_NAME);
            require(msg.sender == marketplace, "TeacherReward: not marketplace");
        } else {
            require(hasRole(ADMIN_ROLE, msg.sender), "TeacherReward: not authorized");
        }

        require(teachers[_teacher].isRegistered, "TeacherReward: teacher not registered");

        // Update metrics
        if (_resourceCreated) {
            teacherReputation[_teacher].resourcesCreated++;
        }

        if (_saleCount > 0) {
            teacherReputation[_teacher].saleCount += _saleCount;
        }

        // Check for achievement triggers
        checkResourceAchievements(_teacher);
    }
}