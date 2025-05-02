// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {VestingCalculations} from "./Libraries/VestingCalculations.sol";
import {Constants} from "./Libraries/Constants.sol";
import {PresaleTiers} from "./Libraries/PresaleTiers.sol";

/**
 * @title GenericTokenPresale
 * @dev Multi-tier presale contract for any ERC20 token
 */
contract TokenCrowdSale is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{

    using PresaleTiers for PresaleTiers.PresaleTier[];

    // User purchase tracking
    struct Purchase {
        uint96 tokens;      // Total tokens purchased
        uint96 usdAmount;   // USD amount paid
        uint96[] tierAmounts; // Amount purchased in each tier
        uint96 lastClaimTime; // Last time user claimed tokens
    }

    struct ClaimEvent {
        uint96 amount;
        uint40 timestamp;
    }

    ERC20Upgradeable internal token;

    // Emergency state tracking
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }
    EmergencyState public emergencyState;

    // Emergency thresholds
    uint8 public constant MINOR_EMERGENCY_THRESHOLD = 1;
    uint8 public constant CRITICAL_EMERGENCY_THRESHOLD = 2;

    // Emergency recovery tracking
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint8 public requiredRecoveryApprovals;

    uint8 public currentTier = 0;
    uint8 public tierCount;
    mapping(uint96 => uint96) public maxTokensForTier;

    // Payment token (USDC)
    ERC20Upgradeable public paymentToken;

    // Presale tiers
    PresaleTiers.PresaleTier[] public tiers;

    // Mapping from user address to purchase info
    mapping(address => Purchase) public purchases;

    //Check for Roles
    mapping(bytes32 => mapping(address => bool)) private roleMembership;
    mapping(address => uint32) private userTotalTokens;  // Total tokens purchased by user
    mapping(address => uint96) private userTotalValue;   // Total value (in stablecoin units) spent by user

    // Treasury wallet to receive funds
    address public treasury;

    // Presale start and end times
    uint40 public presaleStart;
    uint40 public presaleEnd;

    // Whether tokens have been generated and initial distribution occurred
    bool public tgeCompleted = false;

    // USD price scaling factor (6 decimal places)
    uint32 public constant PRICE_DECIMALS = 1e6;

    // Maximum tokens purchasable by a single address across all tiers
    uint96 public maxTokensPerAddress;

    // Presale pause status
    bool public paused;

    // Mapping to track total tokens purchased by each address
    mapping(address => uint32) public addressTokensPurchased;

    // Add to existing contract
    mapping(uint256 => uint40) public tierDeadlines; // Timestamps for tier deadlines

    mapping(address => uint40) public lastPurchaseTime;
    uint40 public minTimeBetweenPurchases = 1 hours;
    uint96 public maxPurchaseAmount = 50_000 * PRICE_DECIMALS; // $50,000 default max

    // Add mapping to track claims history
    mapping(address => ClaimEvent[]) public claimHistory;

    mapping(address => bool) public autoCompoundEnabled;

    // Emergency state variables
    bool public inEmergencyRecovery = false;
    uint40 public emergencyPauseTime;
    mapping(address => bool) public emergencyWithdrawalsProcessed;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint96 private _lastCacheUpdate;

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

    modifier purchaseRateLimit(uint96 _usdAmount) {
        require(
            block.timestamp >= lastPurchaseTime[msg.sender] + minTimeBetweenPurchases,
            "CrowdSale: purchase too soon after previous"
        );

        require(
            _usdAmount <= maxPurchaseAmount,
            "CrowdSale: amount exceeds maximum purchase limit"
        );

        lastPurchaseTime[msg.sender] = uint40(block.timestamp);
        _;
    }

    modifier whenContractNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "TokenCrowdSale: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                require(!paused, "TokenCrowdSale: contract is paused");
            }
            require(!registryOfflineMode, "TokenCrowdSale: registry Offline");
        } else {
            require(!paused, "TokenCrowdSale: contract is paused");
        }
        _;
    }

    //constructor(){
    //    _disableInitializers();
    // }

    /**
     * @dev Initializer function to replace constructor
     * @param _paymentToken Address of the payment token (USDC)
     * @param _treasury Address to receive presale funds
     */
    function initialize(
        ERC20Upgradeable  _paymentToken, address _treasury) initializer public {

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        paymentToken = _paymentToken;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(Constants.RECORDER_ROLE, msg.sender);

        tiers = PresaleTiers.getStandardTiers();
        tierCount = uint8(tiers.length);

        // Calculate tier maximums
        for (uint8 i = 0; i < tierCount; i++) {
            uint96 tierTotal = 0;
            for (uint8 j = 0; j <= i; j++) {
                tierTotal += tiers[j].allocation;
            }
            maxTokensForTier[i] = tierTotal;
        }

        // Inside the constructor, add:
        maxTokensPerAddress = 1_500_000 * 10**18; // 1.5M tokens by default
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    function addRecorder(address _recorder) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        uint32 _tokenAmount,
        uint96 _purchaseValue
    ) external onlyRole(Constants.RECORDER_ROLE) whenContractNotPaused {
        userTotalTokens[_user] += _tokenAmount;
        userTotalValue[_user] += _purchaseValue;
    }

    /**
     * @dev Set the token address after deployment
     * @param _token Address of the ERC20 token contract
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
    function setPresaleTimes(uint40 _start, uint40 _end) external onlyOwner {
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
    function setTierStatus(uint8 _tierId, bool _isActive) external onlyOwner {
        require(_tierId < tiers.length, "Invalid tier ID");
        tiers[_tierId].isActive = _isActive;
        emit TierStatusChanged(_tierId, _isActive);
    }

    /**
     * @dev Purchase tokens in a specific tier
     * @param _tierId Tier to purchase from
     * @param _usdAmount USD amount to spend (scaled by 1e6)
     */
    function purchase(uint8 _tierId, uint96 _usdAmount) external nonReentrant whenContractNotPaused purchaseRateLimit(_usdAmount) {
        require(uint40(block.timestamp) >= presaleStart && uint40(block.timestamp) <= presaleEnd, "Presale not active");
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTiers.PresaleTier storage tier = tiers[_tierId];
        require(tier.isActive, "Tier not active");

        // For earlier tiers (0-3), require whitelist
        //if (_tierId <= 3) {
        //    require(whitelist[msg.sender], "Not whitelisted for this tier");
        //}

        // Validate purchase amount
        require(_usdAmount >= tier.minPurchase, "Below minimum purchase");
        require(_usdAmount <= tier.maxPurchase, "Above maximum purchase");

        // Check if user's total purchase would exceed max
        uint96 userTierTotal = purchases[msg.sender].tierAmounts.length > _tierId
            ? purchases[msg.sender].tierAmounts[_tierId] + _usdAmount
            : _usdAmount;
        require(userTierTotal <= tier.maxPurchase, "Would exceed max tier purchase");

        // Calculate token amount
        uint96 tokenAmount = (_usdAmount * 10**18) / tier.price;

        // Check total cap per address
        require(addressTokensPurchased[msg.sender] + uint96(tokenAmount) <= maxTokensPerAddress, "Exceeds max tokens per address");

        // Check if there's enough allocation left
        require(tier.sold + tokenAmount <= tier.allocation, "Insufficient tier allocation");

        // Update tier data
        tier.sold = uint96(tier.sold + tokenAmount);

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens = uint32(userPurchase.tokens + tokenAmount);
        userPurchase.usdAmount = uint96(userPurchase.usdAmount + _usdAmount);

        // Transfer payment tokens from user to treasury
        require(paymentToken.transferFrom(msg.sender, treasury, _usdAmount), "Payment failed");

        // Update total tokens purchased by address
        addressTokensPurchased[msg.sender] += uint32(tokenAmount);

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
    function completeTGE() external onlyRole(DEFAULT_ADMIN_ROLE) whenContractNotPaused {
        require(!tgeCompleted, "TGE already completed");
        require(uint40(block.timestamp) > presaleEnd, "Presale still active");
        tgeCompleted = true;
    }

    /**
     * @dev Calculate currently claimable tokens for a user
     * @param _user Address to check
     * @return claimable Amount of tokens claimable
     */
    function claimableTokens(address _user) public view returns (uint96 claimable) {
        if (!tgeCompleted) return 0;

        Purchase storage userPurchase = purchases[_user];
        uint96 totalPurchased = userPurchase.tokens;
        if (totalPurchased == 0) return 0;

        // Calculate tokens from each tier
        uint96 totalClaimable = 0;

        // Only loop through tiers where the user has invested
        uint96[] storage tierAmounts = userPurchase.tierAmounts;
        uint8 userTierCount = uint8(tierAmounts.length);

        for (uint8 tierId = 0; tierId < userTierCount; tierId++) {
            // Skip tiers where user hasn't purchased
            if (tierAmounts[tierId] == 0) continue;

            PresaleTiers.PresaleTier storage tier = tiers[tierId];
            uint96 tierTokens = (tierAmounts[tierId] * 10**18) / tier.price;

            uint96 tierClaimable = VestingCalculations.calculateVestedAmount(
                tierTokens,
                tier.vestingTGE,
                tier.vestingMonths,
                presaleEnd,
                uint96(block.timestamp)
            );

            totalClaimable = totalClaimable + tierClaimable;

            // Add auto-compound bonus if enabled
            if (autoCompoundEnabled[_user] && totalClaimable > 0) {
                // Calculate bonus based on how long tokens were unclaimed (up to 5% annual bonus)
                uint96 maxAnnualBonus = (totalClaimable * 5) / 100;
                uint96 timeUnclaimed = uint96(block.timestamp) - userPurchase.lastClaimTime;
                uint96 bonus = (maxAnnualBonus * timeUnclaimed) / 365 days;

                totalClaimable = totalClaimable + bonus;
            }
        }

        // Subtract already claimed tokens
        uint96 alreadyClaimed = totalPurchased - userPurchase.tokens;

        return totalClaimable > alreadyClaimed ? totalClaimable - alreadyClaimed : 0;
    }

    /**
     * @dev Withdraw available tokens based on vesting schedule
     */
    function withdrawTokens() external nonReentrant whenContractNotPaused{
        require(tgeCompleted, "TGE not completed yet");

        uint96 claimable = claimableTokens(msg.sender);
        require(claimable > 0, "No tokens available to claim");

        // Update user's last claim time
        purchases[msg.sender].lastClaimTime = uint40(block.timestamp);

        // Update user's token balance
        purchases[msg.sender].tokens = purchases[msg.sender].tokens - claimable;

        // Record this claim event
        claimHistory[msg.sender].push(ClaimEvent({
            amount: claimable,
            timestamp: uint40(block.timestamp)
        }));

        // Transfer tokens to user
        require(token.transfer(msg.sender, claimable), "Token transfer failed");

        emit TokensWithdrawn(msg.sender, claimable);
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(ERC20Upgradeable _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(_token) != address(token), "Cannot recover tokens");
        uint96 balance = uint96(_token.balanceOf(address(this)));
        require(balance > 0, "No tokens to recover");
        require(_token.transfer(owner(), balance), "Token recovery failed");
    }

    // New function to set tier deadlines
    function setTierDeadline(uint8 _tier, uint40 _deadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tier < tierCount, "Crowdsale: invalid tier");
        require(_deadline > block.timestamp, "Crowdsale: deadline in past");
        tierDeadlines[_tier] = _deadline;
        emit TierDeadlineUpdated(_tier, _deadline);
    }

    // New function to manually advance tier
    function advanceTier() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(currentTier < tierCount - 1, "Crowdsale: already at final tier");
        currentTier++;
        emit TierAdvanced(currentTier);
    }

    // New function to extend current tier
    function extendTier(uint40 _newDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newDeadline > tierDeadlines[currentTier], "Crowdsale: new deadline must be later");
        tierDeadlines[currentTier] = _newDeadline;
        emit TierExtended(currentTier, _newDeadline);
    }

    // Modify the getCurrentTier function to check both tokens sold and deadlines
    function getCurrentTier() public view returns (uint8) {
        // First check if any tier deadlines have passed
        for (uint8 i = currentTier; i < tierCount - 1; i++) {
            if (tierDeadlines[i] > 0 && block.timestamp >= tierDeadlines[i]) {
                return i + 1; // Move to next tier if deadline passed
            }
        }

        // Then check token sales as before
        uint96 tokensSold = totalTokensSold();
        for (uint8 i = tierCount - 1; i > 0; i--) {
            if (tokensSold >= maxTokensForTier[i-1]) {
                return i;
            }
        }
        return 0; // Default to first tier
    }

    // Also add a helper function to calculate total tokens sold
    function totalTokensSold() public view returns (uint96) {
        return PresaleTiers.calculateTotalTokensSold(tiers);
    }

    /**
    * @dev Get the number of tokens remaining in a specific tier
    * @param _tierId The tier ID to check
    * @return uint96 The number of tokens remaining in the tier
    */
    function tokensRemainingInTier(uint8 _tierId) public view returns (uint32) {
        require(_tierId < tiers.length, "Invalid tier ID");
        return PresaleTiers.tokensRemainingInTier(tiers[_tierId]);
    }

    /**
    * @dev Get the number of tokens remaining in the current tier
    * @return uint96 The number of tokens remaining
    */
    function tokensRemainingInCurrentTier() external view returns (uint32) {
        return tokensRemainingInTier(currentTier);
    }

    /**
    * @dev Set the maximum tokens that can be purchased by a single address
    * @param _maxTokens The maximum number of tokens
    */
    function setMaxTokensPerAddress(uint32 _maxTokens) external onlyRole(DEFAULT_ADMIN_ROLE){
        require(_maxTokens > 0, "Max tokens must be positive");
        maxTokensPerAddress = _maxTokens;
    }

    /**
    * @dev Pause the presale
    */
    function pausePresale() external onlyRole(Constants.EMERGENCY_ROLE) {
        _updateEmergencyState(
            EmergencyState.MINOR_EMERGENCY,
            true,  // paused
            inEmergencyRecovery  // maintain current recovery state
        );
    }

    /**
    * @dev Resume the presale
    */
    function resumePresale() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateEmergencyState(
            EmergencyState.NORMAL,
            false,  // not paused
            false   // exit recovery mode
        );
    }

    function configurePurchaseRateLimits(
        uint40 _minTimeBetweenPurchases,
        uint96 _maxPurchaseAmount
    ) external onlyOwner {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRegistry(_registry, Constants.CROWDSALE_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractCache() external onlyRole(Constants.ADMIN_ROLE) {
        require(address(registry) != address(0), "CrowdSale: registry not set");

        // Update Token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newToken = registry.getContractAddress(Constants.TOKEN_NAME);
            address oldToken = address(_cachedTokenAddress);

            if (newToken != oldToken) {
                token = ERC20Upgradeable(newToken);
                _cachedTokenAddress=newToken;
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, newToken);
            }
        }

        // Update StabilityFund reference for price oracle
        if (registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            address newStabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);
            address oldStabilityFund = address(_cachedStabilityFundAddress);

            if (newStabilityFund != oldStabilityFund) {
                // Update the stabilityFund reference if you have one
                _cachedStabilityFundAddress = newStabilityFund;
                emit ContractReferenceUpdated(Constants.STABILITY_FUND_NAME, oldStabilityFund, newStabilityFund);
            }        }
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
        uint96 _tokenAmount,
        uint96 _usdAmount
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
        (success,) = stabilityFund.call(
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
            emergencyPauseTime = uint40(block.timestamp);
            emit EmergencyPaused(msg.sender, block.timestamp);
        }
    }

    /**
     * @dev Allows governance to update parameters during emergency
     * @param _minTimeBetweenPurchases New minimum time between purchases
     * @param _maxPurchaseAmount New maximum purchase amount
     */
    function emergencyUpdateLimits(
        uint40 _minTimeBetweenPurchases,
        uint96 _maxPurchaseAmount
    ) external onlyFromRegistry(Constants.GOVERNANCE_NAME) {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }

    // Function to get claim history
    function getClaimHistory(address _user) external view returns (ClaimEvent[] memory) {
        return claimHistory[_user];
    }

    function getNextVestingMilestone(address _user) public view returns (
        uint40 timestamp,
        uint32 amount
    ) {
        if (!tgeCompleted) return (0, 0);

        Purchase storage userPurchase = purchases[_user];
        if (userPurchase.tokens == 0) return (0, 0);

        // Calculate next vesting event
        uint16 elapsedMonths = uint16((block.timestamp - presaleEnd) / 30 days);
        uint16 nextMonthTimestamp = uint16(presaleEnd + ((elapsedMonths + 1)  * 30 days));

        // Calculate tokens from each tier that will vest at next milestone
        uint32 nextAmount = 0;

        for (uint8 tierId = 0; tierId < tiers.length; tierId++) {
            if (tierId >= userPurchase.tierAmounts.length || userPurchase.tierAmounts[tierId] == 0) continue;

            PresaleTiers.PresaleTier storage tier = tiers[tierId];
            uint96 tierTokens = (userPurchase.tierAmounts[tierId] * (10**18)) / (tier.price);

            // Skip TGE portion
            uint96 tgeAmount = (tierTokens * tier.vestingTGE) / 100;
            uint96 vestingAmount = tierTokens - tgeAmount;

            // Calculate next month's vesting amount
            if (elapsedMonths < tier.vestingMonths) {
                uint16 monthlyVesting = uint16(vestingAmount / tier.vestingMonths);
                nextAmount = nextAmount + monthlyVesting;
            }
        }

        return (nextMonthTimestamp, nextAmount);
    }

    function batchDistributeTokens(address[] calldata _users) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(tgeCompleted, "TGE not completed yet");

        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint96 claimable = claimableTokens(user);

            if (claimable > 0) {
                // Update user's token balance
                purchases[user].tokens = purchases[user].tokens - claimable;

                // Record this claim event
                claimHistory[user].push(ClaimEvent({
                    amount: claimable,
                    timestamp: uint40(block.timestamp)
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
    function initiateEmergencyRecovery() external onlyRole(Constants.EMERGENCY_ROLE) {
        require(paused, "CrowdSale: not paused");
        _updateEmergencyState(
            EmergencyState.CRITICAL_EMERGENCY,
            true,  // paused
            true   // in recovery mode
        );
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    /**
    * @dev Completes emergency recovery mode and resumes normal operations
    * Only callable by admin role
    */
    function completeEmergencyRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        require(inEmergencyRecovery, "CrowdSale: not in recovery mode");
        _updateEmergencyState(
            EmergencyState.NORMAL,
            false,  // not paused
            false   // not in recovery mode
        );
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
    function declareEmergency(EmergencyState _state) external onlyRole(Constants.EMERGENCY_ROLE) {
        bool shouldPause = (_state != EmergencyState.NORMAL);
        bool shouldEnterRecovery = (_state == EmergencyState.CRITICAL_EMERGENCY);

        _updateEmergencyState(_state, shouldPause, shouldEnterRecovery);

        emit EmergencyStateChanged(_state);
    }

    /**
    * @dev System for multi-signature approval of recovery actions
    */
    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        require(inEmergencyRecovery, "CrowdSale: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "CrowdSale: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;

        if (countRecoveryApprovals() >= requiredRecoveryApprovals) {
            executeRecovery();
        }
    }

    function executeRecovery() internal {
        require(inEmergencyRecovery, "CrowdSale: not in recovery mode");
        require(countRecoveryApprovals() >= requiredRecoveryApprovals, "CrowdSale: insufficient approvals");

        // Reset emergency state
        inEmergencyRecovery= false;
        paused = false;
        emergencyState = EmergencyState.NORMAL;

        // Clear approvals
        for (uint8 i = 0; i < _getAdminCount(); i++) {
            address admin = getApprover(i);
            emergencyRecoveryApprovals[admin] = false;
        }

        emit EmergencyRecoveryCompleted(msg.sender, block.timestamp);
    }

    // Add helper function to count approvals
    function countRecoveryApprovals() public view returns (uint8) {
        uint8 count = 0;
        bytes32 adminRole = Constants.ADMIN_ROLE;

        for (uint8 i = 0; i < _getAdminCount(); i++) {
            address admin = getRoleMember(adminRole, i);
            if (emergencyRecoveryApprovals[admin]) {
                count++;
            }
        }
        return count;
    }

    function _getAdminCount() internal view returns (uint256) {
        return getRoleMemberCount(Constants.ADMIN_ROLE);
    }

    function getApprover(uint8 index) public view returns (address) {
        require(index < getRoleMemberCount(Constants.ADMIN_ROLE), "Invalid approver index");
        return getRoleMember(Constants.ADMIN_ROLE, index);
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
                    _lastCacheUpdate = uint96(block.timestamp);
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

    /**
     * @dev Centralizes emergency state management to keep all state variables in sync
     * @param _state The new emergency state
     * @param _pauseState Whether to pause the contract
     * @param _recoveryMode Whether to enter recovery mode
     */
    function _updateEmergencyState(
        EmergencyState _state,
        bool _pauseState,
        bool _recoveryMode
    ) internal {
        emergencyState = _state;

        // Only change pause state if it differs from current
        if (paused != _pauseState) {
            paused = _pauseState;
            if (_pauseState) {
                emit EmergencyPaused(msg.sender, block.timestamp);
            }
        }

        // Only change recovery mode if it differs from current
        if (inEmergencyRecovery != _recoveryMode) {
            inEmergencyRecovery = _recoveryMode;
            if (_recoveryMode) {
                emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
            }
        }
    }
}