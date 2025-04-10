// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PlatformStabilityFund
 * @dev Contract that protects the platform from TEACH token price volatility
 *      during the donation-to-funding conversion process
 */
contract PlatformStabilityFund is Ownable, ReentrancyGuard {
    using Math for uint256;

    // The TeachToken contract
    IERC20 public teachToken;

    // Stable coin used for funding payouts (e.g., USDC)
    IERC20 public stableCoin;

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

    // Events
    event ReservesAdded(address indexed contributor, uint256 amount);
    event ReservesWithdrawn(address indexed recipient, uint256 amount);
    event TokensConverted(address indexed project, uint256 teachAmount, uint256 stableAmount, uint256 subsidyAmount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event FundParametersUpdated(uint256 reserveRatio, uint256 minReserveRatio, uint256 platformFee, uint256 lowValueFee, uint256 threshold);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ValueModeChanged(bool isLowValueMode);
    event BaselinePriceUpdated(uint256 oldPrice, uint256 newPrice);
    event CircuitBreakerTriggered(uint256 currentRatio, uint256 threshold);
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
    
    /**
     * @dev Modifier to restrict certain functions to the price oracle
     */
    modifier onlyPriceOracle() {
        require(msg.sender == priceOracle, "PlatformStabilityFund: not oracle");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PlatformStabilityFund: paused");
        _;
    }

    /**
     * @dev Constructor sets initial parameters and token addresses
     * @param _teachToken Address of the TEACH token
     * @param _stableCoin Address of the stable coin for reserves
     * @param _priceOracle Address authorized to update price
     * @param _initialPrice Initial token price in stable coin units (scaled by 1e18)
     * @param _reserveRatio Target reserve ratio (10000 = 100%)
     * @param _minReserveRatio Minimum reserve ratio 
     * @param _platformFeePercent Regular platform fee percentage
     * @param _lowValueFeePercent Reduced fee during low token value
     * @param _valueThreshold Threshold for low value detection
     */
    constructor(
        address _teachToken,
        address _stableCoin,
        address _priceOracle,
        uint256 _initialPrice,
        uint256 _reserveRatio,
        uint256 _minReserveRatio,
        uint256 _platformFeePercent,
        uint256 _lowValueFeePercent,
        uint256 _valueThreshold
    ) Ownable(msg.sender) {
        require(_teachToken != address(0), "PlatformStabilityFund: zero teach token address");
        require(_stableCoin != address(0), "PlatformStabilityFund: zero stable coin address");
        require(_priceOracle != address(0), "PlatformStabilityFund: zero oracle address");
        require(_initialPrice > 0, "PlatformStabilityFund: zero initial price");
        require(_reserveRatio > _minReserveRatio, "PlatformStabilityFund: invalid reserve ratios");
        require(_platformFeePercent >= _lowValueFeePercent, "PlatformStabilityFund: regular fee must be >= low value fee");
        require(_valueThreshold > 0, "PlatformStabilityFund: zero threshold");

        teachToken = IERC20(_teachToken);
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
    function updateBaselinePrice(uint256 _newBaselinePrice) external onlyOwner {
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
    function updateCurrentFee() public returns (uint16) {
        uint256 valueDropPercent = 0;

        if (tokenPrice < baselinePrice) {
            // Calculate how far below baseline we are (in percentage points, scaled by 10000)
            valueDropPercent = ((baselinePrice - tokenPrice) * 10000) / baselinePrice;
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
    function withdrawReserves(uint256 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "PlatformStabilityFund: zero amount");

        // Calculate maximum withdrawable amount based on min reserve ratio
        uint256 totalTokenValue = (teachToken.totalSupply() * tokenPrice) / 1e18;
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
     * @dev Converts TEACH tokens to stable coins for project funding with stability protection
     * @param _project Address of the project receiving funds
     * @param _teachAmount Amount of TEACH tokens to convert
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins sent to the project
     */
    function convertTokensToFunding(
        address _project,
        uint256 _teachAmount,
        uint256 _minReturn
    ) external onlyOwner nonReentrant whenNotPaused returns (uint256 stableAmount) {
        require(_project != address(0), "PlatformStabilityFund: zero project address");
        require(_teachAmount > 0, "PlatformStabilityFund: zero amount");

        // Calculate expected value at baseline price
        uint256 baselineValue = (_teachAmount * baselinePrice) / 1e18;

        // Calculate current value
        uint256 currentValue = (_teachAmount * tokenPrice) / 1e18;

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

        // Transfer TEACH tokens from sender to contract
        require(teachToken.transferFrom(msg.sender, address(this), _teachAmount), "PlatformStabilityFund: teach transfer failed");

        // Transfer stable coins to project
        if (stableAmount > 0) {
            require(stableCoin.transfer(_project, stableAmount), "PlatformStabilityFund: stable transfer failed");
        }

        emit TokensConverted(_project, _teachAmount, stableAmount, subsidy);

        checkAndPauseIfCritical();
        
        return stableAmount;
    }

    /**
     * @dev Get the reserve ratio health of the fund
     * @return uint256 Current reserve ratio (10000 = 100%)
     */
    function getReserveRatioHealth() public view returns (uint256) {
        uint256 totalTokenValue = (teachToken.totalSupply() * tokenPrice) / 1e18;

        if (totalTokenValue == 0) {
            return 10000; // 100% if no tokens
        }

        return (totalReserves * 10000) / totalTokenValue;
    }

    /**
     * @dev Simulates a token conversion without executing it
     * @param _teachAmount Amount of TEACH tokens to convert
     * @return expectedValue Expected stable coin value based on current price
     * @return subsidyAmount Expected subsidy amount (if any)
     * @return finalAmount Final amount after subsidy
     * @return feeAmount Platform fee amount
     */
    function simulateConversion(uint256 _teachAmount) external view returns (
        uint256 expectedValue,
        uint256 subsidyAmount,
        uint256 finalAmount,
        uint256 feeAmount
    ) {
        // Calculate expected value at current price
        expectedValue = (_teachAmount * tokenPrice) / 1e18;

        // Calculate baseline value
        uint256 baselineValue = (_teachAmount * baselinePrice) / 1e18;

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
    ) external onlyOwner {
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
    function updatePriceOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "PlatformStabilityFund: zero oracle address");

        emit PriceOracleUpdated(priceOracle, _newOracle);

        priceOracle = _newOracle;
    }

    /**
     * @dev Swap TEACH tokens for stable coins
     * @param _teachAmount Amount of TEACH tokens to swap
     * @param _minReturn Minimum stable coin amount to receive
     * @return stableAmount Amount of stable coins received
     */
    function swapTokensForStable(uint256 _teachAmount, uint256 _minReturn) external nonReentrant returns (uint256 stableAmount) {
        require(_teachAmount > 0, "PlatformStabilityFund: zero amount");

        // Calculate the value of TEACH tokens at current price
        stableAmount = (_teachAmount * tokenPrice) / 1e18;

        // Check minimum return
        require(stableAmount >= _minReturn, "PlatformStabilityFund: below min return");

        // Check if we have enough reserves
        require(stableAmount <= totalReserves, "PlatformStabilityFund: insufficient reserves");

        // Update state
        totalReserves -= stableAmount;

        // Transfer TEACH tokens from sender to contract
        require(teachToken.transferFrom(msg.sender, address(this), _teachAmount), "PlatformStabilityFund: teach transfer failed");

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
    function emergencyPause() external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "PlatformStabilityFund: not authorized");
        require(!paused, "PlatformStabilityFund: already paused");

        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
    * @dev Resumes the fund from pause state
    */
    function resumeFromPause() external onlyOwner {
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
    function setCriticalReserveThreshold(uint16 _threshold) external onlyOwner {
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
    function setEmergencyAdmin(address _newAdmin) external onlyOwner {
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
    ) external onlyOwner {
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
    * @param _burnedAmount Amount of TEACH tokens that were burned
    */
    function processBurnedTokens(uint256 _burnedAmount) external {
        require(authorizedBurners[msg.sender], "PlatformStabilityFund: not authorized");
        require(_burnedAmount > 0, "PlatformStabilityFund: zero burn amount");

        // Calculate value of burned tokens
        uint256 burnValue = (_burnedAmount * tokenPrice) / 1e18;

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
    function processPlatformFees(uint256 _feeAmount) external onlyOwner {
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
    ) external onlyOwner {
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
    function setAuthBurner(address _burner, bool _authorized) external onlyOwner {
        require(_burner != address(0), "PlatformStabilityFund: zero burner address");

        authorizedBurners[_burner] = _authorized;

        emit BurnerAuthorization(_burner, _authorized);
    }
}