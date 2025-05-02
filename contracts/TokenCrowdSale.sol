// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./Registry/RegistryAwareUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import {VestingCalculations} from "./Libraries/VestingCalculations.sol";

/**
 * @title TokenCrowdSale
 * @dev Multi-tier presale contract for token sales, with all tier functionality integrated directly
 */
contract TokenCrowdSale is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Presale tiers structure - integrated directly into contract
    struct PresaleTier {
        uint96 price;         // Price in USD (scaled by 1e6)
        uint96 allocation;    // Total allocation for this tier
        uint96 sold;          // Amount sold in this tier
        uint96 minPurchase;   // Minimum purchase amount in USD
        uint96 maxPurchase;   // Maximum purchase amount in USD
        uint8 vestingTGE;     // Percentage released at TGE (scaled by 100)
        uint16 vestingMonths; // Remaining vesting period in months
        bool isActive;        // Whether this tier is currently active
    }

    // User purchase tracking
    struct Purchase {
        uint96 tokens;          // Total tokens purchased
        uint96 usdAmount;       // USD amount paid
        uint96[] tierAmounts;   // Amount purchased in each tier
        uint96 lastClaimTime;   // Last time user claimed tokens
    }

    struct ClaimEvent {
        uint128 amount;
        uint64 timestamp;
    }

    struct CachedAddresses {
        address token;
        address stabilityFund;
        uint64 lastUpdate;
    }

    ERC20Upgradeable internal token;

    // Emergency state tracking
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }
    EmergencyState public emergencyState;

    // Emergency thresholds
    uint8 public constant MINOR_EMERGENCY_THRESHOLD = 1;
    uint8 public constant CRITICAL_EMERGENCY_THRESHOLD = 2;

    // Emergency recovery tracking
    mapping(address => bool) public recoveryApprovals;
    uint8 public requiredRecoveryApprovals;
    uint8 public recoveryApprovalsCount;

    uint8 public currentTier;
    uint8 public tierCount;
    mapping(uint8 => uint96) public maxTokensForTier;

    // Payment token (USDC)
    ERC20Upgradeable public paymentToken;

    // Presale tiers
    PresaleTier[] public tiers;

    // Mapping from user address to purchase info
    mapping(address => Purchase) public purchases;

    // Treasury wallet to receive funds
    address public treasury;

    // Presale start and end times
    uint64 public presaleStart;
    uint64 public presaleEnd;

    // Whether tokens have been generated and initial distribution occurred
    bool public tgeCompleted;

    // USD price scaling factor (6 decimal places)
    uint32 public constant PRICE_DECIMALS = 1e6;

    // Maximum tokens purchasable by a single address across all tiers
    uint96 public maxTokensPerAddress;

    // Mapping to track total tokens purchased by each address
    mapping(address => uint96) public addressTokensPurchased;

    // Timestamps for tier deadlines
    mapping(uint8 => uint64) public tierDeadlines;

    mapping(address => uint64) public lastPurchaseTime;
    uint32 public minTimeBetweenPurchases;
    uint96 public maxPurchaseAmount;

    // Add mapping to track claims history
    mapping(address => ClaimEvent[]) public claimHistory;

    mapping(address => bool) public autoCompoundEnabled;

    uint64 public emergencyPauseTime;
    mapping(address => bool) public emergencyWithdrawalsProcessed;

    CachedAddresses private _cachedAddresses;

    // Events
    event TierPurchase(address indexed buyer, uint8 tierId, uint96 tokenAmount, uint96 usdAmount);
    event TierStatusChanged(uint8 tierId, bool isActive);
    event TokensWithdrawn(address indexed user, uint96 amount);
    event PresaleTimesUpdated(uint64 newStart, uint64 newEnd);
    event TierDeadlineUpdated(uint8 indexed tier, uint64 deadline);
    event TierAdvanced(uint8 indexed newTier);
    event TierExtended(uint8 indexed tier, uint64 newDeadline);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event EmergencyPaused(address indexed triggeredBy, uint64 timestamp);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint64 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint64 timestamp);
    event AutoCompoundUpdated(address indexed user, bool enabled);
    event EmergencyWithdrawalProcessed(address indexed user, uint96 amount);
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

        lastPurchaseTime[msg.sender] = uint64(block.timestamp);
        _;
    }

    modifier whenNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "TokenCrowdSale: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                require(emergencyState == EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
            }
            require(!registryOfflineMode, "TokenCrowdSale: registry Offline");
        } else {
            require(emergencyState == EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
        }
        _;
    }

    /**
     * @dev Creates standard tier configurations for token presale - moved from library to contract
     */
    function _createStandardTiers() internal pure returns (PresaleTier[] memory) {
        PresaleTier[] memory stdTiers = new PresaleTier[](7);

        // Tier 1:
        stdTiers[0] = PresaleTier({
            price: 35000, // $0.035
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 10, // 10% at TGE
            vestingMonths: 18, // 18 months vesting
            isActive: false
        });

        // Tier 2: 
        stdTiers[1] = PresaleTier({
            price: 45000, // $0.045
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 25_000 * PRICE_DECIMALS, // $25,000 max
            vestingTGE: 15, // 15% at TGE
            vestingMonths: 15, // 15 months vesting
            isActive: false
        });

        // Tier 3: 
        stdTiers[2] = PresaleTier({
            price: 55000, // $0.055
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 10_000 * PRICE_DECIMALS, // $10,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 12, // 12 months vesting
            isActive: false
        });

        // Tier 4:
        stdTiers[3] = PresaleTier({
            price: 70000, // $0.07
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 9, // 9 months vesting
            isActive: false
        });

        // Tier 5:
        stdTiers[4] = PresaleTier({
            price: 85000, // $0.085
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 50 * PRICE_DECIMALS, // $50 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 25, // 25% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        // Tier 6:
        stdTiers[5] = PresaleTier({
            price: 100000, // $0.10
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $20 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 30, // 30% at TGE
            vestingMonths: 4, // 4 months vesting
            isActive: false
        });

        // Tier 7:
        stdTiers[6] = PresaleTier({
            price: 120000, // $0.12
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $20 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 40, // 40% at TGE
            vestingMonths: 3, // 3 months vesting
            isActive: false
        });

        return stdTiers;
    }

    /**
     * @dev Calculate tier maximum values - moved from library to contract
     */
    function _calculateTierMaximums() internal {
        for (uint8 i = 0; i < tiers.length; i++) {
            uint96 tierTotal = 0;
            for (uint8 j = 0; j <= i; j++) {
                tierTotal += tiers[j].allocation;
            }
            maxTokensForTier[i] = tierTotal;
        }
    }

    /**
     * @dev Calculate tokens remaining in a tier - moved from library to contract
     */
    function tokensRemainingInTier(uint8 _tierId) public view returns (uint96) {
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTier storage tier = tiers[_tierId];
        if (tier.allocation <= tier.sold) {
            return 0;
        }
        return tier.allocation - tier.sold;
    }

    /**
     * @dev Calculate total tokens sold across all tiers - moved from library to contract
     */
    function totalTokensSold() public view returns (uint96 total) {
        total = 0;
        for (uint8 i = 0; i < tiers.length; i++) {
            total += tiers[i].sold;
        }
        return total;
    }

    /**
     * @dev Initializer function to replace constructor
     * @param _paymentToken Address of the payment token (USDC)
     * @param _treasury Address to receive presale funds
     */
    function initialize(
        ERC20Upgradeable _paymentToken,
        address _treasury
    ) initializer public {
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

        // Create standard tiers directly instead of using library
        tiers = _createStandardTiers();
        tierCount = uint8(tiers.length);

        // Initialize state variables
        emergencyState = EmergencyState.NORMAL;
        currentTier = 0;
        tgeCompleted = false;
        requiredRecoveryApprovals = 3;
        recoveryApprovalsCount = 0;
        minTimeBetweenPurchases = 1 hours;
        maxPurchaseAmount = 50_000 * uint96(PRICE_DECIMALS); // $50,000 default max

        // Calculate tier maximums
        _calculateTierMaximums();

        maxTokensPerAddress = 1_500_000 * 10**18; // 1.5M tokens by default

        // Initialize cache
        _cachedAddresses = CachedAddresses({
            token: address(0),
            stabilityFund: address(0),
            lastUpdate: 0
        });
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
     * @dev Records a token purchase for tracking
     * @param _user Address of the user
     * @param _tokenAmount Amount of tokens purchased
     * @param _purchaseValue Value paid in stable coin units
     */
    function recordTokenPurchase(
        address _user,
        uint96 _tokenAmount,
        uint96 _purchaseValue
    ) external onlyRole(Constants.RECORDER_ROLE) whenNotPaused {
        // This function only records data - no storage needed
        if (address(registry) != address(0) && registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            try this.recordPurchaseInStabilityFund(_user, _tokenAmount, _purchaseValue) {} catch {}
        }
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
    function setPresaleTimes(uint64 _start, uint64 _end) external onlyOwner {
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
    function purchase(uint8 _tierId, uint96 _usdAmount) external nonReentrant whenNotPaused purchaseRateLimit(_usdAmount) {
        require(block.timestamp >= presaleStart && block.timestamp <= presaleEnd, "Presale not active");
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTier storage tier = tiers[_tierId];
        require(tier.isActive, "Tier not active");

        // Validate purchase amount
        require(_usdAmount >= tier.minPurchase, "Below minimum purchase");
        require(_usdAmount <= tier.maxPurchase, "Above maximum purchase");

        // Check if user's total purchase would exceed max
        uint96 userTierTotal = purchases[msg.sender].tierAmounts.length > _tierId
            ? purchases[msg.sender].tierAmounts[_tierId] + _usdAmount
            : _usdAmount;
        require(userTierTotal <= tier.maxPurchase, "Would exceed max tier purchase");

        // Calculate token amount
        uint96 tokenAmount = uint96((_usdAmount * 10**18) / tier.price);

        // Check total cap per address
        require(addressTokensPurchased[msg.sender] + tokenAmount <= maxTokensPerAddress, "Exceeds max tokens per address");

        // Check if there's enough allocation left
        require(tier.sold + tokenAmount <= tier.allocation, "Insufficient tier allocation");

        // Update tier data
        tier.sold = tier.sold + tokenAmount;

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens = userPurchase.tokens + tokenAmount;
        userPurchase.usdAmount = userPurchase.usdAmount + _usdAmount;

        // Transfer payment tokens from user to treasury
        require(paymentToken.transferFrom(msg.sender, treasury, _usdAmount), "Payment failed");

        // Update total tokens purchased by address
        addressTokensPurchased[msg.sender] += tokenAmount;

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
    function completeTGE() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(!tgeCompleted, "TGE already completed");
        require(block.timestamp > presaleEnd, "Presale still active");
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

            PresaleTier storage tier = tiers[tierId];
            uint96 tierTokens = uint96((tierAmounts[tierId] * 10**18) / tier.price);

            uint96 tierClaimable = VestingCalculations.calculateVestedAmount(
                tierTokens,
                tier.vestingTGE,
                tier.vestingMonths,
                userPurchase.lastClaimTime > 0 ? userPurchase.lastClaimTime : presaleEnd,
                uint96(block.timestamp)
            );

            totalClaimable = totalClaimable + tierClaimable;

            // Add auto-compound bonus if enabled
            if (autoCompoundEnabled[_user] && totalClaimable > 0 && userPurchase.lastClaimTime > 0) {
                // Calculate bonus based on how long tokens were unclaimed (up to 5% annual bonus)
                uint96 maxAnnualBonus = (totalClaimable * 5) / 100;
                uint96 timeUnclaimed = uint96(block.timestamp) - userPurchase.lastClaimTime;
                uint96 bonus = uint96((maxAnnualBonus * timeUnclaimed) / 365 days);

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
    function withdrawTokens() external nonReentrant whenNotPaused {
        require(tgeCompleted, "TGE not completed yet");

        uint96 claimable = claimableTokens(msg.sender);
        require(claimable > 0, "No tokens available to claim");

        // Update user's last claim time
        purchases[msg.sender].lastClaimTime = uint96(block.timestamp);

        // Update user's token balance
        purchases[msg.sender].tokens = purchases[msg.sender].tokens - claimable;

        // Record this claim event
        claimHistory[msg.sender].push(ClaimEvent({
            amount: uint128(claimable),
            timestamp: uint64(block.timestamp)
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
        uint256 balance = _token.balanceOf(address(this));
        require(balance > 0, "No tokens to recover");
        require(_token.transfer(owner(), balance), "Token recovery failed");
    }

    // New function to set tier deadlines
    function setTierDeadline(uint8 _tier, uint64 _deadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tier < tierCount, "Crowdsale: invalid tier");
        require(_deadline > uint64(block.timestamp), "Crowdsale: deadline in past");
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
    function extendTier(uint64 _newDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newDeadline > tierDeadlines[currentTier], "Crowdsale: new deadline must be later");
        tierDeadlines[currentTier] = _newDeadline;
        emit TierExtended(currentTier, _newDeadline);
    }

    // Get current tier based on tokens sold and deadlines
    function getCurrentTier() public view returns (uint8) {
        // First check if any tier deadlines have passed
        for (uint8 i = currentTier; i < tierCount - 1; i++) {
            if (tierDeadlines[i] > 0 && block.timestamp >= tierDeadlines[i]) {
                return i + 1; // Move to next tier if deadline passed
            }
        }

        // Then check token sales
        uint96 tokensSold = totalTokensSold();
        for (uint8 i = uint8(tierCount - 1); i > 0; i--) {
            if (tokensSold >= maxTokensForTier[i-1]) {
                return i;
            }
        }
        return 0; // Default to first tier
    }

    /**
     * @dev Get the number of tokens remaining in the current tier
     * @return amount The number of tokens remaining
     */
    function tokensRemainingInCurrentTier() external view returns (uint96 amount) {
        return tokensRemainingInTier(currentTier);
    }

    /**
     * @dev Set the maximum tokens that can be purchased by a single address
     * @param _maxTokens The maximum number of tokens
     */
    function setMaxTokensPerAddress(uint96 _maxTokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxTokens > 0, "Max tokens must be positive");
        maxTokensPerAddress = _maxTokens;
    }

    /**
     * @dev Emergency function to allow setting emergency state
     * @param _stateValue The emergency state to set (0=NORMAL, 1=MINOR, 2=CRITICAL)
     */
    function _setEmergencyState(uint8 _stateValue) internal onlyRole(Constants.EMERGENCY_ROLE) {
        EmergencyState newState;
        if (_stateValue == 0) {
            newState = EmergencyState.NORMAL;
        } else if (_stateValue == 1) {
            newState = EmergencyState.MINOR_EMERGENCY;
        } else {
            newState = EmergencyState.CRITICAL_EMERGENCY;
        }

        EmergencyState oldState = emergencyState;
        emergencyState = newState;

        // Handle pause/unpause based on state
        if (newState != EmergencyState.NORMAL && oldState == EmergencyState.NORMAL) {
            emergencyPauseTime = uint64(block.timestamp);
            emit EmergencyPaused(msg.sender, uint64(block.timestamp));
        }

        // Handle recovery mode
        if (newState == EmergencyState.CRITICAL_EMERGENCY && oldState != EmergencyState.CRITICAL_EMERGENCY) {
            emit EmergencyRecoveryInitiated(msg.sender, uint64(block.timestamp));
        } else if (newState != EmergencyState.CRITICAL_EMERGENCY && oldState == EmergencyState.CRITICAL_EMERGENCY) {
            // Reset approvals when leaving critical emergency
            recoveryApprovalsCount = 0;
            emit EmergencyRecoveryCompleted(msg.sender, uint64(block.timestamp));
        }

        emit EmergencyStateChanged(newState);
    }

    // External interface that other functions can call with this
    function setEmergencyState(uint8 _stateValue) external onlyRole(Constants.EMERGENCY_ROLE) {
        _setEmergencyState(_stateValue);
    }

    
    /**
     * @dev Declare different levels of emergency based on severity
     * @param _stateEnum The emergency state to set
     */
    function declareEmergency(EmergencyState _stateEnum) external onlyRole(Constants.EMERGENCY_ROLE) {
        _setEmergencyState(uint8(_stateEnum));
    }

    /**
     * @dev Convenience function to pause presale
     */
    function pausePresale() external onlyRole(Constants.EMERGENCY_ROLE) {
        _setEmergencyState(1); // Set to MINOR_EMERGENCY
    }

    /**
     * @dev Convenience function to resume presale
     */
    function resumePresale() external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Only allow resuming from MINOR_EMERGENCY
        require(emergencyState == EmergencyState.MINOR_EMERGENCY, "Cannot resume from critical state");
        _setEmergencyState(0); // Set to NORMAL
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
    ) external returns (bool success) {
        require(msg.sender == address(this), "CrowdSale: unauthorized");

        // Verify registry and stability fund are properly set
        if (address(registry) == address(0) || !registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
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
    }

    /**
     * @dev Enable or disable auto-compound for rewards
     * @param _enabled Whether to enable auto-compound
     */
    function setAutoCompound(bool _enabled) external {
        autoCompoundEnabled[msg.sender] = _enabled;
        emit AutoCompoundUpdated(msg.sender, _enabled);
    }

    /**
     * @dev In case of critical emergency, allows users to withdraw their USDC
     */
    function emergencyWithdraw() external nonReentrant {
        require(emergencyState == EmergencyState.CRITICAL_EMERGENCY, "CrowdSale: not in critical emergency");
        require(!emergencyWithdrawalsProcessed[msg.sender], "CrowdSale: already processed");

        // Calculate refundable amount
        Purchase storage userPurchase = purchases[msg.sender];
        uint96 refundAmount = userPurchase.usdAmount;

        if (refundAmount > 0) {
            // Mark as processed
            emergencyWithdrawalsProcessed[msg.sender] = true;

            // Return funds
            require(paymentToken.transfer(msg.sender, refundAmount), "CrowdSale: transfer failed");

            emit EmergencyWithdrawalProcessed(msg.sender, refundAmount);
        }
    }

    /**
     * @dev System for multi-signature approval of recovery actions
     */
    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        require(emergencyState == EmergencyState.CRITICAL_EMERGENCY, "CrowdSale: not in critical emergency");
        require(!recoveryApprovals[msg.sender], "CrowdSale: already approved");

        recoveryApprovals[msg.sender] = true;
        recoveryApprovalsCount++;

        if (recoveryApprovalsCount >= requiredRecoveryApprovals) {
            // Return to normal state when enough approvals
            _setEmergencyState(0); // Set to NORMAL
        }
    }

    /**
     * @dev Gets next vesting milestone for a user
     * @param _user Address to check
     * @return timestamp Time of next vesting event
     * @return amount Amount that will vest
     */
    function getNextVestingMilestone(address _user) public view returns (
        uint64 timestamp,
        uint96 amount
    ) {
        if (!tgeCompleted) return (0, 0);

        Purchase storage userPurchase = purchases[_user];
        if (userPurchase.tokens == 0) return (0, 0);

        // Calculate next vesting event
        uint64 elapsedMonths = uint64((block.timestamp - presaleEnd) / 30 days);
        uint64 nextMonthTimestamp = presaleEnd + ((elapsedMonths + 1) * 30 days);

        // Calculate tokens from each tier that will vest at next milestone
        uint96 nextAmount = 0;

        for (uint8 tierId = 0; tierId < tiers.length; tierId++) {
            if (tierId >= userPurchase.tierAmounts.length || userPurchase.tierAmounts[tierId] == 0) continue;

            PresaleTier storage tier = tiers[tierId];
            uint96 tierTokens = uint96((userPurchase.tierAmounts[tierId] * (10**18)) / (tier.price));

            // Skip TGE portion
            uint96 tgeAmount = uint96((tierTokens * tier.vestingTGE) / 100);
            uint96 vestingAmount = tierTokens - tgeAmount;

            // Calculate next month's vesting amount
            if (elapsedMonths < tier.vestingMonths) {
                uint96 monthlyVesting = vestingAmount / tier.vestingMonths;
                nextAmount = nextAmount + monthlyVesting;
            }
        }

        return (nextMonthTimestamp, nextAmount);
    }

    /**
     * @dev Batch distribute tokens to multiple users
     * @param _users Array of user addresses
     */
    function batchDistributeTokens(address[] calldata _users) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(tgeCompleted, "TGE not completed yet");

        for (uint8 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint96 claimable = claimableTokens(user);

            if (claimable > 0) {
                // Update user's token balance
                purchases[user].tokens = purchases[user].tokens - claimable;

                // Record this claim event
                claimHistory[user].push(ClaimEvent({
                    amount: uint128(claimable),
                    timestamp: uint64(block.timestamp)
                }));

                // Transfer tokens to user
                require(token.transfer(user, claimable), "Token transfer failed");

                emit TokensWithdrawn(user, claimable);
            }
        }
    }

    /**
     * @dev Get claim history for a user
     * @param _user User address
     * @return Array of claim events
     */
    function getClaimHistory(address _user) external view returns (ClaimEvent[] memory) {
        return claimHistory[_user];
    }

    /**
     * @dev Handle emergency pause notification from the StabilityFund
     */
    function handleEmergencyPause() external onlyFromRegistry(Constants.STABILITY_FUND_NAME) {
        if (emergencyState == EmergencyState.NORMAL) {
            _setEmergencyState(1); // Set to MINOR_EMERGENCY
        }
    }

    /**
     * @dev Emergency update limits for governance
     * @param _minTimeBetweenPurchases New minimum time between purchases
     * @param _maxPurchaseAmount New maximum purchase amount
     */
    function emergencyUpdateLimits(
        uint32 _minTimeBetweenPurchases,
        uint96 _maxPurchaseAmount
    ) external onlyFromRegistry(Constants.GOVERNANCE_NAME) {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }
}