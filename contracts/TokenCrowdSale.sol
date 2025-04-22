// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Constants.sol";

/**
 * @title GenericTokenPresale
 * @dev Multi-tier presale contract for any ERC20 token
 */
contract TokenCrowdSale is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    RegistryAwareUpgradeable
{
    
    // Presale tiers structure
    struct PresaleTier {
        uint96 price;         // Price in USD (scaled by 1e6)
        uint96 allocation;    // Total allocation for this tier
        uint96 sold;          // Amount sold in this tier
        uint96 minPurchase;   // Minimum purchase amount in USD
        uint96 maxPurchase;   // Maximum purchase amount in USD
        uint16 vestingTGE;    // Percentage released at TGE (scaled by 100)
        uint16 vestingMonths; // Remaining vesting period in months
        bool isActive;        // Whether this tier is currently active
    }    

    // User purchase tracking
    struct Purchase {
        uint96 tokens;      // Total tokens purchased
        uint96 usdAmount;   // USD amount paid
        uint256[] tierAmounts; // Amount purchased in each tier
    }

    struct ClaimEvent {
        uint256 amount;
        uint256 timestamp;
    }
    
    ERC20Upgradeable internal token;
    
    // Emergency state tracking
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }
    EmergencyState public emergencyState;

    // Emergency thresholds
    uint256 public constant MINOR_EMERGENCY_THRESHOLD = 1; 
    uint256 public constant CRITICAL_EMERGENCY_THRESHOLD = 2;

    // Emergency recovery tracking
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;
    bool public inRecoveryMode;
    
    uint256 public currentTier = 0;
    uint256 public tierCount;
    mapping(uint256 => uint256) public maxTokensForTier;

    // Payment token (USDC)
    ERC20Upgradeable public paymentToken;

    // Presale tiers
    PresaleTier[] public tiers;

    // Mapping from user address to purchase info
    mapping(address => Purchase) public purchases;
    
    //Check for Roles
    mapping(bytes32 => mapping(address => bool)) private roleMembership;
    mapping(address => uint256) private userTotalTokens;  // Total tokens purchased by user
    mapping(address => uint256) private userTotalValue;   // Total value (in stablecoin units) spent by user
    
    // Treasury wallet to receive funds
    address public treasury;

    // Presale start and end times
    uint96 public presaleStart;
    uint96 public presaleEnd;

    // Whether tokens have been generated and initial distribution occurred
    bool public tgeCompleted = false;

    // USD price scaling factor (6 decimal places)
    uint256 public constant PRICE_DECIMALS = 1e6;
    
    // Maximum tokens purchasable by a single address across all tiers
    uint96 public maxTokensPerAddress;

    // Presale pause status
    bool public paused;
    
    // Mapping to track total tokens purchased by each address
    mapping(address => uint96) public addressTokensPurchased;

    // Add to existing contract
    mapping(uint256 => uint96) public tierDeadlines; // Timestamps for tier deadlines

    mapping(address => uint256) public lastPurchaseTime;
    uint256 public minTimeBetweenPurchases = 1 hours;
    uint256 public maxPurchaseAmount = 50_000 * PRICE_DECIMALS; // $50,000 default max

    // Add mapping to track claims history
    mapping(address => ClaimEvent[]) public claimHistory;

    mapping(address => bool) public autoCompoundEnabled;

    // Emergency state variables
    bool public inEmergencyRecovery = false;
    uint256 public emergencyPauseTime;
    mapping(address => bool) public emergencyWithdrawalsProcessed;

    uint256 private _resourceIdCounter;
    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;

    uint256 public platformFeePercent;
    uint256 public lowValueFeePercent;
    uint256 public valueThreshold;
    
    // Events
    event TierPurchase(address indexed buyer, uint256 tierId, uint256 tokenAmount, uint256 usdAmount);
    event TierStatusChanged(uint256 tierId, bool isActive);
    event TokensWithdrawn(address indexed user, uint256 amount);
    event PresaleTimesUpdated(uint256 newStart, uint256 newEnd);
    event TierDeadlineUpdated(uint256 indexed tier, uint256 deadline);
    event TierAdvanced(uint256 indexed newTier);
    event TierExtended(uint256 indexed tier, uint256 newDeadline);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event EmergencyPaused(address indexed triggeredBy, uint256 timestamp);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint256 timestamp);
    event AutoCompoundUpdated(address indexed user, bool enabled);
    event EmergencyWithdrawalProcessed(address indexed user, uint256 amount);
    event EmergencyStateChanged(EmergencyState state);
    event StabilityFundRecordingFailed(address indexed user, string reason);
    
    modifier purchaseRateLimit(uint256 _usdAmount) {
        require(
            block.timestamp >= lastPurchaseTime[msg.sender] + minTimeBetweenPurchases,
            "CrowdSale: purchase too soon after previous"
        );

        require(
            _usdAmount <= maxPurchaseAmount,
            "CrowdSale: amount exceeds maximum purchase limit"
        );

        lastPurchaseTime[msg.sender] = block.timestamp;
        _;
    }

    modifier whenSystemNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool paused) {
                require(!paused, "CrowdSale: system is paused");
            } catch {
                // If registry call fails, continue execution
            }
        }
        _;
    }

    modifier onlyAdmin() {
        require(hasRole(Constants.ADMIN_ROLE, msg.sender), "CrowdSale: caller is not admin role");
        _;
    }

    modifier onlyRecorder() {
        require(hasRole(Constants.RECORDER_ROLE, msg.sender), "CrowdSale: caller is not recorder role");
        _;
    }

    modifier onlyEmergency() {
        require(hasRole(Constants.EMERGENCY_ROLE, msg.sender), "CrowdSale: caller is not emergency role");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "CrowdSale: caller doesn't have role");
        _;
    }
    
    /**
     * @dev Constructor to initialize the presale contract
     * @param _paymentToken Address of the payment token (USDC)
     * @param _treasury Address to receive presale funds
     */
    constructor(){
        _disableInitializers();
    }

    /**
     * @dev Initializer function to replace constructor
     * @param _paymentToken Address of the payment token (USDC)
     * @param _treasury Address to receive presale funds
     */
    function initialize(
        IERC20 _paymentToken, address _treasury) initializer public {

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        paymentToken = _paymentToken;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(Constants.RECORDER_ROLE, msg.sender);

        _resourceIdCounter = 1;
        
        // Initialize the 7 tiers with our pricing structure
        // Prices are in USD scaled by 1e6 (e.g., $0.018 = 18000)

        // Tier 1:
        tiers.push(PresaleTier({
            price: 35000, // $0.035
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 10, // 10% at TGE
            vestingMonths: 18, // 18 months vesting
            isActive: false
        }));

        // Tier 2: 
        tiers.push(PresaleTier({
            price: 45000, // $0.045
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 25_000 * PRICE_DECIMALS, // $25,000 max
            vestingTGE: 15, // 15% at TGE
            vestingMonths: 15, // 15 months vesting
            isActive: false
        }));

        // Tier 3: 
        tiers.push(PresaleTier({
            price: 55000, // $0.055
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 10_000 * PRICE_DECIMALS, // $10,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 12, // 12 months vesting
            isActive: false
        }));

        // Tier 4:
        tiers.push(PresaleTier({
            price: 70000, // $0.07
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 9, // 9 months vesting
            isActive: false
        }));

        // Tier 5:
        tiers.push(PresaleTier({
            price: 85000, // $0.085
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 50 * PRICE_DECIMALS, // $50 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 25, // 25% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        }));

        // Tier 6:
        tiers.push(PresaleTier({
            price: 100000, // $0.10
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $20 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 30, // 30% at TGE
            vestingMonths: 4, // 4 months vesting
            isActive: false
        }));

        // Tier 7:
        tiers.push(PresaleTier({
            price: 120000, // $0.12
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $200 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 40, // 40% at TGE
            vestingMonths: 3, // 3 months vesting
            isActive: false
        }));

        tierCount = tiers.length;

        for (uint256 i = 0; i < tiers.length; i++) {
            uint256 tierTotal = 0;
            for (uint256 j = 0; j <= i; j++) {
                tierTotal += tiers[j].allocation;
            }
            maxTokensForTier[i] = tierTotal;
        }

        // Inside the constructor, add:
        maxTokensPerAddress = 1_500_000 * 10**18; // 1.5M tokens by default
    }

    function addRecorder(address _recorder) external onlyOwner {
        _grantRole(Constants.RECORDER_ROLE, _recorder);
    }

    /**
    * @dev Records a token purchase for tracking average buy price
    * @param _user Address of the user
    * @param _tokenAmount Amount of tokens purchased
    * @param _purchaseValue Value paid in stable coin units (scaled by 1e18)
    * @notice This should be called by authorized contracts when users purchase tokens
    */
    function recordTokenPurchase(
        address _user,
        uint256 _tokenAmount,
        uint256 _purchaseValue
    ) external onlyRecorder whenSystemNotPaused {
        userTotalTokens[_user] += _tokenAmount;
        userTotalValue[_user] += _purchaseValue;
    }
    
    /**
     * @dev Set the token address after deployment
     * @param _Token Address of the ERC20 token contract
     */
    function setSaleToken(ERC20Upgradeable _token) external onlyOwner {
        require(address(token) == address(0), "Token already set");
        token = _token;
    }

    /**
     * @dev Set the presale start and end times
     * @param _start Start timestamp
     * @param _end End timestamp
     */
    function setPresaleTimes(uint256 _start, uint256 _end) external onlyOwner {
        require(_end > _start, "End must be after start");
        presaleStart = _start;
        presaleEnd = _end;
        emit PresaleTimesUpdated(_start, _end);
    }

    /**
     * @dev Activate or deactivate a specific tier
     * @param _tierId Tier ID to modify
     * @param _isActive New active status
     */
    function setTierStatus(uint256 _tierId, bool _isActive) external onlyOwner {
        require(_tierId < tiers.length, "Invalid tier ID");
        tiers[_tierId].isActive = _isActive;
        emit TierStatusChanged(_tierId, _isActive);
    }

    /**
     * @dev Purchase tokens in a specific tier
     * @param _tierId Tier to purchase from
     * @param _usdAmount USD amount to spend (scaled by 1e6)
     */
    function purchase(uint256 _tierId, uint256 _usdAmount) external nonReentrant whenSystemNotPaused whenNotPaused purchaseRateLimit(_usdAmount) {
        require(block.timestamp >= presaleStart && block.timestamp <= presaleEnd, "Presale not active");
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTier storage tier = tiers[_tierId];
        require(tier.isActive, "Tier not active");

        // For earlier tiers (0-3), require whitelist
        //if (_tierId <= 3) {
        //    require(whitelist[msg.sender], "Not whitelisted for this tier");
        //}

        // Validate purchase amount
        require(_usdAmount >= tier.minPurchase, "Below minimum purchase");
        require(_usdAmount <= tier.maxPurchase, "Above maximum purchase");

        // Check if user's total purchase would exceed max
        uint256 userTierTotal = purchases[msg.sender].tierAmounts.length > _tierId
            ? purchases[msg.sender].tierAmounts[_tierId] + _usdAmount
            : _usdAmount;
        require(userTierTotal <= tier.maxPurchase, "Would exceed max tier purchase");

        // Calculate token amount
        uint256 tokenAmount = (_usdAmount * 10**18) / tier.price;

        // Check total cap per address
        require(addressTokensPurchased[msg.sender] + uint96(tokenAmount) <= maxTokensPerAddress, "Exceeds max tokens per address");

        // Check if there's enough allocation left
        require(tier.sold + tokenAmount <= tier.allocation, "Insufficient tier allocation");

        // Update tier data
        tier.sold = uint96(tier.sold + tokenAmount);

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens = uint96(userPurchase.tokens + tokenAmount);
        userPurchase.usdAmount = uint96(userPurchase.usdAmount + _usdAmount);

        // Transfer payment tokens from user to treasury
        require(paymentToken.transferFrom(msg.sender, treasury, _usdAmount), "Payment failed");

        // Update total tokens purchased by address
        addressTokensPurchased[msg.sender] += uint96(tokenAmount);
        
        // Ensure tierAmounts array is long enough
        while (userPurchase.tierAmounts.length <= _tierId) {
            userPurchase.tierAmounts.push(0);
        }
        userPurchase.tierAmounts[_tierId] = userPurchase.tierAmounts[_tierId] + _usdAmount;

        // Record purchase for tracking using the StabilityFund
        if (address(registry) != address(0) && registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            try this.recordPurchaseInStabilityFund(msg.sender, tokenAmount, _usdAmount) {} catch {}
        }
        
        emit TierPurchase(msg.sender, _tierId, tokenAmount, _usdAmount);
    }

    /**
     * @dev Complete Token Generation Event, allowing initial token claims
     */
    function completeTGE() external onlyOwner whenSystemNotPaused {
        require(!tgeCompleted, "TGE already completed");
        require(block.timestamp > presaleEnd, "Presale still active");
        tgeCompleted = true;
    }

    /**
     * @dev Calculate currently claimable tokens for a user
     * @param _user Address to check
     * @return claimable Amount of tokens claimable
     */
    function claimableTokens(address _user) public view returns (uint256 claimable) {
        if (!tgeCompleted) return 0;

        Purchase storage userPurchase = purchases[_user];
        uint256 totalPurchased = userPurchase.tokens;
        if (totalPurchased == 0) return 0;

        // Calculate time-based vesting
        uint256 elapsedMonths = (block.timestamp - presaleEnd) / 30 days;

        // Calculate tokens from each tier
        uint256 totalClaimable = 0;

        // Only loop through tiers where the user has invested
        uint256[] storage tierAmounts = userPurchase.tierAmounts;
        uint256 userTierCount = tierAmounts.length;
        
        for (uint256 tierId = 0; tierId < userTierCount; tierId++) {
            // Skip tiers where user hasn't purchased
            if (tierAmounts[tierId] == 0) continue;

            PresaleTier storage tier = tiers[tierId];
            uint256 tierTokens = (tierAmounts[tierId] * 10**18) / tier.price;

            uint256 tierClaimable = calculateVestedAmount(
                tierTokens,
                tier.vestingTGE,
                tier.vestingMonths,
                presaleEnd,
                block.timestamp
            );
            
            totalClaimable = totalClaimable + tierClaimable;

            // Add auto-compound bonus if enabled
            if (autoCompoundEnabled[_user] && totalClaimable > 0) {
                // Calculate bonus based on how long tokens were unclaimed (up to 5% annual bonus)
                uint256 maxAnnualBonus = (totalClaimable * 5) / 100;
                uint256 timeUnclaimed = block.timestamp - userPurchase.lastClaimTime;
                uint256 bonus = (maxAnnualBonus * timeUnclaimed) / 365 days;

                totalClaimable = totalClaimable + bonus;
            }
        }

        // Subtract already claimed tokens
        uint256 alreadyClaimed = totalPurchased - userPurchase.tokens;
        return totalClaimable > alreadyClaimed ? totalClaimable - alreadyClaimed : 0;
    }

    /**
     * @dev Withdraw available tokens based on vesting schedule
     */
    function withdrawTokens() external nonReentrant whenSystemNotPaused{
        require(tgeCompleted, "TGE not completed yet");

        uint256 claimable = claimableTokens(msg.sender);
        require(claimable > 0, "No tokens available to claim");

        // Update user's token balance
        purchases[msg.sender].tokens = purchases[msg.sender].tokens - claimable;

        // Record this claim event
        claimHistory[msg.sender].push(ClaimEvent({
            amount: claimable,
            timestamp: block.timestamp
        }));
        
        // Transfer tokens to user
        require(token.transfer(msg.sender, claimable), "Token transfer failed");

        emit TokensWithdrawn(msg.sender, claimable);
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(ERC20Upgradeable _token) external onlyOwner {
        require(address(_token) != address(token), "Cannot recover tokens");
        uint256 balance = _token.balanceOf(address(this));
        require(balance > 0, "No tokens to recover");
        require(_token.transfer(owner(), balance), "Token recovery failed");
    }
    
    // New function to set tier deadlines
    function setTierDeadline(uint256 _tier, uint256 _deadline) external onlyOwner {
        require(_tier < tierCount, "Crowdsale: invalid tier");
        require(_deadline > block.timestamp, "Crowdsale: deadline in past");
        tierDeadlines[_tier] = _deadline;
        emit TierDeadlineUpdated(_tier, _deadline);
    }

    // New function to manually advance tier
    function advanceTier() external onlyOwner {
        require(currentTier < tierCount - 1, "Crowdsale: already at final tier");
        currentTier++;
        emit TierAdvanced(currentTier);
    }

    // New function to extend current tier
    function extendTier(uint256 _newDeadline) external onlyOwner {
        require(_newDeadline > tierDeadlines[currentTier], "Crowdsale: new deadline must be later");
        tierDeadlines[currentTier] = _newDeadline;
        emit TierExtended(currentTier, _newDeadline);
    }

    // Modify the getCurrentTier function to check both tokens sold and deadlines
    function getCurrentTier() public view returns (uint256) {
        // First check if any tier deadlines have passed
        for (uint256 i = currentTier; i < tierCount - 1; i++) {
            if (tierDeadlines[i] > 0 && block.timestamp >= tierDeadlines[i]) {
                return i + 1; // Move to next tier if deadline passed
            }
        }
        
        // Then check token sales as before
        uint256 tokensSold = totalTokensSold();
        for (uint256 i = tierCount - 1; i > 0; i--) {
            if (tokensSold >= maxTokensForTier[i-1]) {
                return i;
            }
        }
        return 0; // Default to first tier
    }

    // Also add a helper function to calculate total tokens sold
    function totalTokensSold() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < tiers.length; i++) {
            total += tiers[i].sold;
        }
        return total;
    }

    /**
    * @dev Get the number of tokens remaining in a specific tier
    * @param _tierId The tier ID to check
    * @return uint96 The number of tokens remaining in the tier
    */
    function tokensRemainingInTier(uint256 _tierId) public view returns (uint96) {
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTier storage tier = tiers[_tierId];
        return uint96(tier.allocation - tier.sold);
    }

    /**
    * @dev Get the number of tokens remaining in the current tier
    * @return uint96 The number of tokens remaining
    */
    function tokensRemainingInCurrentTier() external view returns (uint96) {
        return tokensRemainingInTier(currentTier);
    }

    /**
    * @dev Set the maximum tokens that can be purchased by a single address
    * @param _maxTokens The maximum number of tokens
    */
    function setMaxTokensPerAddress(uint96 _maxTokens) external onlyOwner {
        require(_maxTokens > 0, "Max tokens must be positive");
        maxTokensPerAddress = _maxTokens;
    }

    /**
    * @dev Modifier to check if presale is not paused
    */
    modifier whenNotPaused() {
        require(!paused, "Presale is paused");
        _;
    }

    /**
    * @dev Pause the presale
    */
    function pausePresale() external onlyEmergency {
        paused = true;
    }

    /**
    * @dev Resume the presale
    */
    function resumePresale() external onlyOwner {
        paused = false;
    }

    function configurePurchaseRateLimits(
        uint256 _minTimeBetweenPurchases,
        uint256 _maxPurchaseAmount
    ) external onlyOwner {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyOwner {
        _setRegistry(_registry, Constants.CROWDSALE_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyAdmin {
        require(address(registry) != address(0), "CrowdSale: registry not set");

        // Update Token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newToken = registry.getContractAddress(Constants.TOKEN_NAME);
            address oldToken = address(token);

            if (newToken != oldToken) {
                token = ERC20Upgradeable(newToken);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, newToken);
            }
        }

        // Update StabilityFund reference for price oracle
        if (registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

            // Here we might need to update any reference to the stability fund
            // For example, if the crowdsale uses the stability fund for pricing
        }
    }

    /**
     * @dev Record purchase in stability fund for tracking
     * This function can only be called by the contract itself
     * @param _user Purchaser address
     * @param _tokenAmount Amount of tokens purchased
     * @param _usdAmount USD amount spent
     */
    function recordPurchaseInStabilityFund(
        address _user,
        uint256 _tokenAmount,
        uint256 _usdAmount
    ) external returns (bool success){
        require(msg.sender == address(this), "CrowdSale: unauthorized");

        // Verify registry and stability fund are properly set
        if (address(registry) == address(0) || !registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            // Log issue but don't revert
            emit StabilityFundRecordingFailed(_user, "Registry or StabilityFund not available");
            return false;
        }
        
        address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

        // Call the recordTokenPurchase function in StabilityFund
        (bool success, ) = stabilityFund.call(
            abi.encodeWithSignature(
                "recordTokenPurchase(address,uint256,uint256)",
                _user,
                _tokenAmount,
                _usdAmount
            )
        );
        return success;
        // We don't revert on failure since this is a non-critical operation
    }

    /**
     * @dev Handles emergency pause notification from the StabilityFund
     * Only callable by the StabilityFund contract
     */
    function handleEmergencyPause() external onlyFromRegistry(Constants.STABILITY_FUND_NAME) {
        if (!paused) {
            paused = true;
            emergencyPauseTime = block.timestamp;
            emit EmergencyPaused(msg.sender, block.timestamp);
        }
    }

    /**
     * @dev Allows governance to update parameters during emergency
     * @param _minTimeBetweenPurchases New minimum time between purchases
     * @param _maxPurchaseAmount New maximum purchase amount
     */
    function emergencyUpdateLimits(
        uint256 _minTimeBetweenPurchases,
        uint256 _maxPurchaseAmount
    ) external onlyFromRegistry(Constants.GOVERNANCE_NAME) {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }

    // Function to get claim history
    function getClaimHistory(address _user) external view returns (ClaimEvent[] memory) {
        return claimHistory[_user];
    }

    function getNextVestingMilestone(address _user) public view returns (
        uint256 timestamp,
        uint256 amount
    ) {
        if (!tgeCompleted) return (0, 0);

        Purchase storage userPurchase = purchases[_user];
        if (userPurchase.tokens == 0) return (0, 0);

        // Calculate next vesting event
        uint256 elapsedMonths = (block.timestamp - presaleEnd) / 30 days;
        uint256 nextMonthTimestamp = presaleEnd + ((elapsedMonths + 1)  * 30 days);

        // Calculate tokens from each tier that will vest at next milestone
        uint256 nextAmount = 0;

        for (uint256 tierId = 0; tierId < tiers.length; tierId++) {
            if (tierId >= userPurchase.tierAmounts.length || userPurchase.tierAmounts[tierId] == 0) continue;

            PresaleTier storage tier = tiers[tierId];
            uint256 tierTokens = (userPurchase.tierAmounts[tierId] * (10**18)) / (tier.price);

            // Skip TGE portion
            uint256 tgeAmount = (tierTokens * tier.vestingTGE) / 100;
            uint256 vestingAmount = tierTokens - tgeAmount;

            // Calculate next month's vesting amount
            if (elapsedMonths < tier.vestingMonths) {
                uint256 monthlyVesting = vestingAmount / tier.vestingMonths;
                nextAmount = nextAmount + monthlyVesting;
            }
        }

        return (nextMonthTimestamp, nextAmount);
    }

    function batchDistributeTokens(address[] calldata _users) external onlyOwner nonReentrant {
        require(tgeCompleted, "TGE not completed yet");

        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 claimable = claimableTokens(user);

            if (claimable > 0) {
                // Update user's token balance
                purchases[user].tokens = purchases[user].tokens - claimable;

                // Record this claim event
                claimHistory[user].push(ClaimEvent({
                    amount: claimable,
                    timestamp: block.timestamp
                }));

                // Transfer tokens to user
                require(token.transfer(user, claimable), "Token transfer failed");

                emit TokensWithdrawn(user, claimable);
            }
        }
    }

    function setAutoCompound(bool _enabled) external {
        autoCompoundEnabled[msg.sender] = _enabled;
        emit AutoCompoundUpdated(msg.sender, _enabled);
    }

    /**
    * @dev Initiates emergency recovery mode
    * Only callable by emergency admin
    */
    function initiateEmergencyRecovery() external onlyEmergency {
        require(paused, "CrowdSale: not paused");
        inEmergencyRecovery = true;
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    /**
    * @dev Completes emergency recovery mode and resumes normal operations
    * Only callable by admin role
    */
    function completeEmergencyRecovery() external onlyAdmin {
        require(inEmergencyRecovery, "CrowdSale: not in recovery mode");
        inEmergencyRecovery = false;
        paused = false;
        emit EmergencyRecoveryCompleted(msg.sender, block.timestamp);
    }

    /**
 * @dev In case of critical emergency, allows users to withdraw their USDC
 * This is only available during emergency recovery mode
 */
    function emergencyWithdraw() external nonReentrant {
        require(inEmergencyRecovery, "CrowdSale: not in recovery mode");
        require(!emergencyWithdrawalsProcessed[msg.sender], "CrowdSale: already processed");

        // Calculate refundable amount (simplified, you may want more complex logic)
        uint256 refundAmount = 0;
        Purchase storage userPurchase = purchases[msg.sender];

        if (userPurchase.usdAmount > 0) {
            refundAmount = uint256(userPurchase.usdAmount);

            // Mark as processed
            emergencyWithdrawalsProcessed[msg.sender] = true;

            // Return funds
            require(paymentToken.transfer(msg.sender, refundAmount), "CrowdSale: transfer failed");

            emit EmergencyWithdrawalProcessed(msg.sender, refundAmount);
        }
    }

    /**
    * @dev Declare different levels of emergency based on severity
    */
    function declareEmergency(EmergencyState _state) external onlyEmergency {
        emergencyState = _state;
        paused = (_state != EmergencyState.NORMAL);

        if (_state == EmergencyState.CRITICAL_EMERGENCY) {
            inRecoveryMode = true;
            // Additional critical actions
        }

        emit EmergencyStateChanged(_state);
    }

    /**
    * @dev System for multi-signature approval of recovery actions
    */
    function approveRecovery() external onlyAdmin {
        require(inRecoveryMode, "CrowdSale: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "CrowdSale: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;

        if (countRecoveryApprovals() >= requiredRecoveryApprovals) {
            executeRecovery();
        }
    }

    // Improved implementation to handle edge cases
    function calculateVestedAmount(
        uint256 totalAmount,
        uint16 tgePercentage,
        uint16 vestingMonths,
        uint256 startTime,
        uint256 currentTime
    ) internal pure returns (uint256) {
        // Handle immediate vesting case
        if (vestingMonths == 0) {
            return totalAmount;
        }

        // Calculate TGE amount
        uint256 tgeAmount = (totalAmount * tgePercentage) / 100;

        // Calculate remaining amount to vest
        uint256 vestingAmount = totalAmount - tgeAmount;

        // Calculate elapsed time in precise units (seconds)
        uint256 elapsed = currentTime - startTime;
        uint256 vestingPeriod = uint256(vestingMonths) * 30 days;

        // If past vesting period, return full amount
        if (elapsed >= vestingPeriod) {
            return totalAmount;
        }

        // Calculate vested portion with higher precision
        // Use fixed point math with 10^18 precision
        uint256 precision = 10**18;
        uint256 vestedPortion = (elapsed * precision) / vestingPeriod;
        uint256 vestedVestingAmount = (vestingAmount * vestedPortion) / precision;

        return tgeAmount + vestedVestingAmount;
    }
    
    function executeRecovery() internal {
        require(inRecoveryMode, "CrowdSale: not in recovery mode");
        require(countRecoveryApprovals() >= requiredRecoveryApprovals, "CrowdSale: insufficient approvals");

        // Reset emergency state
        inRecoveryMode = false;
        paused = false;
        emergencyState = EmergencyState.NORMAL;

        // Clear approvals
        for (uint i = 0; i < _getAdminCount(); i++) {
            address admin = getApprover(i); 
            emergencyRecoveryApprovals[admin] = false;
        }

        emit EmergencyRecoveryCompleted(msg.sender, block.timestamp);
    }

    // Add helper function to count approvals
    function countRecoveryApprovals() public view returns (uint256) {
        uint256 count = 0;
        for (uint i = 0; i < _getAdminCount(); i++) { // Implement _getAdminCount function
            address admin = getApprover(i);
            if (emergencyRecoveryApprovals[admin]) {
                count++;
            }
        }
        return count;
    }

    function _getAdminCount() internal view returns (uint256) {
        return getRoleMemberCount(Constants.ADMIN_ROLE);
    }

    function getApprover(uint256 index) public view returns (address) {
        require(index < getRoleMemberCount(Constants.ADMIN_ROLE), "Invalid approver index");
        return getRoleMember(Constants.ADMIN_ROLE, index);
    }

    // Update cache periodically
    function updateAddressCache() public {
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    _cachedTokenAddress = tokenAddress;
                }
            } catch {}

            try registry.getContractAddress(Constants.STABILITY_FUND_NAME) returns (address stabilityFund) {
                if (stabilityFund != address(0)) {
                    _cachedStabilityFundAddress = stabilityFund;
                }
            } catch {}

            _lastCacheUpdate = block.timestamp;
        }
    }

    /**
     * @dev Retrieves the address of the token contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getTokenAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0) && !registryOfflineMode) {
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

        // Third attempt: Use explicitly set fallback address
        address fallbackAddress = _fallbackAddresses[Constants.TOKEN_NAME];
        if (fallbackAddress != address(0)) {
            return fallbackAddress;
        }

        // Final fallback: Use hardcoded address (if appropriate) or revert
        revert("Token address unavailable through all fallback mechanisms");
    }

    function getRoleMemberCount(bytes32 role) internal view returns (uint256) {
        return AccessControlUpgradeable.getRoleMemberCount(role);
    }

    function getRoleMember(bytes32 role, uint256 index) internal view returns (address) {
        return AccessControlUpgradeable.getRoleMember(role, index);
    }
}