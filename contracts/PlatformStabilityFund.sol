// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import {IStabilityFund} from "./Interfaces/IStabilityFund.sol";

/**
 * @title PlatformStabilityFund
 * @dev Contract that protects the platform from platform token price volatility
 *      during the donation-to-funding conversion process
 */
contract PlatformStabilityFund is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
IStabilityFund,
UUPSUpgradeable
{

    struct PriceObservation {
        uint40 timestamp;
        uint96 price;
    }

    ERC20Upgradeable internal token;

    // Stable coin used for funding payouts (e.g., USDC)
    ERC20Upgradeable public stableCoin;

    // Fund parameters
    uint96 public reserveRatio;                // Target reserve ratio (10000 = 100%)
    uint96 public minReserveRatio;             // Minimum reserve ratio to maintain solvency
    uint96 public baselinePrice;               // Baseline price in stable coin units (scaled by 1e18)
    uint16 public baseFeePercent;               // Base platform fee percentage (100 = 1%)
    uint16 public maxFeePercent;                // Maximum platform fee percentage (100 = 1%)
    uint16 public minFeePercent;                // Minimum platform fee percentage (100 = 1%)
    uint16 public feeAdjustmentFactor;          // How quickly fees adjust with price changes
    uint16 public currentFeePercent;            // Current effective fee (dynamically adjusted)
    uint16 public priceDropThreshold;           // When fee adjustment begins (500 = 5% below baseline)
    uint16 public maxPriceDropPercent;          // When max fee reduction applies (3000 = 30% below baseline)

    uint32 public platformFeePercent;
    uint32 public lowValueFeePercent;
    uint32 public valueThreshold;

    // Price oracle data
    uint96 public tokenPrice;                  // Current price in stable coin units (scaled by 1e18)
    uint40 public lastPriceUpdateTime;         // Timestamp of last price update
    address public priceOracle;                 // Address authorized to update price

    // Fund state
    uint96 public totalReserves;               // Total stable coin reserves
    uint96 public totalConversions;            // Total conversion transactions processed
    uint96 public totalStabilized;             // Total value stabilized (in stable coins)

    // Platform state
    bool internal paused;
    uint16 public criticalReserveThreshold;     // percentage of min reserve ratio (e.g. 120 = 120% of min)
    address public emergencyAdmin;              // additional address that can trigger circuit breaker

    uint16 public burnToReservePercent;         // Percentage of burned tokens to convert to reserves
    uint16 public platformFeeToReservePercent;  // Percentage of platform fees to add to reserves
    mapping(address => bool) public authorizedBurners; // Addresses authorized to burn tokens

    // Flash Loan protection
    mapping(address => uint40) private lastActionTimestamp;
    mapping(address => uint96) private dailyConversionVolume;
    uint96 public maxDailyUserVolume;
    uint96 public maxSingleConversionAmount;
    uint96 public minTimeBetweenActions;
    bool public flashLoanProtectionEnabled;

    mapping(address => bool) public addressCooldown;
    uint40 public suspiciousCooldownPeriod;

    uint8 public constant MAX_PRICE_OBSERVATIONS = 24; // Store 24 hourly observations
    PriceObservation[MAX_PRICE_OBSERVATIONS] public priceHistory;
    uint8 public currentObservationIndex;
    uint40 public lastObservationTimestamp;
    uint40 public observationInterval;
    uint8 public twapWindowSize; 
    bool public twapEnabled;

    bool public inEmergencyRecovery;
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint8 public requiredRecoveryApprovals;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint40 private _lastCacheUpdate;



    // Events
    event ReservesAdded(address indexed contributor, uint96 amount);
    event ReservesWithdrawn(address indexed recipient, uint96 amount);
    event TokensConverted(address indexed project, uint96 tokenAmount, uint96 stableAmount, uint96 subsidyAmount);
    event PriceUpdated(uint96 oldPrice, uint96 newPrice);
    event FundParametersUpdated(uint96 reserveRatio, uint96 minReserveRatio, uint96 platformFee, uint96 lowValueFee, uint96 threshold);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ValueModeChanged(bool isLowValueMode);
    event BaselinePriceUpdated(uint96 oldPrice, uint96 newPrice);
    event CircuitBreakerTriggered(uint96 currentRatio, uint96 threshold);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event EmergencyPaused(address indexed triggeredBy);
    event EmergencyResumed(address indexed resumedBy);
    event CriticalThresholdUpdated(uint96 oldThreshold, uint96 newThreshold);
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event FeeParametersUpdated(
        uint16 baseFee,
        uint16 maxFee,
        uint16 minFee,
        uint16 adjustmentFactor,
        uint16 dropThreshold,
        uint16 maxDropPercent
    );
    event FlashLoanProtectionConfigured(
        uint96 maxDailyUserVolume,
        uint96 maxSingleConversionAmount,
        uint96 minTimeBetweenActions,
        bool enabled
    );
    event CurrentFeeUpdated(uint16 oldFee, uint16 newFee);
    event TokensBurnedToReserves(uint96 burnedAmount, uint96 reservesAdded);
    event PlatformFeesToReserves(uint96 feeAmount, uint96 reservesAdded);
    event ReplenishmentParametersUpdated(uint16 burnPercent, uint16 feePercent);
    event BurnerAuthorization(address indexed burner, bool authorized);
    event SuspiciousActivity(address indexed user, string reason, uint96 amount);
    event PriceObservationRecorded(uint40 timestamp, uint96 price, uint8 index);
    event TWAPConfigUpdated(uint96 windowSize, uint96 interval, bool enabled);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint40 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint40 timestamp);
    event AddressPlacedInCooldown(address indexed suspiciousAddress, uint96 endTime);
    event AddressRemovedFromCooldown(address indexed cooldownAddress);
    event FunctionCallFailed(bytes4 indexed selector);
    event EtherReceived(address indexed sender, uint256 amount);
    event ExternalCallFailed(string method, address target);
    
    // Error declarations for PlatformStabilityFund
    error ZeroTokenAddress();
    error ZeroStableCoinAddress();
    error ZeroOracleAddress();
    error ZeroInitialPrice();
    error InvalidReserveRatios();
    error FeeParamsInvalid();
    error ZeroThreshold();
    error ZeroAmount();
    error ZeroAddress();
    error ZeroBaselinePrice();
    error TransferFailed();
    error ZeroPriceChange();
    error InsufficientReserves();
    error ExceedsAvailableReserves();
    error ZeroProjectAddress();
    error BelowMinReturn();
    error ThresholdMustBeGreaterThan100();
    error ThresholdTooHigh();
    error AlreadyPaused();
    error NotPaused();
    error ReservesStillCritical();
    error InvalidFeeRange();
    error InvalidDropThresholds();
    error ZeroAdjustmentFactor();
    error AddressInCooldown(address suspiciousAddress);
    error ActionTooSoon();
    error AmountExceedsMaxConversion();
    error DailyVolumeLimitExceeded();
    error PriceDeviatesFromTWAP();
    error PriceChangeTooLarge();
    error InvalidWindowSize();
    error IntervalCannotBeZero();
    error TokenAddressUnavailable();
    error BurnPercentTooHigh();
    error FeePercentTooHigh();
    error NotInRecoveryMode();
    error EmergencyAlreadyApproved();

    modifier flashLoanGuard(uint96 _amount) {
        if (flashLoanProtectionEnabled) {
            // Check if this is the first action today
            if (addressCooldown[msg.sender]) revert AddressInCooldown(msg.sender);
            uint40 dayStart = uint40(block.timestamp - (block.timestamp % 1 days));
            if (lastActionTimestamp[msg.sender] < dayStart) {
                dailyConversionVolume[msg.sender] = 0;
            }

            // Check for minimum time between actions
            if (block.timestamp < lastActionTimestamp[msg.sender] + minTimeBetweenActions) revert ActionTooSoon();

            // Check for maximum single amount
            if (_amount > maxSingleConversionAmount) revert AmountExceedsMaxConversion();

            // Check for daily volume limit
            if (dailyConversionVolume[msg.sender] + _amount > maxDailyUserVolume) revert DailyVolumeLimitExceeded();


            // Update tracking variables
            lastActionTimestamp[msg.sender] = uint40(block.timestamp);
            dailyConversionVolume[msg.sender] += _amount;
        }
        _;
    }

    /**
     * @dev Constructor
     */
    //constructor(){
    //    _disableInitializers();
    //}

    /**
     * @dev Initializes the contract replacing the constructor
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
    function initialize(
        address _token,
        address _stableCoin,
        address _priceOracle,
        uint96 _initialPrice,
        uint96 _reserveRatio,
        uint96 _minReserveRatio,
        uint16 _platformFeePercent,
        uint16 _lowValueFeePercent,
        uint16 _valueThreshold
    ) initializer public {
        __AccessControl_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        

        if (_token == address(0)) revert ZeroTokenAddress();
        if (_stableCoin == address(0)) revert ZeroStableCoinAddress();
        if (_priceOracle == address(0)) revert ZeroOracleAddress();
        if (_initialPrice == 0) revert ZeroInitialPrice();
        if (_reserveRatio <= _minReserveRatio) revert InvalidReserveRatios();
        if (_platformFeePercent < _lowValueFeePercent) revert FeeParamsInvalid();
        if (_valueThreshold == 0) revert ZeroThreshold();

        token = ERC20Upgradeable(_token);
        stableCoin = ERC20Upgradeable(_stableCoin);
        priceOracle = _priceOracle;
        tokenPrice = _initialPrice;
        baselinePrice = _initialPrice;
        lastPriceUpdateTime = uint40(block.timestamp);
        reserveRatio = _reserveRatio;
        minReserveRatio = _minReserveRatio;
        baseFeePercent = _platformFeePercent;       // Use the original platform fee as base
        maxFeePercent = _platformFeePercent;        // Maximum fee is the base fee
        minFeePercent = _lowValueFeePercent;        // Minimum fee is the low value fee
        currentFeePercent = _platformFeePercent;    // Start with base fee
        priceDropThreshold = _valueThreshold;       // When fee adjustment begins
        maxPriceDropPercent = 3000;                 // 30% price drop applies max fee reduction
        feeAdjustmentFactor = 100;                  // Linear adjustment by default
        criticalReserveThreshold = 120;             // Default: 120% of minimum reserve ratio
        emergencyAdmin = msg.sender;
        burnToReservePercent = 1000;                // 10% by default
        platformFeeToReservePercent = 2000;         // 20% by default
        authorizedBurners[msg.sender] = true;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ORACLE_ROLE, _priceOracle);
        _grantRole(Constants.EMERGENCY_ROLE, emergencyAdmin);
        _grantRole(Constants.BURNER_ROLE, msg.sender);
        maxDailyUserVolume = 1_000_000 * 10**18;      // 1M tokens per day per user
        maxSingleConversionAmount = 100_000 * 10**18;// 100K tokens per conversion
        minTimeBetweenActions = 15 minutes;         // 15 minutes between actions
        flashLoanProtectionEnabled = true;
        suspiciousCooldownPeriod = 24 hours;
        observationInterval = 1 hours;
        twapWindowSize=12; // Use 12 hours for TWAP by default
        twapEnabled=true;
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
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE){
        _setRegistry(_registry, Constants.STABILITY_FUND_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Updates the baseline price (governance function)
     * @param _newBaselinePrice New baseline price in stable coin units (scaled by 1e18)
     */
    function updateBaselinePrice(uint96 _newBaselinePrice) external onlyRole(Constants.ADMIN_ROLE) {
        if (_newBaselinePrice == 0) revert ZeroBaselinePrice();

        emit BaselinePriceUpdated(baselinePrice, _newBaselinePrice);

        baselinePrice = _newBaselinePrice;

        // Re-check low value mode status with new baseline
        updateValueMode();
    }

    /**
    * @dev Updates the current fee based on token price relative to baseline
    * @return uint16 The newly calculated fee percentage
    */
    function updateCurrentFee() public onlyRole(Constants.ADMIN_ROLE) returns (uint16) {
        uint96 valueDropPercent = 0;
        uint96 verifiedPrice = getVerifiedPrice();

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
            uint96 adjustmentRange = maxPriceDropPercent - priceDropThreshold;
            uint96 adjustmentPosition = valueDropPercent - priceDropThreshold;
            uint96 adjustmentPercent = (adjustmentPosition * 100) / adjustmentRange;

            // Apply adjustment factor to make the curve more or less aggressive
            adjustmentPercent = (adjustmentPercent * feeAdjustmentFactor) / 100;
            if (adjustmentPercent > 100) {
                adjustmentPercent = 100;
            }

            // Calculate fee reduction amount
            uint96 feeRange = baseFeePercent - minFeePercent;
            uint96 feeReduction = (feeRange * adjustmentPercent) / 100;

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
    function addReserves(uint96 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        // Transfer stable coins to contract
        if (!stableCoin.transferFrom(msg.sender, address(this), _amount)) revert TransferFailed();
        
        totalReserves += _amount;

        emit ReservesAdded(msg.sender, _amount);
    }

    /**
     * @dev Withdraws stable coins from reserves (only owner)
     * @param _amount Amount of stable coins to withdraw
     */
    function withdrawReserves(uint96 _amount) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        uint96 verifiedPrice = getVerifiedPrice();

        // Calculate maximum withdrawable amount based on min reserve ratio
        uint96 totalTokenValue = uint96((token.totalSupply() * verifiedPrice) / 1e18);
        uint96 minReserveRequired = (totalTokenValue * minReserveRatio) / 10000;

        uint96 excessReserves = 0;
        if (totalReserves > minReserveRequired) {
            excessReserves = totalReserves - minReserveRequired;
        }

        if (_amount > excessReserves) revert ExceedsAvailableReserves();
        
        totalReserves -= _amount;

        // Transfer stable coins from contract
        if (!stableCoin.transfer(msg.sender, _amount)) revert TransferFailed();

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
        uint96 _tokenAmount,
        uint96 _minReturn
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant whenContractNotPaused flashLoanGuard(_tokenAmount) returns (uint96 stableAmount) {
        if (_project == address(0)) revert ZeroProjectAddress();
        if (_tokenAmount == 0) revert ZeroAmount();
        
        uint96 oldReserves = totalReserves;
        uint96 oldStableBalance = uint96(stableCoin.balanceOf(_project));

        uint96 verifiedPrice = getVerifiedPrice();

        // Calculate expected value at baseline price
        uint96 baselineValue = (_tokenAmount * baselinePrice) / 1e18;

        // Calculate current value
        uint96 currentValue = (_tokenAmount * verifiedPrice) / 1e18;

        // Apply platform fee based on value mode
        uint96 feePercent = updateCurrentFee();
        uint96 fee = (currentValue * feePercent) / 10000;
        uint96 valueAfterFee = currentValue - fee;

        // Calculate subsidy (if any)
        uint96 subsidy = 0;
        if (valueAfterFee < baselineValue) {
            subsidy = baselineValue - valueAfterFee;

            // Cap subsidy by available reserves
            if (subsidy > totalReserves) {
                subsidy = totalReserves;
            }
        }

        // Calculate final amount to send to project
        stableAmount = valueAfterFee + subsidy;
        if (stableAmount < _minReturn) revert BelowMinReturn();

        // Update state
        if (subsidy > 0) {
            totalReserves -= subsidy;
            totalStabilized += subsidy;
        }
        totalConversions += 1;

        // Transfer ERC20 tokens from sender to contract
        if (!token.transferFrom(msg.sender, address(this), _tokenAmount)) revert TransferFailed();
        
        // Transfer stable coins to project
        if (stableAmount > 0) {
            if (!stableCoin.transfer(_project, stableAmount)) revert TransferFailed();
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
     * @return uint96 Current reserve ratio (10000 = 100%)
     */
    function getReserveRatioHealth() public view returns (uint96) {
        uint96 verifiedPrice = getVerifiedPrice();
        uint96 totalTokenValue = uint96((token.totalSupply() * verifiedPrice) / 1e18);

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
    function simulateConversion(uint96 _tokenAmount) external view returns (
        uint96 expectedValue,
        uint96 subsidyAmount,
        uint96 finalAmount,
        uint96 feeAmount
    ) {
        uint96 verifiedPrice = getVerifiedPrice();
        // Calculate expected value at current price
        expectedValue = (_tokenAmount * verifiedPrice) / 1e18;

        // Calculate baseline value
        uint96 baselineValue = (_tokenAmount * baselinePrice) / 1e18;

        // Apply platform fee based on value mode
        uint96 feePercent = currentFeePercent;
        feeAmount = (expectedValue * feePercent) / 10000;
        uint96 valueAfterFee = expectedValue - feeAmount;

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
        uint96 _reserveRatio,
        uint96 _minReserveRatio,
        uint32 _platformFeePercent,
        uint32 _lowValueFeePercent,
        uint32 _valueThreshold
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_reserveRatio <= _minReserveRatio) revert InvalidReserveRatios();
        if (_platformFeePercent < _lowValueFeePercent) revert FeeParamsInvalid();
        if (_valueThreshold == 0) revert ZeroThreshold();
        
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
    function updatePriceOracle(address _newOracle) external onlyRole(Constants.ADMIN_ROLE) {
        if (_newOracle == address(0)) revert ZeroOracleAddress();
        
        emit PriceOracleUpdated(priceOracle, _newOracle);

        priceOracle = _newOracle;
    }

    /**
     * @dev Swap platform tokens for stable coins
     * @param _tokenAmount Amount of platform tokens to swap
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins received
     */
    function swapTokensForStable(uint96 _tokenAmount, uint96 _minReturn) external nonReentrant flashLoanGuard(_tokenAmount) returns (uint96 stableAmount) {
        if (_tokenAmount == 0) revert ZeroAmount();

        uint96 verifiedPrice = getVerifiedPrice();

        // Calculate the value of platform tokens at current price
        stableAmount = (_tokenAmount * verifiedPrice) / 1e18;

        // Check minimum return
        if (stableAmount < _minReturn) revert BelowMinReturn();
        
        // Check if we have enough reserves
        if (stableAmount > totalReserves) revert InsufficientReserves();
        
        // Update state
        totalReserves -= stableAmount;

        // Transfer platform tokens from sender to contract
        if (!token.transferFrom(msg.sender, address(this), _tokenAmount)) revert TransferFailed();
        
        // Transfer stable coins to sender
        if (!stableCoin.transfer(msg.sender, stableAmount)) revert TransferFailed();
        
        checkAndPauseIfCritical();

        return stableAmount;
    }

    /**
    * @dev Checks if reserve ratio is below critical threshold and pauses if needed
    * @return bool True if paused due to critical reserve ratio
    */
    function checkAndPauseIfCritical() public returns (bool) {
        uint96 reserveRatioHealth = getReserveRatioHealth();
        uint96 criticalThreshold = (minReserveRatio * criticalReserveThreshold) / 100;

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
    function emergencyPause() external onlyRole(Constants.EMERGENCY_ROLE){
        if (msg.sender != owner() && msg.sender != emergencyAdmin) revert NotAuthorized();
        if (paused) revert AlreadyPaused();
        
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
    * @dev Resumes the fund from pause state
    */
    function resumeFromPause() external onlyRole(Constants.ADMIN_ROLE) {
        if (!paused) revert NotPaused();

        // Ensure reserves are above critical threshold before resuming
        uint96 reserveRatioHealth = getReserveRatioHealth();
        uint96 criticalThreshold = (minReserveRatio * criticalReserveThreshold) / 100;
        if (reserveRatioHealth < criticalThreshold) revert ReservesStillCritical();
        
        paused = false;
        emit EmergencyResumed(msg.sender);
    }

    function _isContractPaused() internal override view returns (bool) {
        return paused;
    }
    
    /**
    * @dev Sets the critical reserve threshold percentage
    * @param _threshold New threshold as percentage of min reserve ratio
    */
    function setCriticalReserveThreshold(uint16 _threshold) external onlyRole(Constants.ADMIN_ROLE){
        if (_threshold <= 100) revert ThresholdMustBeGreaterThan100();
        if (_threshold > 200) revert ThresholdTooHigh();

        emit CriticalThresholdUpdated(criticalReserveThreshold, _threshold);
        criticalReserveThreshold = _threshold;

        // Check if we need to pause based on new threshold
        checkAndPauseIfCritical();
    }

    /**
    * @dev Updates the emergency admin address
    * @param _newAdmin New emergency admin address
    */
    function setEmergencyAdmin(address _newAdmin) external onlyRole(Constants.ADMIN_ROLE) {
        if (_newAdmin == address(0)) revert ZeroAddress();
        
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
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (!(_maxFee >= _baseFee && _baseFee >= _minFee)) revert InvalidFeeRange();
        if (_maxDropPercent <= _dropThreshold) revert InvalidDropThresholds();
        if (_adjustmentFactor == 0) revert ZeroAdjustmentFactor();
        
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
    function processBurnedTokens(uint96 _burnedAmount) external onlyRole(Constants.BURNER_ROLE){
        if (_burnedAmount == 0) revert ZeroAmount();

        // If the registry is set, verify the caller is either a registered burner or the token contract
        if (address(registry) != address(0)) {
            if (registry.isContractActive(Constants.TOKEN_NAME)) {
                address tokenAddress = registry.getContractAddress(Constants.TOKEN_NAME);
                if (msg.sender != tokenAddress && !hasRole(Constants.BURNER_ROLE, msg.sender)) revert NotAuthorized();
            }
        } else {
            if(!hasRole(Constants.BURNER_ROLE, msg.sender)) revert NotAuthorized();
        }

        uint96 verifiedPrice = getVerifiedPrice();
        // Calculate value of burned tokens
        uint96 burnValue = (_burnedAmount * verifiedPrice) / 1e18;

        // Calculate portion to add to reserves
        uint96 reservesToAdd = (burnValue * burnToReservePercent) / 10000;

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
    function processPlatformFees(uint96 _feeAmount) external onlyRole(Constants.ADMIN_ROLE) {
        if (_feeAmount == 0) revert ZeroAmount();

        // Calculate portion to add to reserves
        uint96 reservesToAdd = (_feeAmount * platformFeeToReservePercent) / 10000;

        if (reservesToAdd > 0) {
            if (!stableCoin.transferFrom(msg.sender, address(this), reservesToAdd)) revert TransferFailed();
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
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if(_burnPercent > 5000) revert BurnPercentTooHigh();
        if(_feePercent > 10000) revert FeePercentTooHigh();

        burnToReservePercent = _burnPercent;
        platformFeeToReservePercent = _feePercent;

        emit ReplenishmentParametersUpdated(_burnPercent, _feePercent);
    }

    /**
    * @dev Authorize or deauthorize a token burner
    * @param _burner Address of the burner
    * @param _authorized Whether the address is authorized
    */
    function setAuthBurner(address _burner, bool _authorized) external onlyRole(Constants.ADMIN_ROLE) {
        if (_burner == address(0)) revert ZeroAddress();
        
        if (_authorized) {
            grantRole(Constants.BURNER_ROLE, _burner);
        } else {
            revokeRole(Constants.BURNER_ROLE, _burner);
        }

        emit BurnerAuthorization(_burner, _authorized);
    }

    function _checkReserveRatioInvariant() internal view {
        if (!paused) {
            uint96 verifiedPrice = getVerifiedPrice();
            uint96 totalTokenValue = uint96((token.totalSupply() * verifiedPrice) / 1e18);
            uint96 minRequired = (totalTokenValue * minReserveRatio) / 10000;
            assert(totalReserves >= minRequired);
        }
    }

    function configureFlashLoanProtection(
        uint96 _maxDailyUserVolume,
        uint96 _maxSingleConversionAmount,
        uint96 _minTimeBetweenActions,
        bool _enabled
    ) external onlyRole(Constants.ADMIN_ROLE) {
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

    function detectSuspiciousActivity(address _user, uint96 _amount) internal {
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

    function placeSuspiciousAddressInCooldown(address _suspiciousAddress) external onlyRole(Constants.EMERGENCY_ROLE) {
        addressCooldown[_suspiciousAddress] = true;
        emit AddressPlacedInCooldown(_suspiciousAddress, uint96(block.timestamp + suspiciousCooldownPeriod));
    }

    function removeSuspiciousAddressCooldown(address _address) external onlyRole(Constants.ADMIN_ROLE) {
        addressCooldown[_address] = false;
        emit AddressRemovedFromCooldown(_address);
    }

    function _postActionCheck(
        address _user,
        uint96 _tokenAmount,
        uint96 _stableAmount
    ) internal {
        uint96 verifiedPrice = getVerifiedPrice();
        // Check for abnormal price impact
        uint96 expectedValue = (_tokenAmount * verifiedPrice) / 1e18;
        uint96 priceImpact = 0;

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
            uint96 verifiedPrice = getVerifiedPrice();
            // Update the current observation
            priceHistory[currentObservationIndex] = PriceObservation({
                timestamp: uint40(block.timestamp),
                price: verifiedPrice
            });

            emit PriceObservationRecorded(uint40(block.timestamp), verifiedPrice, currentObservationIndex);

            // Update tracking variables
            lastObservationTimestamp = uint40(block.timestamp);

            // Move to next slot in circular buffer
            currentObservationIndex = (currentObservationIndex + 1) % MAX_PRICE_OBSERVATIONS;
        }
    }

    function updatePrice(uint96 _newPrice) external onlyRole(Constants.ORACLE_ROLE) {
        if (_newPrice == 0) revert ZeroAmount();

        uint96 verifiedPrice = getVerifiedPrice();

        // Store the old price for the event
        uint96 oldPrice = verifiedPrice;

        // Calculate the maximum allowed price change (e.g. 10%)
        uint96 maxPriceChange = verifiedPrice * 1000 / 10000; // 10%

        // If TWAP is enabled, check against the time-weighted average
        if (twapEnabled) {
            uint96 twapPrice = calculateTWAP();

            // If we have enough observations and the new price deviates significantly from TWAP
            if (twapPrice > 0) {
                uint96 twapDeviation;

                if (_newPrice > twapPrice) {
                    twapDeviation = ((_newPrice - twapPrice) * 10000) / twapPrice;
                } else {
                    twapDeviation = ((twapPrice - _newPrice) * 10000) / twapPrice;
                }

                // If the deviation exceeds a threshold (e.g. 20%), reject the update
                if (twapDeviation > 2000) revert PriceDeviatesFromTWAP();
            }
        }

        // Check for sudden large price changes
        if (verifiedPrice > 0) {
            uint96 priceChange;

            if (_newPrice > verifiedPrice) {
                priceChange = _newPrice - verifiedPrice;
            } else {
                priceChange = verifiedPrice - _newPrice;
            }

            // If the change is too large, reject the update
            if (priceChange > maxPriceChange) revert PriceChangeTooLarge();
        }

        // Update the price
        verifiedPrice = _newPrice;
        lastPriceUpdateTime = uint40(block.timestamp);

        // Record this observation
        recordPriceObservation();

        // Check if we should enter or exit low value mode
        updateValueMode();

        emit PriceUpdated(oldPrice, _newPrice);
    }

    // Calculate time-weighted average price
    function calculateTWAP() public view returns (uint96) {
        uint96 validObservations = 0;
        uint96 weightedPriceSum = 0;
        uint96 timeSum = 0;
        uint40 oldestAllowedTimestamp = uint40(block.timestamp - (twapWindowSize * observationInterval));

        // Start from newest and work backward for 'windowSize' observations
        uint8 startIndex = (currentObservationIndex == 0) ? MAX_PRICE_OBSERVATIONS - 1 : currentObservationIndex - 1;

        for (uint8 i = 0; i < MAX_PRICE_OBSERVATIONS && validObservations < twapWindowSize; i++) {
            uint8 index = (startIndex - i + MAX_PRICE_OBSERVATIONS) % MAX_PRICE_OBSERVATIONS;
            PriceObservation memory observation = priceHistory[index];

            // Skip if this slot has no observation or if it's too old
            if (observation.timestamp == 0 || observation.timestamp < oldestAllowedTimestamp) {
                continue;
            }

            uint40 timeWeight;
            if (validObservations == 0) {
                timeWeight = uint40(block.timestamp - observation.timestamp);
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
        uint8 _windowSize,
        uint40 _interval,
        bool _enabled
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_windowSize == 0 || _windowSize > MAX_PRICE_OBSERVATIONS) revert InvalidWindowSize();
        if (_interval == 0) revert IntervalCannotBeZero();

        twapWindowSize = _windowSize;
        observationInterval = _interval;
        twapEnabled = _enabled;

        emit TWAPConfigUpdated(_windowSize, _interval, _enabled);
    }

    function getVerifiedPrice() public view returns (uint96) {
        // If TWAP is enabled and we have enough observations, use TWAP
        if (twapEnabled) {
            uint96 twapPrice = calculateTWAP();
            if (twapPrice > 0) {
                // Check if current price deviates too much from TWAP
                uint96 deviation;
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
    function notifyEmergencyToConnectedContracts() external nonReentrant onlyRole(Constants.EMERGENCY_ROLE) {
        if (address(registry) == address(0)) revert RegistryNotSet();
        
        // Try to notify the marketplace to pause
        try registry.isContractActive(Constants.MARKETPLACE_NAME) returns (bool isActive) {
            if (isActive) {
                address marketplace = registry.getContractAddress(Constants.MARKETPLACE_NAME);
                (bool success, ) = marketplace.call(
                    abi.encodeWithSignature("pauseMarketplace()")
                );
                // Log but don't revert if call fails
                if (!success) {
                    emit ExternalCallFailed("pauseMarketplace", marketplace);
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
                    emit ExternalCallFailed("pausePresale", crowdsale);
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
                    emit ExternalCallFailed("pauseStaking", staking);
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
                    emit ExternalCallFailed("pauseRewards", rewards);
                }
            }
        } catch {
            emit EmergencyNotificationFailed(Constants.PLATFORM_REWARD_NAME);
        }

        // Trigger the emergency pause in this contract as well
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    // Add initialization
    function initializeEmergencyRecovery(uint8 _requiredApprovals) external onlyRole(Constants.ADMIN_ROLE) {
        requiredRecoveryApprovals = _requiredApprovals;
    }

    // Add recovery function
    function initiateEmergencyRecovery() external onlyRole(Constants.EMERGENCY_ROLE) {
        if (!paused) revert NotPaused();
        inEmergencyRecovery = true;
        emit EmergencyRecoveryInitiated(msg.sender, uint40(block.timestamp));
    }

    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        if(!inEmergencyRecovery) revert NotInRecoveryMode();
        if(emergencyRecoveryApprovals[msg.sender]) revert EmergencyAlreadyApproved();

        emergencyRecoveryApprovals[msg.sender] = true;

        if (_countRecoveryApprovals() >= requiredRecoveryApprovals) {
            _executeRecovery();
        }
    }

    function _countRecoveryApprovals() internal view returns (uint96) {
        uint96 count = 0;
        // Iterate through all admin role holders
        bytes32 role = Constants.ADMIN_ROLE;
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
        emit EmergencyRecoveryCompleted(msg.sender, uint40(block.timestamp));
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
                    _lastCacheUpdate = uint40(block.timestamp);
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
     * @dev Updates the value mode based on current price compared to baseline
     */
    function updateValueMode() internal {
        uint96 verifiedPrice = getVerifiedPrice();

        // Calculate how far below baseline we are (in percentage points)
        uint96 valueDropPercent = 0;
        if (verifiedPrice < baselinePrice) {
            valueDropPercent = ((baselinePrice - verifiedPrice) * 10000) / baselinePrice;
        }

        // Update current fee based on new value mode
        updateCurrentFee();

        emit ValueModeChanged(valueDropPercent >= priceDropThreshold);
    }

    fallback() external payable {
        // Extract function selector from calldata
        bytes4 selector = msg.data.length >= 4 ? bytes4(msg.data[0:4]) : bytes4(0);

        // Log which function is being attempted
        emit FunctionCallFailed(selector);

        revert("Function not found");
    }
    
    receive() external payable {
        // Either revert with a clear message
        revert("PlatformStabilityFund: ETH transfers not accepted");

        // Accept the ETH (uncomment if needed):
        // emit EtherReceived(msg.sender, msg.value);
    }
}