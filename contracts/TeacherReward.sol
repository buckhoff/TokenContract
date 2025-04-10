// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TeacherReward
 * @dev Contract for incentivizing and rewarding teachers based on performance metrics
 */
contract TeacherReward is Ownable, ReentrancyGuard, Pausable {
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
    
    // Mapping from teacher address to Teacher struct
    mapping(address => Teacher) public teachers;
    
    // Array of registered teacher addresses for iteration
    address[] public registeredTeachers;
    
    // Reward parameters
    uint256 public baseRewardRate;         // Base tokens per day for verified teachers
    uint256 public reputationMultiplier;   // Reputation impact on rewards (100 = 1x)
    uint256 public maxDailyReward;         // Maximum rewards claimable per day
    uint256 public minimumClaimPeriod;     // Minimum time between claims in seconds
    
    // Total tokens allocated for rewards
    uint256 public rewardPool;
    
    // Admin roles for verification
    mapping(address => bool) public verifiers;
    
    // Events
    event TeacherRegistered(address indexed teacher);
    event TeacherVerified(address indexed teacher, address indexed verifier);
    event RewardClaimed(address indexed teacher, uint256 amount);
    event ReputationUpdated(address indexed teacher, uint256 newReputation);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event RewardPoolIncreased(uint256 amount);
    event RewardParametersUpdated(uint256 baseRate, uint256 multiplier, uint256 maxDaily, uint256 minPeriod);
    
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
        
        // Calculate reward based on reputation and time
        uint256 reputationFactor = (teacher.reputation * reputationMultiplier) / 100;
        pendingReward = (baseRewardRate * reputationFactor * daysSinceLastClaim) / 100;
        
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
}