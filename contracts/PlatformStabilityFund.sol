// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Constants.sol"

/**
 * @title PlatformStabilityFund
 * @dev Contract that protects the platform from platform token price volatility
 *      during the donation-to-funding conversion process
 */
contract PlatformStabilityFund is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    RegistryAwareUpgradeable,
    Constants
{

    struct PriceObservation {
        uint256 timestamp;
        uint256 price;
    }

    // Stable coin used for funding payouts (e.g., USDC)
    IERC20Upgradeable public stableCoin;

    // Fund parameters
    uint256 public reserveRatio;               // Target reserve ratio (10000 = 100%)
    uint256 public minReserveRatio;            // Minimum reserve ratio to maintain solvency
    uint256 public baselinePrice;              // Baseline price in stable coin units (scaled by 1e18)
    uint16 public baseFeePercent;        // Base platform fee percentage (100 = 1%)
    uint16 public maxFeePercent;         // Maximum platform fee percentage (100 = 1%)
    uint16 public minFeePercent;         // Minimum platform fee percentage (100 = 1%)
    uint16 public feeAdjustmentFactor;   // How quickly fees adjust with price changes
    uint16 public currentFeePercent;     // Current effective fee (dynamically adjusted)
    uint16 public priceDropThreshold;    // When fee adjustment begins (500 = 5% below baseline)
    uint16 public maxPriceDropPercent;   // When max fee reduction applies (3000 = 30% below baseline)

    // Price oracle data
    uint256 public tokenPrice;                 // Current price in stable coin units (scaled by 1e18)
    uint256 public lastPriceUpdateTime;        // Timestamp of last price update
    address public priceOracle;                // Address authorized to update price

    // Fund state
    uint256 public totalReserves;              // Total stable coin reserves
    uint256 public totalConversions;           // Total conversion transactions processed
    uint256 public totalStabilized;            // Total value stabilized (in stable coins)

    // Platform state
    bool public paused;
    uint16 public criticalReserveThreshold;    // percentage of min reserve ratio (e.g. 120 = 120% of min)
    address public emergencyAdmin;             // additional address that can trigger circuit breaker

    uint16 public burnToReservePercent;  // Percentage of burned tokens to convert to reserves
    uint16 public platformFeeToReservePercent; // Percentage of platform fees to add to reserves
    mapping(address => bool) public authorizedBurners; // Addresses authorized to burn tokens

    // Flash Loan protection
    mapping(address => uint256) private lastActionTimestamp;
    mapping(address => uint256) private dailyConversionVolume;
    uint256 public maxDailyUserVolume;
    uint256 public maxSingleConversionAmount;
    uint256 public minTimeBetweenActions;
    bool public flashLoanProtectionEnabled;

    mapping(address => bool) public addressCooldown;
    uint256 public suspiciousCooldownPeriod = 24 hours;

    uint8 public constant MAX_PRICE_OBSERVATIONS = 24; // Store 24 hourly observations
    PriceObservation[MAX_PRICE_OBSERVATIONS] public priceHistory;
    uint8 public currentObservationIndex;
    uint256 public lastObservationTimestamp;
    uint256 public observationInterval = 1 hours;
    uint256 public twapWindowSize = 12; // Use 12 hours for TWAP by default
    bool public twapEnabled = true;

    bool public inEmergencyRecovery;
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;

    // Events
    event ReservesAdded(address indexed contributor, uint256 amount);
    event ReservesWithdrawn(address indexed recipient, uint256 amount);
    event TokensConverted(address indexed project, uint256 tokenAmount, uint256 stableAmount, uint256 subsidyAmount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event FundParametersUpdated(uint256 reserveRatio, uint256 minReserveRatio, uint256 platformFee, uint256 lowValueFee, uint256 threshold);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ValueModeChanged(bool isLowValueMode);
    event BaselinePriceUpdated(uint256 oldPrice, uint256 newPrice);
    event CircuitBreakerTriggered(uint256 currentRatio, uint256 threshold);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event EmergencyNotificationFailed(bytes32 indexed contractName);
    event EmergencyPaused(address indexed triggeredBy);
    event EmergencyResumed(address indexed resumedBy);
    event CriticalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event FeeParametersUpdated(
        uint16 baseFee,
        uint16 maxFee,
        uint16 minFee,
        uint16 adjustmentFactor,
        uint16 dropThreshold,
        uint16 maxDropPercent
    );
    event CurrentFeeUpdated(uint16 oldFee, uint16 newFee);
    event TokensBurnedToReserves(uint256 burnedAmount, uint256 reservesAdded);
    event PlatformFeesToReserves(uint256 feeAmount, uint256 reservesAdded);
    event ReplenishmentParametersUpdated(uint16 burnPercent, uint16 feePercent);
    event BurnerAuthorization(address indexed burner, bool authorized);
    event SuspiciousActivity(address indexed user, string reason, uint256 amount);
    event PriceObservationRecorded(uint256 timestamp, uint256 price, uint8 index);
    event TWAPConfigUpdated(uint256 windowSize, uint256 interval, bool enabled);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint256 timestamp);
    
    /**
     * @dev Modifier to restrict certain functions to the price oracle
     */
    modifier onlyPriceOracle() {
        require(hasRole(ORACLE_ROLE, msg.sender), "PlatformStabilityFund: not price oracle role");
        _;
    }
    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "PlatformStabilityFund: caller is not admin role");
        _;
    }

    modifier onlyBurner() {
        require(hasRole(BURNER_ROLE, msg.sender), "PlatformStabilityFund: caller is not burner role");
        _;
    }

    modifier onlyEmergency() {
        require(hasRole(EMERGENCY_ROLE, msg.sender), "PlatformStabilityFund: caller is not emergency role");
        _;
    }
    
    modifier whenNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "PlatformStabilityFund: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                require(!paused, "PlatformStabilityFund: paused");
            }
        } else {
            require(!paused, "PlatformStabilityFund: paused");
        }
        _;
    }

    modifier flashLoanGuard(uint256 _amount) {
        if (flashLoanProtectionEnabled) {
            // Check if this is the first action today
            require(!addressCooldown[msg.sender], "PlatformStabilityFund: address in suspicious activity cooldown");
            uint256 dayStart = block.timestamp.sub(block.timestamp % 1 days);
            if (lastActionTimestamp[msg.sender] < dayStart) {
                dailyConversionVolume[msg.sender] = 0;
            }

            // Check for minimum time between actions
            require(
                block.timestamp >= lastActionTimestamp[msg.sender] + minTimeBetweenActions,
                "PlatformStabilityFund: action too soon after previous action"
            );

            // Check for maximum single amount
            require(
                _amount <= maxSingleConversionAmount,
                "PlatformStabilityFund: amount exceeds maximum single conversion limit"
            );

            // Check for daily volume limit
            require(
                dailyConversionVolume[msg.sender] + _amount <= maxDailyUserVolume,
                "PlatformStabilityFund: daily volume limit exceeded"
            );

            // Update tracking variables
            lastActionTimestamp[msg.sender] = block.timestamp;
            dailyConversionVolume[msg.sender] += _amount;
        }
        _;
    }
    
    /**
     * @dev Constructor sets initial parameters and token addresses
     * @param _token Address of the ERC20 token
     * @param _stableCoin Address of the stable coin for reserves
     * @param _priceOracle Address authorized to update price
     * @param _initialPrice Initial token price in stable coin units (scaled by 1e18)
     * @param _reserveRatio Target reserve ratio (10000 = 100%)
     * @param _minReserveRatio Minimum reserve ratio 
     * @param _platformFeePercent Regular platform fee percentage
     * @param _lowValueFeePercent Reduced fee during low token value
     * @param _valueThreshold Threshold for low value detection
     */
    constructor(){
        _disableInitializers();
    }

    /**
    * @dev Initializes the contract replacing the constructor
     */
    function initialize(  
        address _token,
        address _stableCoin,
        address _priceOracle,
        uint256 _initialPrice,
        uint256 _reserveRatio,
        uint256 _minReserveRatio,
        uint256 _platformFeePercent,
        uint256 _lowValueFeePercent,
        uint256 _valueThreshold
    ) initializer public {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        
        require(_token != address(0), "PlatformStabilityFund: zero token address");
        require(_stableCoin != address(0), "PlatformStabilityFund: zero stable coin address");
        require(_priceOracle != address(0), "PlatformStabilityFund: zero oracle address");
        require(_initialPrice > 0, "PlatformStabilityFund: zero initial price");
        require(_reserveRatio > _minReserveRatio, "PlatformStabilityFund: invalid reserve ratios");
        require(_platformFeePercent >= _lowValueFeePercent, "PlatformStabilityFund: regular fee must be >= low value fee");
        require(_valueThreshold > 0, "PlatformStabilityFund: zero threshold");

        token = IERC20(_token);
        stableCoin = IERC20(_stableCoin);
        priceOracle = _priceOracle;
        tokenPrice = _initialPrice;
        baselinePrice = _initialPrice;
        lastPriceUpdateTime = block.timestamp;
        reserveRatio = _reserveRatio;
        minReserveRatio = _minReserveRatio;
        baseFeePercent = _platformFeePercent;       // Use the original platform fee as base
        maxFeePercent = _platformFeePercent;        // Maximum fee is the base fee
        minFeePercent = _lowValueFeePercent;        // Minimum fee is the low value fee
        currentFeePercent = _platformFeePercent;    // Start with base fee
        priceDropThreshold = _valueThreshold;       // When fee adjustment begins
        maxPriceDropPercent = 3000;                 // 30% price drop applies max fee reduction
        feeAdjustmentFactor = 100;                  // Linear adjustment by default
        criticalReserveThreshold = 120; // Default: 120% of minimum reserve ratio
        emergencyAdmin = msg.sender;
        burnToReservePercent = 1000; // 10% by default
        platformFeeToReservePercent = 2000; // 20% by default
        authorizedBurners[msg.sender] = true;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(Constants.ADMIN_ROLE, msg.sender);
        _setupRole(Constants.ORACLE_ROLE, _priceOracle);
        _setupRole(Constants.EMERGENCY_ROLE, emergencyAdmin);
        _setupRole(Constants.BURNER_ROLE, msg.sender);
        maxDailyUserVolume = 1_000_000 * 10**18; // 1M tokens per day per user
        maxSingleConversionAmount = 100_000 * 10**18; // 100K tokens per conversion
        minTimeBetweenActions = 15 minutes; // 15 minutes between actions
        flashLoanProtectionEnabled = true;
    }

    /**
    * @dev Sets the registry contract address
    * @param _registry Address of the registry contract
    */
    function setRegistry(address _registry) external onlyAdmin {
        _setRegistry(_registry, Constants.PLATFORM_STABILITY_FUND);
        emit RegistrySet(_registry);
    }
    
    /**
     * @dev Updates the token price and checks if low value mode should be activated
     * @param _newPrice New token price in stable coin units (scaled by 1e18)
     */
    function updatePrice(uint256 _newPrice) external onlyPriceOracle {
        require(_newPrice > 0, "PlatformStabilityFund: zero price");

        emit PriceUpdated(tokenPrice, _newPrice);

        tokenPrice = _newPrice;
        lastPriceUpdateTime = block.timestamp;

        // Check if we should enter or exit low value mode
        updateValueMode();
    }

    /**
     * @dev Updates the baseline price (governance function)
     * @param _newBaselinePrice New baseline price in stable coin units (scaled by 1e18)
     */
    function updateBaselinePrice(uint256 _newBaselinePrice) external onlyAdmin {
        require(_newBaselinePrice > 0, "PlatformStabilityFund: zero baseline price");

        emit BaselinePriceUpdated(baselinePrice, _newBaselinePrice);

        baselinePrice = _newBaselinePrice;

        // Re-check low value mode status with new baseline
        updateValueMode();
    }

    /**
    * @dev Updates the current fee based on token price relative to baseline
    * @return uint16 The newly calculated fee percentage
    */
    function updateCurrentFee() public onlyAdmin returns (uint16) {
        uint256 valueDropPercent = 0;
        uint256 verifiedPrice = getVerifiedPrice();
        
        if (verifiedPrice < baselinePrice) {
            // Calculate how far below baseline we are (in percentage points, scaled by 10000)
            valueDropPercent = ((baselinePrice - verifiedPrice) * 10000) / baselinePrice;
        }

        uint16 oldFee = currentFeePercent;

        // If price drop is below threshold, use base fee
        if (valueDropPercent <= priceDropThreshold) {
            currentFeePercent = baseFeePercent;
        }
            // If price drop exceeds max threshold, use min fee
        else if (valueDropPercent >= maxPriceDropPercent) {
            currentFeePercent = minFeePercent;
        }
            // Otherwise calculate gradual fee reduction
        else {
            // Calculate how far between threshold and max drop we are (0-100%)
            uint256 adjustmentRange = maxPriceDropPercent - priceDropThreshold;
            uint256 adjustmentPosition = valueDropPercent - priceDropThreshold;
            uint256 adjustmentPercent = (adjustmentPosition * 100) / adjustmentRange;

            // Apply adjustment factor to make the curve more or less aggressive
            adjustmentPercent = (adjustmentPercent * feeAdjustmentFactor) / 100;
            if (adjustmentPercent > 100) {
                adjustmentPercent = 100;
            }

            // Calculate fee reduction amount
            uint256 feeRange = baseFeePercent - minFeePercent;
            uint256 feeReduction = (feeRange * adjustmentPercent) / 100;

            // Apply the reduction to the base fee
            currentFeePercent = uint16(baseFeePercent - feeReduction);
        }

        if (oldFee != currentFeePercent) {
            emit CurrentFeeUpdated(oldFee, currentFeePercent);
        }

        return currentFeePercent;
    }

    /**
     * @dev Adds stable coins to the stability reserves
     * @param _amount Amount of stable coins to add
     */
    function addReserves(uint256 _amount) external nonReentrant {
        require(_amount > 0, "PlatformStabilityFund: zero amount");

        // Transfer stable coins to contract
        require(stableCoin.transferFrom(msg.sender, address(this), _amount), "PlatformStabilityFund: transfer failed");

        totalReserves += _amount;

        emit ReservesAdded(msg.sender, _amount);
    }

    /**
     * @dev Withdraws stable coins from reserves (only owner)
     * @param _amount Amount of stable coins to withdraw
     */
    function withdrawReserves(uint256 _amount) external onlyAdmin nonReentrant {
        require(_amount > 0, "PlatformStabilityFund: zero amount");
        uint256 verifiedPrice = getVerifiedPrice();
        
        // Calculate maximum withdrawable amount based on min reserve ratio
        uint256 totalTokenValue = (token.totalSupply() * verifiedPrice) / 1e18;
        uint256 minReserveRequired = (totalTokenValue * minReserveRatio) / 10000;

        uint256 excessReserves = 0;
        if (totalReserves > minReserveRequired) {
            excessReserves = totalReserves - minReserveRequired;
        }

        require(_amount <= excessReserves, "PlatformStabilityFund: exceeds available reserves");

        totalReserves -= _amount;

        // Transfer stable coins from contract
        require(stableCoin.transfer(msg.sender, _amount), "PlatformStabilityFund: transfer failed");

        emit ReservesWithdrawn(msg.sender, _amount);
    }

    /**
     * @dev Converts ERC20 tokens to stable coins for project funding with stability protection
     * @param _project Address of the project receiving funds
     * @param _tokenAmount Amount of ERC20 tokens to convert
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins sent to the project
     */
    function convertTokensToFunding(
        address _project,
        uint256 _tokenAmount,
        uint256 _minReturn
    ) external onlyAdmin nonReentrant whenNotPaused flashLoanGuard(_tokenAmount) returns (uint256 stableAmount) {
        require(_project != address(0), "PlatformStabilityFund: zero project address");
        require(_tokenAmount > 0, "PlatformStabilityFund: zero amount");

        uint256 oldReserves = totalReserves;
        uint256 oldStableBalance = stableCoin.balanceOf(_project);

        uint256 verifiedPrice = getVerifiedPrice();
        
        // Calculate expected value at baseline price
        uint256 baselineValue = (_tokenAmount * baselinePrice) / 1e18;

        // Calculate current value
        uint256 currentValue = (_tokenAmount * verifiedPrice) / 1e18;

        // Apply platform fee based on value mode
        uint256 feePercent = updateCurrentFee();
        uint256 fee = (currentValue * feePercent) / 10000;
        uint256 valueAfterFee = currentValue - fee;

        // Calculate subsidy (if any)
        uint256 subsidy = 0;
        if (valueAfterFee < baselineValue) {
            subsidy = baselineValue - valueAfterFee;

            // Cap subsidy by available reserves
            if (subsidy > totalReserves) {
                subsidy = totalReserves;
            }
        }

        // Calculate final amount to send to project
        stableAmount = valueAfterFee + subsidy;
        require(stableAmount >= _minReturn, "PlatformStabilityFund: below min return");

        // Update state
        if (subsidy > 0) {
            totalReserves -= subsidy;
            totalStabilized += subsidy;
        }
        totalConversions += 1;

        // Transfer ERC20 tokens from sender to contract
        require(token.transferFrom(msg.sender, address(this), _tokenAmount), "PlatformStabilityFund: token transfer failed");

        // Transfer stable coins to project
        if (stableAmount > 0) {
            require(stableCoin.transfer(_project, stableAmount), "PlatformStabilityFund: stable transfer failed");
        }

        emit TokensConverted(_project, _tokenAmount, stableAmount, subsidy);

        checkAndPauseIfCritical();

        if (subsidy > 0) {
            assert(totalReserves == oldReserves - subsidy);
        }
        assert(stableCoin.balanceOf(_project) == oldStableBalance + stableAmount);
        
        return stableAmount;
    }

    /**
     * @dev Get the reserve ratio health of the fund
     * @return uint256 Current reserve ratio (10000 = 100%)
     */
    function getReserveRatioHealth() public view returns (uint256) {
        uint256 verifiedPrice = getVerifiedPrice();
        uint256 totalTokenValue = (token.totalSupply() * verifiedPrice) / 1e18;

        if (totalTokenValue == 0) {
            return 10000; // 100% if no tokens
        }

        return (totalReserves * 10000) / totalTokenValue;
    }

    /**
     * @dev Simulates a token conversion without executing it
     * @param _tokenAmount Amount of ERC20 tokens to convert
     * @return expectedValue Expected stable coin value based on current price
     * @return subsidyAmount Expected subsidy amount (if any)
     * @return finalAmount Final amount after subsidy
     * @return feeAmount Platform fee amount
     */
    function simulateConversion(uint256 _tokenAmount) external view returns (
        uint256 expectedValue,
        uint256 subsidyAmount,
        uint256 finalAmount,
        uint256 feeAmount
    ) {
        uint256 verifiedPrice = getVerifiedPrice();
        // Calculate expected value at current price
        expectedValue = (_tokenAmount * verifiedPrice) / 1e18;

        // Calculate baseline value
        uint256 baselineValue = (_tokenAmount * baselinePrice) / 1e18;

        // Apply platform fee based on value mode
        uint256 feePercent = currentFeePercent;
        feeAmount = (expectedValue * feePercent) / 10000;
        uint256 valueAfterFee = expectedValue - feeAmount;

        // Calculate subsidy (if any)
        subsidyAmount = 0;
        if (valueAfterFee < baselineValue) {
            subsidyAmount = baselineValue - valueAfterFee;

            // Cap subsidy by available reserves
            if (subsidyAmount > totalReserves) {
                subsidyAmount = totalReserves;
            }
        }

        // Calculate final amount
        finalAmount = valueAfterFee + subsidyAmount;

        return (expectedValue, subsidyAmount, finalAmount, feeAmount);
    }

    /**
     * @dev Updates fund parameters (only owner)
     * @param _reserveRatio New target reserve ratio
     * @param _minReserveRatio New minimum reserve ratio
     * @param _platformFeePercent New regular platform fee percentage
     * @param _lowValueFeePercent New reduced fee percentage
     * @param _valueThreshold New threshold for low value detection
     */
    function updateFundParameters(
        uint256 _reserveRatio,
        uint256 _minReserveRatio,
        uint256 _platformFeePercent,
        uint256 _lowValueFeePercent,
        uint256 _valueThreshold
    ) external onlyAdmin {
        require(_reserveRatio > _minReserveRatio, "PlatformStabilityFund: invalid reserve ratios");
        require(_platformFeePercent >= _lowValueFeePercent, "PlatformStabilityFund: regular fee must be >= low value fee");
        require(_valueThreshold > 0, "PlatformStabilityFund: zero threshold");

        reserveRatio = _reserveRatio;
        minReserveRatio = _minReserveRatio;
        platformFeePercent = _platformFeePercent;
        lowValueFeePercent = _lowValueFeePercent;
        valueThreshold = _valueThreshold;

        emit FundParametersUpdated(_reserveRatio, _minReserveRatio, _platformFeePercent, _lowValueFeePercent, _valueThreshold);

        // Re-check low value mode status with new parameters
        updateValueMode();
    }

    /**
     * @dev Updates the price oracle address
     * @param _newOracle New price oracle address
     */
    function updatePriceOracle(address _newOracle) external onlyAdmin {
        require(_newOracle != address(0), "PlatformStabilityFund: zero oracle address");

        emit PriceOracleUpdated(priceOracle, _newOracle);

        priceOracle = _newOracle;
    }

    /**
     * @dev Swap platform tokens for stable coins
     * @param _tokenAmount Amount of platform tokens to swap
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins received
     */
    function swapTokensForStable(uint256 _tokenAmount, uint256 _minReturn) external nonReentrant flashLoanGuard(_tokenAmount) returns (uint256 stableAmount) {
        require(_tokenAmount > 0, "PlatformStabilityFund: zero amount");

        uint256 verifiedPrice = getVerifiedPrice();
        
        // Calculate the value of platform tokens at current price
        stableAmount = (_tokenAmount * verifiedPrice) / 1e18;

        // Check minimum return
        require(stableAmount >= _minReturn, "PlatformStabilityFund: below min return");

        // Check if we have enough reserves
        require(stableAmount <= totalReserves, "PlatformStabilityFund: insufficient reserves");

        // Update state
        totalReserves -= stableAmount;

        // Transfer platform tokens from sender to contract
        require(token.transferFrom(msg.sender, address(this), _tokenAmount), "PlatformStabilityFund: token transfer failed");

        // Transfer stable coins to sender
        require(stableCoin.transfer(msg.sender, stableAmount), "PlatformStabilityFund: stable transfer failed");

        checkAndPauseIfCritical();
        
        return stableAmount;
    }

    /**
    * @dev Checks if reserve ratio is below critical threshold and pauses if needed
    * @return bool True if paused due to critical reserve ratio
    */
    function checkAndPauseIfCritical() public returns (bool) {
        uint256 reserveRatioHealth = getReserveRatioHealth();
        uint256 criticalThreshold = (minReserveRatio * criticalReserveThreshold) / 100;

        if (reserveRatioHealth < criticalThreshold) {
            if (!paused) {
                paused = true;
                emit CircuitBreakerTriggered(reserveRatioHealth, criticalThreshold);
                emit EmergencyPaused(msg.sender);
            }
            return true;
        }

        return false;
    }

    /**
    * @dev Manually pauses the fund in case of emergency
    */
    function emergencyPause() external onlyEmergency{
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "PlatformStabilityFund: not authorized");
        require(!paused, "PlatformStabilityFund: already paused");

        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
    * @dev Resumes the fund from pause state
    */
    function resumeFromPause() external onlyAdmin {
        require(paused, "PlatformStabilityFund: not paused");

        // Ensure reserves are above critical threshold before resuming
        uint256 reserveRatioHealth = getReserveRatioHealth();
        uint256 criticalThreshold = (minReserveRatio * criticalReserveThreshold) / 100;
        require(reserveRatioHealth >= criticalThreshold, "PlatformStabilityFund: reserves still critical");

        paused = false;
        emit EmergencyResumed(msg.sender);
    }

    /**
    * @dev Sets the critical reserve threshold percentage
    * @param _threshold New threshold as percentage of min reserve ratio
    */
    function setCriticalReserveThreshold(uint16 _threshold) external onlyAdmin{
        require(_threshold > 100, "PlatformStabilityFund: threshold must be > 100%");
        require(_threshold <= 200, "PlatformStabilityFund: threshold too high");

        emit CriticalThresholdUpdated(criticalReserveThreshold, _threshold);
        criticalReserveThreshold = _threshold;

        // Check if we need to pause based on new threshold
        checkAndPauseIfCritical();
    }

    /**
    * @dev Updates the emergency admin address
    * @param _newAdmin New emergency admin address
    */
    function setEmergencyAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "PlatformStabilityFund: zero admin address");

        emit EmergencyAdminUpdated(emergencyAdmin, _newAdmin);
        emergencyAdmin = _newAdmin;
    }

    /**
 * @dev Updates fee adjustment parameters
 * @param _baseFee Base fee percentage
 * @param _maxFee Maximum fee percentage
 * @param _minFee Minimum fee percentage
 * @param _adjustmentFactor Fee adjustment curve factor
 * @param _dropThreshold Price drop threshold to begin fee adjustment
 * @param _maxDropPercent Price drop percentage for maximum fee reduction
 */
    function updateFeeParameters(
        uint16 _baseFee,
        uint16 _maxFee,
        uint16 _minFee,
        uint16 _adjustmentFactor,
        uint16 _dropThreshold,
        uint16 _maxDropPercent
    ) external onlyAdmin {
        require(_maxFee >= _baseFee && _baseFee >= _minFee, "PlatformStabilityFund: invalid fee range");
        require(_maxDropPercent > _dropThreshold, "PlatformStabilityFund: invalid drop thresholds");
        require(_adjustmentFactor > 0, "PlatformStabilityFund: zero adjustment factor");

        baseFeePercent = _baseFee;
        maxFeePercent = _maxFee;
        minFeePercent = _minFee;
        feeAdjustmentFactor = _adjustmentFactor;
        priceDropThreshold = _dropThreshold;
        maxPriceDropPercent = _maxDropPercent;

        emit FeeParametersUpdated(_baseFee, _maxFee, _minFee, _adjustmentFactor, _dropThreshold, _maxDropPercent);

        // Update current fee with new parameters
        updateCurrentFee();
    }

    /**
    * @dev Process burned tokens and convert a portion to reserves
    * @param _burnedAmount Amount of platform tokens that were burned
    */
    function processBurnedTokens(uint256 _burnedAmount) external onlyBurner{
        require(_burnedAmount > 0, "PlatformStabilityFund: zero burn amount");

        // If the registry is set, verify the caller is either a registered burner or the token contract
        if (address(registry) != address(0)) {
            if (registry.isContractActive(Constants.TOKEN_NAME)) {
                address tokenAddress = registry.getContractAddress(Constants.TOKEN_NAME);
                require(
                    msg.sender == tokenAddress || hasRole(Constants.BURNER_ROLE, msg.sender),
                    "PlatformStabilityFund: not authorized"
                );
            }
        } else {
            require(hasRole(Constants.BURNER_ROLE, msg.sender), "PlatformStabilityFund: not authorized");
        }
        
        uint256 verifiedPrice = getVerifiedPrice();
        // Calculate value of burned tokens
        uint256 burnValue = (_burnedAmount * verifiedPrice) / 1e18;

        // Calculate portion to add to reserves
        uint256 reservesToAdd = (burnValue * burnToReservePercent) / 10000;

        if (reservesToAdd > 0) {
            // Owner is expected to transfer stablecoins to the contract
            totalReserves += reservesToAdd;
            emit TokensBurnedToReserves(_burnedAmount, reservesToAdd);
        }
    }

    /**
    * @dev Process platform fees and add a portion to reserves
    * @param _feeAmount Amount of platform fees collected
    */
    function processPlatformFees(uint256 _feeAmount) external onlyAdmin {
        require(_feeAmount > 0, "PlatformStabilityFund: zero fee amount");

        // Calculate portion to add to reserves
        uint256 reservesToAdd = (_feeAmount * platformFeeToReservePercent) / 10000;

        if (reservesToAdd > 0) {
            // Require the owner to transfer the stablecoins
            require(stableCoin.transferFrom(msg.sender, address(this), reservesToAdd),
                "PlatformStabilityFund: transfer failed");

            totalReserves += reservesToAdd;
            emit PlatformFeesToReserves(_feeAmount, reservesToAdd);
        }
    }

    /**
    * @dev Updates replenishment parameters
    * @param _burnPercent Percentage of burned tokens to convert to reserves
    * @param _feePercent Percentage of platform fees to add to reserves
    */
    function updateReplenishmentParameters(
        uint16 _burnPercent,
        uint16 _feePercent
    ) external onlyAdmin {
        require(_burnPercent <= 5000, "PlatformStabilityFund: burn percent too high");
        require(_feePercent <= 10000, "PlatformStabilityFund: fee percent too high");

        burnToReservePercent = _burnPercent;
        platformFeeToReservePercent = _feePercent;

        emit ReplenishmentParametersUpdated(_burnPercent, _feePercent);
    }

    /**
    * @dev Authorize or deauthorize a token burner
    * @param _burner Address of the burner
    * @param _authorized Whether the address is authorized
    */
    function setAuthBurner(address _burner, bool _authorized) external onlyAdmin {
        require(_burner != address(0), "PlatformStabilityFund: zero burner address");
        
        if (_authorized) {
            grantRole(Constants.BURNER_ROLE, _burner);
        } else {
            revokeRole(Constants.BURNER_ROLE, _burner);
        }
        
        emit BurnerAuthorization(_burner, _authorized);
    }

    function _checkReserveRatioInvariant() internal view {
        if (!paused) {
            uint256 verifiedPrice = getVerifiedPrice();
            uint256 totalTokenValue = (token.totalSupply() * verifiedPrice) / 1e18;
            uint256 minRequired = (totalTokenValue * minReserveRatio) / 10000;
            assert(totalReserves >= minRequired);
        }
    }

    function configureFlashLoanProtection(
        uint256 _maxDailyUserVolume,
        uint256 _maxSingleConversionAmount,
        uint256 _minTimeBetweenActions,
        bool _enabled
    ) external onlyAdmin {
        maxDailyUserVolume = _maxDailyUserVolume;
        maxSingleConversionAmount = _maxSingleConversionAmount;
        minTimeBetweenActions = _minTimeBetweenActions;
        flashLoanProtectionEnabled = _enabled;

        emit FlashLoanProtectionConfigured(
            _maxDailyUserVolume,
            _maxSingleConversionAmount,
            _minTimeBetweenActions,
            _enabled
        );
    }

    function detectSuspiciousActivity(address _user, uint256 _amount) internal {
        // Check for abnormal conversion patterns
        bool isSuspicious = false;
        string memory reason = "";

        // Sudden large volume from an address that hasn't been active
        if (lastActionTimestamp[_user] == 0 && _amount > maxSingleConversionAmount / 2) {
            isSuspicious = true;
            reason = "Large first-time conversion";
        }

        // Multiple conversions approaching limits
        if (dailyConversionVolume[_user] > maxDailyUserVolume * 90 / 100) {
            isSuspicious = true;
            reason = "Approaching daily volume limit";
        }

        if (isSuspicious) {
            emit SuspiciousActivity(_user, reason, _amount);
        }
    }

    function placeSuspiciousAddressInCooldown(address _suspiciousAddress) external onlyEmergency {
        addressCooldown[_suspiciousAddress] = true;
        emit AddressPlacedInCooldown(_suspiciousAddress, block.timestamp + suspiciousCooldownPeriod);
    }

    function removeSuspiciousAddressCooldown(address _address) external onlyAdmin {
        addressCooldown[_address] = false;
        emit AddressRemovedFromCooldown(_address);
    }

    function _postActionCheck(
        address _user,
        uint256 _tokenAmount,
        uint256 _stableAmount
    ) internal {
        uint256 verifiedPrice = getVerifiedPrice();
        // Check for abnormal price impact
        uint256 expectedValue = (_tokenAmount * verifiedPrice) / 1e18;
        uint256 priceImpact = 0;

        if (expectedValue > _stableAmount) {
            priceImpact = ((expectedValue - _stableAmount) * 10000) / expectedValue;
        }

        // If price impact is abnormally high, log suspicious activity
        if (priceImpact > 500) { // 5% threshold
            emit SuspiciousActivity(_user, "High price impact conversion", _tokenAmount);
        }

        // Run detection algorithm
        detectSuspiciousActivity(_user, _tokenAmount);
    }

    function recordPriceObservation() public {
        // Only record if enough time has passed since last observation
        if (block.timestamp >= lastObservationTimestamp + observationInterval) {
            uint256 verifiedPrice = getVerifiedPrice();
            // Update the current observation
            priceHistory[currentObservationIndex] = PriceObservation({
                timestamp: block.timestamp,
                price: verifiedPrice
            });

            emit PriceObservationRecorded(block.timestamp, verifiedPrice, currentObservationIndex);

            // Update tracking variables
            lastObservationTimestamp = block.timestamp;

            // Move to next slot in circular buffer
            currentObservationIndex = (currentObservationIndex + 1) % MAX_PRICE_OBSERVATIONS;
        }
    }

    function updatePrice(uint256 _newPrice) external onlyPriceOracle {
        require(_newPrice > 0, "PlatformStabilityFund: zero price");

        uint256 verifiedPrice = getVerifiedPrice();
        
        // Store the old price for the event
        uint256 oldPrice = verifiedPrice;

        // Calculate the maximum allowed price change (e.g. 10%)
        uint256 maxPriceChange = verifiedPrice * 1000 / 10000; // 10%

        // If TWAP is enabled, check against the time-weighted average
        if (twapEnabled) {
            uint256 twapPrice = calculateTWAP();

            // If we have enough observations and the new price deviates significantly from TWAP
            if (twapPrice > 0) {
                uint256 twapDeviation;

                if (_newPrice > twapPrice) {
                    twapDeviation = ((_newPrice - twapPrice) * 10000) / twapPrice;
                } else {
                    twapDeviation = ((twapPrice - _newPrice) * 10000) / twapPrice;
                }

                // If the deviation exceeds a threshold (e.g. 20%), reject the update
                require(twapDeviation <= 2000, "PlatformStabilityFund: price deviates too much from TWAP");
            }
        }

        // Check for sudden large price changes
        if (verifiedPrice > 0) {
            uint256 priceChange;

            if (_newPrice > verifiedPrice) {
                priceChange = _newPrice - verifiedPrice;
            } else {
                priceChange = verifiedPrice - _newPrice;
            }

            // If the change is too large, reject the update
            require(priceChange <= maxPriceChange, "PlatformStabilityFund: price change too large");
        }

        // Update the price
        verifiedPrice = _newPrice;
        lastPriceUpdateTime = block.timestamp;

        // Record this observation
        recordPriceObservation();

        // Check if we should enter or exit low value mode
        updateValueMode();

        emit PriceUpdated(oldPrice, _newPrice);
    }

    // Calculate time-weighted average price
    function calculateTWAP() public view returns (uint256) {
        uint256 validObservations = 0;
        uint256 weightedPriceSum = 0;
        uint256 timeSum = 0;
        uint256 oldestAllowedTimestamp = block.timestamp - (twapWindowSize * observationInterval);

        // Start from newest and work backward for 'windowSize' observations
        uint8 startIndex = (currentObservationIndex == 0) ? MAX_PRICE_OBSERVATIONS - 1 : currentObservationIndex - 1;

        for (uint8 i = 0; i < MAX_PRICE_OBSERVATIONS && validObservations < twapWindowSize; i++) {
            uint8 index = (startIndex - i + MAX_PRICE_OBSERVATIONS) % MAX_PRICE_OBSERVATIONS;
            PriceObservation memory observation = priceHistory[index];

            // Skip if this slot has no observation or if it's too old
            if (observation.timestamp == 0 || observation.timestamp < oldestAllowedTimestamp) {
                continue;
            }

            uint256 timeWeight;
            if (validObservations == 0) {
                timeWeight = block.timestamp - observation.timestamp;
            } else {
                uint8 prevIndex = (index + 1) % MAX_PRICE_OBSERVATIONS;
                timeWeight = priceHistory[prevIndex].timestamp - observation.timestamp;
            }

            weightedPriceSum += observation.price * timeWeight;
            timeSum += timeWeight;
            validObservations++;
        }

        // Return 0 if not enough observations
        if (timeSum == 0 || validObservations < twapWindowSize / 2) {
            return 0;
        }

        return weightedPriceSum / timeSum;
    }

    // Configure TWAP parameters
    function configureTWAP(
        uint256 _windowSize,
        uint256 _interval,
        bool _enabled
    ) external onlyAdmin {
        require(_windowSize > 0 && _windowSize <= MAX_PRICE_OBSERVATIONS, "PlatformStabilityFund: invalid window size");
        require(_interval > 0, "PlatformStabilityFund: interval cannot be zero");

        twapWindowSize = _windowSize;
        observationInterval = _interval;
        twapEnabled = _enabled;

        emit TWAPConfigUpdated(_windowSize, _interval, _enabled);
    }

    function getVerifiedPrice() public view returns (uint256) {
        // If TWAP is enabled and we have enough observations, use TWAP
        if (twapEnabled) {
            uint256 twapPrice = calculateTWAP();
            if (twapPrice > 0) {
                // Check if current price deviates too much from TWAP
                uint256 deviation;
                if (tokenPrice > twapPrice) {
                    deviation = ((tokenPrice - twapPrice) * 10000) / twapPrice;
                } else {
                    deviation = ((twapPrice - tokenPrice) * 10000) / twapPrice;
                }

                // If deviation is too large, return TWAP instead
                if (deviation > 2000) { // 20% threshold
                    return twapPrice;
                }
            }
        }

        return tokenPrice;
    }

    /**
     * @dev Emergency notification to all connected contracts
     * Called when critical stability issues are detected
     */
    function notifyEmergencyToConnectedContracts() external onlyEmergency {
        require(address(registry) != address(0), "PlatformStabilityFund: registry not set");

        // Try to notify the marketplace to pause
        try registry.isContractActive(Constants.MARKETPLACE_NAME) returns (bool isActive) {
            if (isActive) {
                address marketplace = registry.getContractAddress(Constants.MARKETPLACE_NAME);
                (bool success, ) = marketplace.call(
                    abi.encodeWithSignature("pauseMarketplace()")
                );
                // Log but don't revert if call fails
                if (!success) {
                    emit EmergencyNotificationFailed(Constants.MARKETPLACE_NAME);
                }
            }
        } catch {
            emit EmergencyNotificationFailed(Constants.MARKETPLACE_NAME);
        }

        // Try to notify the crowdsale to pause
        try registry.isContractActive(Constants.CROWDSALE_NAME) returns (bool isActive) {
            if (isActive) {
                address crowdsale = registry.getContractAddress(Constants.CROWDSALE_NAME);
                (bool success, ) = crowdsale.call(
                    abi.encodeWithSignature("pausePresale()")
                );
                if (!success) {
                    emit EmergencyNotificationFailed(Constants.CROWDSALE_NAME);
                }
            }
        } catch {
            emit EmergencyNotificationFailed(Constants.CROWDSALE_NAME);
        }

        // Try to notify staking contract
        try registry.isContractActive(Constants.STAKING_NAME) returns (bool isActive) {
            if (isActive) {
                address staking = registry.getContractAddress(Constants.STAKING_NAME);
                (bool success, ) = staking.call(
                    abi.encodeWithSignature("pauseStaking()")
                );
                if (!success) {
                    emit EmergencyNotificationFailed(Constants.STAKING_NAME);
                }
            }
        } catch {
            emit EmergencyNotificationFailed(Constants.STAKING_NAME);
        }

        // Try to notify platform rewards
        try registry.isContractActive(Constants.PLATFORM_REWARD_NAME) returns (bool isActive) {
            if (isActive) {
                address rewards = registry.getContractAddress(Constants.PLATFORM_REWARD_NAME);
                (bool success, ) = rewards.call(
                    abi.encodeWithSignature("pauseRewards()")
                );
                if (!success) {
                    emit EmergencyNotificationFailed(Constants.PLATFORM_REWARD_NAME);
                }
            }
        } catch {
            emit EmergencyNotificationFailed(Constants.PLATFORM_REWARD_NAME);
        }

        // Trigger the emergency pause in this contract as well
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Get the Token address from the registry
     * @return Address of the Token contract
     */
    function getPlatformTokenFromRegistry() public view returns (address) {
        require(address(registry) != address(0), "PlatformStabilityFund: registry not set");
        require(registry.isContractActive(Constants.TOKEN_NAME), "PlatformStabilityFund: token not active");

        return registry.getContractAddress(Constants.TOKEN_NAME);
    }

    /**
    * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyAdmin {
        require(address(registry) != address(0), "PlatformStabilityFund: registry not set");

        // Update Token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address newToken = registry.getContractAddress(Constants.TOKEN_NAME);
            address oldToken = address(token);

            if (newToken != oldToken) {
                token = IERC20(newToken);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, newToken);
            }
        }
    }

    // Add initialization
    function initializeEmergencyRecovery(uint256 _requiredApprovals) external onlyAdmin {
        requiredRecoveryApprovals = _requiredApprovals;
    }

// Add recovery function
    function initiateEmergencyRecovery() external onlyEmergency {
        require(paused, "StabilityFund: not paused");
        inEmergencyRecovery = true;
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    function approveRecovery() external onlyAdmin {
        require(inEmergencyRecovery, "StabilityFund: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "StabilityFund: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;

        if (_countRecoveryApprovals() >= requiredRecoveryApprovals) {
            _executeRecovery();
        }
    }

    function _countRecoveryApprovals() internal view returns (uint256) {
        uint256 count = 0;
        // Iterate through all admin role holders
        bytes32 role = ADMIN_ROLE;
        for (uint i = 0; i < getRoleMemberCount(role); i++) {
            address admin = getRoleMember(role, i);
            if (emergencyRecoveryApprovals[admin]) {
                count++;
            }
        }
        return count;
    }

    function _executeRecovery() internal {
        inEmergencyRecovery = false;
        paused = false;
        // Reset any emergency state variables
        emit EmergencyRecoveryCompleted(msg.sender, block.timestamp);
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
        address fallbackAddress = _fallbackAddresses[TOKEN_NAME];
        if (fallbackAddress != address(0)) {
            return fallbackAddress;
        }

        // Final fallback: Use hardcoded address (if appropriate) or revert
        revert("Token address unavailable through all fallback mechanisms");
    }

    function getRoleMemberCount(bytes32 role) internal view returns (uint256) {
        return _roles[role].members.length();
    }

    function getRoleMember(bytes32 role, uint256 index) internal view returns (address) {
        return _roles[role].members.at(index);
    }
    
}