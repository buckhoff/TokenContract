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
 * @dev Contract that protects the platform from token price volatility
 */
contract PlatformStabilityFund is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
IStabilityFund,
UUPSUpgradeable
{
    struct PriceObservation {
        uint64 timestamp;
        uint128 price;
    }

    struct EmergencyData {
        bool paused;
        bool inRecovery;
        uint8 requiredApprovals;
        uint8 approvalCount;
        uint64 pauseTime;
    }

    struct PriceData {
        uint128 tokenPrice;
        uint128 baselinePrice;
        uint64 lastUpdateTime;
    }

    struct FeeParams {
        uint16 baseFeePercent;
        uint16 maxFeePercent;
        uint16 minFeePercent;
        uint16 currentFeePercent;
        uint16 adjustmentFactor;
        uint16 priceDropThreshold;
        uint16 maxPriceDropPercent;
    }

    struct ReserveParams {
        uint16 reserveRatio;
        uint16 minReserveRatio;
        uint16 criticalThreshold;
        uint16 burnToReservePercent;
        uint16 platformFeeToReservePercent;
    }

    struct FlashLoanParams {
        uint96 maxDailyUserVolume;
        uint96 maxSingleAmount;
        uint32 minTimeBetween;
        bool enabled;
    }

    struct TWAPConfig {
        uint8 windowSize;
        uint8 currentIndex;
        uint32 interval;
        uint64 lastTimestamp;
        bool enabled;
    }

    // Main state variables
    ERC20Upgradeable internal token;
    ERC20Upgradeable public stableCoin;
    address public priceOracle;
    address public emergencyAdmin;

    // Optimized group state variables
    PriceData public priceData;
    FeeParams public feeParams;
    ReserveParams public reserveParams;
    EmergencyData public emergencyData;
    FlashLoanParams public flashLoanParams;
    TWAPConfig public twapConfig;

    // Financial state
    uint128 public totalReserves;
    uint32 public totalConversions;
    uint128 public totalStabilized;

    // Flash loan protection
    mapping(address => uint64) private lastActionTimestamp;
    mapping(address => uint96) private dailyConversionVolume;
    mapping(address => bool) public addressCooldown;
    uint32 public suspiciousCooldownPeriod = 24 hours;

    // TWAP data
    PriceObservation[24] public priceHistory;

    // Recovery and authorization
    mapping(address => bool) public emergencyRecoveryApprovals;
    mapping(address => bool) public authorizedBurners;

    // Events
    event ReservesAdded(address indexed contributor, uint128 amount);
    event ReservesWithdrawn(address indexed recipient, uint128 amount);
    event TokensConverted(address indexed project, uint96 tokenAmount, uint128 stableAmount, uint128 subsidyAmount);
    event PriceUpdated(uint128 oldPrice, uint128 newPrice);
    event FundParametersUpdated(uint16 reserveRatio, uint16 minReserveRatio, uint16 platformFee, uint16 lowValueFee, uint16 threshold);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ValueModeChanged(bool isLowValueMode);
    event BaselinePriceUpdated(uint128 oldPrice, uint128 newPrice);
    event CircuitBreakerTriggered(uint16 currentRatio, uint16 threshold);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event EmergencyPaused(address indexed triggeredBy);
    event EmergencyResumed(address indexed resumedBy);
    event CriticalThresholdUpdated(uint16 oldThreshold, uint16 newThreshold);
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event FeeParametersUpdated(uint16 baseFee, uint16 maxFee, uint16 minFee, uint16 adjustmentFactor, uint16 dropThreshold, uint16 maxDropPercent);
    event FlashLoanProtectionConfigured(uint96 maxDailyVolume, uint96 maxSingleAmount, uint32 minTimeBetween, bool enabled);
    event CurrentFeeUpdated(uint16 oldFee, uint16 newFee);
    event TokensBurnedToReserves(uint96 burnedAmount, uint128 reservesAdded);
    event PlatformFeesToReserves(uint96 feeAmount, uint128 reservesAdded);
    event ReplenishmentParametersUpdated(uint16 burnPercent, uint16 feePercent);
    event BurnerAuthorization(address indexed burner, bool authorized);
    event SuspiciousActivity(address indexed user, string reason, uint96 amount);
    event PriceObservationRecorded(uint64 timestamp, uint128 price, uint8 index);
    event TWAPConfigUpdated(uint8 windowSize, uint32 interval, bool enabled);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint64 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin, uint64 timestamp);
    event AddressPlacedInCooldown(address indexed suspiciousAddress, uint64 endTime);
    event AddressRemovedFromCooldown(address indexed cooldownAddress);

    modifier whenNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "StabilityFund: system is paused");
            } catch {
                require(!emergencyData.paused, "StabilityFund: contract is paused");
            }
            require(!registryOfflineMode, "StabilityFund: registry Offline");
        } else {
            require(!emergencyData.paused, "StabilityFund: contract is paused");
        }
        _;
    }

    modifier flashLoanGuard(uint96 _amount) {
        if (flashLoanParams.enabled) {
            require(!addressCooldown[msg.sender], "StabilityFund: address in cooldown");

            uint64 dayStart = uint64(block.timestamp - (block.timestamp % 1 days));
            if (lastActionTimestamp[msg.sender] < dayStart) {
                dailyConversionVolume[msg.sender] = 0;
            }

            require(
                block.timestamp >= lastActionTimestamp[msg.sender] + flashLoanParams.minTimeBetween,
                "StabilityFund: action too soon"
            );

            require(
                _amount <= flashLoanParams.maxSingleAmount,
                "StabilityFund: exceeds max single conversion"
            );

            require(
                dailyConversionVolume[msg.sender] + _amount <= flashLoanParams.maxDailyUserVolume,
                "StabilityFund: daily volume exceeded"
            );

            lastActionTimestamp[msg.sender] = uint64(block.timestamp);
            dailyConversionVolume[msg.sender] += _amount;
        }
        _;
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _token,
        address _stableCoin,
        address _priceOracle,
        uint128 _initialPrice,
        uint16 _reserveRatio,
        uint16 _minReserveRatio,
        uint16 _platformFeePercent,
        uint16 _lowValueFeePercent,
        uint16 _valueThreshold
    ) initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);

        require(_token != address(0), "StabilityFund: zero token address");
        require(_stableCoin != address(0), "StabilityFund: zero stable coin address");
        require(_priceOracle != address(0), "StabilityFund: zero oracle address");
        require(_initialPrice > 0, "StabilityFund: zero initial price");
        require(_reserveRatio > _minReserveRatio, "StabilityFund: invalid reserve ratios");
        require(_platformFeePercent >= _lowValueFeePercent, "StabilityFund: fee config error");
        require(_valueThreshold > 0, "StabilityFund: zero threshold");

        token = ERC20Upgradeable(_token);
        stableCoin = ERC20Upgradeable(_stableCoin);
        priceOracle = _priceOracle;

        // Initialize price data
        priceData = PriceData({
            tokenPrice: _initialPrice,
            baselinePrice: _initialPrice,
            lastUpdateTime: uint64(block.timestamp)
        });

        // Initialize fee parameters
        feeParams = FeeParams({
            baseFeePercent: _platformFeePercent,
            maxFeePercent: _platformFeePercent,
            minFeePercent: _lowValueFeePercent,
            currentFeePercent: _platformFeePercent,
            adjustmentFactor: 100,
            priceDropThreshold: _valueThreshold,
            maxPriceDropPercent: 3000
        });

        // Initialize reserve parameters
        reserveParams = ReserveParams({
            reserveRatio: _reserveRatio,
            minReserveRatio: _minReserveRatio,
            criticalThreshold: 120,
            burnToReservePercent: 1000,
            platformFeeToReservePercent: 2000
        });

        // Initialize emergency data
        emergencyData = EmergencyData({
            paused: false,
            inRecovery: false,
            requiredApprovals: 3,
            approvalCount: 0,
            pauseTime: 0
        });

        // Initialize flash loan protection
        flashLoanParams = FlashLoanParams({
            maxDailyUserVolume: 1_000_000 * 10**18,
            maxSingleAmount: 100_000 * 10**18,
            minTimeBetween: 15 minutes,
            enabled: true
        });

        // Initialize TWAP config
        twapConfig = TWAPConfig({
            windowSize: 12,
            currentIndex: 0,
            interval: 1 hours,
            lastTimestamp: 0,
            enabled: true
        });

        emergencyAdmin = msg.sender;
        authorizedBurners[msg.sender] = true;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ORACLE_ROLE, _priceOracle);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(Constants.BURNER_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Sets the registry contract address
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, Constants.STABILITY_FUND_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Updates the baseline price (governance function)
     */
    function updateBaselinePrice(uint128 _newBaselinePrice) external onlyRole(Constants.ADMIN_ROLE) {
        require(_newBaselinePrice > 0, "StabilityFund: zero baseline price");

        emit BaselinePriceUpdated(priceData.baselinePrice, _newBaselinePrice);
        priceData.baselinePrice = _newBaselinePrice;

        // Re-check low value mode status with new baseline
        updateValueMode();
    }

    /**
     * @dev Updates the current fee based on token price relative to baseline
     */
    function updateCurrentFee() public onlyRole(Constants.ADMIN_ROLE) returns (uint16) {
        uint128 verifiedPrice = getVerifiedPrice();
        uint16 valueDropPercent = 0;

        if (verifiedPrice < priceData.baselinePrice) {
            valueDropPercent = uint16(((priceData.baselinePrice - verifiedPrice) * 10000) / priceData.baselinePrice);
        }

        uint16 oldFee = feeParams.currentFeePercent;

        // If price drop is below threshold, use base fee
        if (valueDropPercent <= feeParams.priceDropThreshold) {
            feeParams.currentFeePercent = feeParams.baseFeePercent;
        }
            // If price drop exceeds max threshold, use min fee
        else if (valueDropPercent >= feeParams.maxPriceDropPercent) {
            feeParams.currentFeePercent = feeParams.minFeePercent;
        }
            // Otherwise calculate gradual fee reduction
        else {
            // Calculate how far between threshold and max drop we are (0-100%)
            uint16 adjustmentRange = feeParams.maxPriceDropPercent - feeParams.priceDropThreshold;
            uint16 adjustmentPosition = valueDropPercent - feeParams.priceDropThreshold;
            uint16 adjustmentPercent = (adjustmentPosition * 100) / adjustmentRange;

            // Apply adjustment factor
            adjustmentPercent = (adjustmentPercent * feeParams.adjustmentFactor) / 100;
            if (adjustmentPercent > 100) {
                adjustmentPercent = 100;
            }

            // Calculate fee reduction amount
            uint16 feeRange = feeParams.baseFeePercent - feeParams.minFeePercent;
            uint16 feeReduction = (feeRange * adjustmentPercent) / 100;

            // Apply the reduction to the base fee
            feeParams.currentFeePercent = feeParams.baseFeePercent - feeReduction;
        }

        if (oldFee != feeParams.currentFeePercent) {
            emit CurrentFeeUpdated(oldFee, feeParams.currentFeePercent);
        }

        return feeParams.currentFeePercent;
    }

    /**
     * @dev Adds stable coins to the stability reserves
     */
    function addReserves(uint128 _amount) external nonReentrant {
        require(_amount > 0, "StabilityFund: zero amount");

        // Transfer stable coins to contract
        require(stableCoin.transferFrom(msg.sender, address(this), _amount), "StabilityFund: transfer failed");

        totalReserves += _amount;

        emit ReservesAdded(msg.sender, _amount);
    }

    /**
     * @dev Withdraws stable coins from reserves (only owner)
     */
    function withdrawReserves(uint128 _amount) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_amount > 0, "StabilityFund: zero amount");
        uint128 verifiedPrice = getVerifiedPrice();

        // Calculate maximum withdrawable amount based on min reserve ratio
        uint128 totalTokenValue = uint128((token.totalSupply() * verifiedPrice) / 1e18);
        uint128 minReserveRequired = uint128((totalTokenValue * reserveParams.minReserveRatio) / 10000);

        uint128 excessReserves = 0;
        if (totalReserves > minReserveRequired) {
            excessReserves = totalReserves - minReserveRequired;
        }

        require(_amount <= excessReserves, "StabilityFund: exceeds available reserves");

        totalReserves -= _amount;

        // Transfer stable coins from contract
        require(stableCoin.transfer(msg.sender, _amount), "StabilityFund: transfer failed");

        emit ReservesWithdrawn(msg.sender, _amount);
    }

    /**
     * @dev Converts tokens to stable coins with stability protection
     */
    function convertTokensToFunding(
        address _project,
        uint96 _tokenAmount,
        uint128 _minReturn
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant whenNotPaused flashLoanGuard(_tokenAmount) returns (uint128 stableAmount) {
        require(_project != address(0), "StabilityFund: zero project address");
        require(_tokenAmount > 0, "StabilityFund: zero amount");

        uint128 verifiedPrice = getVerifiedPrice();

        // Calculate expected value at baseline price
        uint128 baselineValue = uint128((_tokenAmount * priceData.baselinePrice) / 1e18);

        // Calculate current value
        uint128 currentValue = uint128((_tokenAmount * verifiedPrice) / 1e18);

        // Apply platform fee
        uint16 feePercent = updateCurrentFee();
        uint128 fee = uint128((currentValue * feePercent) / 10000);
        uint128 valueAfterFee = currentValue - fee;

        // Calculate subsidy (if any)
        uint128 subsidy = 0;
        if (valueAfterFee < baselineValue) {
            subsidy = baselineValue - valueAfterFee;

            // Cap subsidy by available reserves
            if (subsidy > totalReserves) {
                subsidy = totalReserves;
            }
        }

        // Calculate final amount to send to project
        stableAmount = valueAfterFee + subsidy;
        require(stableAmount >= _minReturn, "StabilityFund: below min return");

        // Update state
        if (subsidy > 0) {
            totalReserves -= subsidy;
            totalStabilized += subsidy;
        }
        totalConversions += 1;

        // Transfer tokens from sender to contract
        require(token.transferFrom(msg.sender, address(this), _tokenAmount), "StabilityFund: token transfer failed");

        // Transfer stable coins to project
        if (stableAmount > 0) {
            require(stableCoin.transfer(_project, stableAmount), "StabilityFund: stable transfer failed");
        }

        emit TokensConverted(_project, _tokenAmount, stableAmount, subsidy);

        checkAndPauseIfCritical();

        return stableAmount;
    }

    /**
     * @dev Get the reserve ratio health of the fund
     */
    function getReserveRatioHealth() public view returns (uint16) {
        uint128 verifiedPrice = getVerifiedPrice();
        uint128 totalTokenValue = uint128((token.totalSupply() * verifiedPrice) / 1e18);

        if (totalTokenValue == 0) {
            return 10000; // 100% if no tokens
        }

        return uint16((totalReserves * 10000) / totalTokenValue);
    }

    /**
     * @dev Simulates a token conversion without executing it
     */
    function simulateConversion(uint96 _tokenAmount) external view returns (
        uint128 expectedValue,
        uint128 subsidyAmount,
        uint128 finalAmount,
        uint128 feeAmount
    ) {
        uint128 verifiedPrice = getVerifiedPrice();

        // Calculate expected value at current price
        expectedValue = uint128((_tokenAmount * verifiedPrice) / 1e18);

        // Calculate baseline value
        uint128 baselineValue = uint128((_tokenAmount * priceData.baselinePrice) / 1e18);

        // Apply platform fee
        uint16 feePercent = feeParams.currentFeePercent;
        feeAmount = uint128((expectedValue * feePercent) / 10000);
        uint128 valueAfterFee = expectedValue - feeAmount;

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
     * @dev Checks if reserve ratio is below critical threshold and pauses if needed
     */
    function checkAndPauseIfCritical() public returns (bool) {
        uint16 reserveRatioHealth = getReserveRatioHealth();
        uint16 criticalThreshold = uint16((reserveParams.minReserveRatio * reserveParams.criticalThreshold) / 100);

        if (reserveRatioHealth < criticalThreshold) {
            if (!emergencyData.paused) {
                emergencyData.paused = true;
                emergencyData.pauseTime = uint64(block.timestamp);
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
    function emergencyPause() external onlyRole(Constants.EMERGENCY_ROLE) {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "StabilityFund: not authorized");
        require(!emergencyData.paused, "StabilityFund: already paused");

        emergencyData.paused = true;
        emergencyData.pauseTime = uint64(block.timestamp);
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Resumes the fund from pause state
     */
    function resumeFromPause() external onlyRole(Constants.ADMIN_ROLE) {
        require(emergencyData.paused, "StabilityFund: not paused");

        // Ensure reserves are above critical threshold before resuming
        uint16 reserveRatioHealth = getReserveRatioHealth();
        uint16 criticalThreshold = uint16((reserveParams.minReserveRatio * reserveParams.criticalThreshold) / 100);
        require(reserveRatioHealth >= criticalThreshold, "StabilityFund: reserves still critical");

        emergencyData.paused = false;
        emit EmergencyResumed(msg.sender);
    }

    /**
     * @dev Updates the price oracle address
     */
    function updatePriceOracle(address _newOracle) external onlyRole(Constants.ADMIN_ROLE) {
        require(_newOracle != address(0), "StabilityFund: zero oracle address");
        emit PriceOracleUpdated(priceOracle, _newOracle);
        priceOracle = _newOracle;
        _grantRole(Constants.ORACLE_ROLE, _newOracle);
    }

    /**
     * @dev Swap platform tokens for stable coins
     */
    function swapTokensForStable(uint96 _tokenAmount, uint128 _minReturn) external nonReentrant flashLoanGuard(_tokenAmount) returns (uint128 stableAmount) {
        require(_tokenAmount > 0, "StabilityFund: zero amount");

        uint128 verifiedPrice = getVerifiedPrice();

        // Calculate the value of platform tokens at current price
        stableAmount = uint128((_tokenAmount * verifiedPrice) / 1e18);

        // Check minimum return
        require(stableAmount >= _minReturn, "StabilityFund: below min return");

        // Check if we have enough reserves
        require(stableAmount <= totalReserves, "StabilityFund: insufficient reserves");

        // Update state
        totalReserves -= stableAmount;

        // Transfer platform tokens from sender to contract
        require(token.transferFrom(msg.sender, address(this), _tokenAmount), "StabilityFund: token transfer failed");

        // Transfer stable coins to sender
        require(stableCoin.transfer(msg.sender, stableAmount), "StabilityFund: stable transfer failed");

        checkAndPauseIfCritical();

        return stableAmount;
    }

    /**
     * @dev Update the token price
     */
    function updatePrice(uint128 _newPrice) external onlyRole(Constants.ORACLE_ROLE) {
        require(_newPrice > 0, "StabilityFund: zero price");

        uint128 verifiedPrice = getVerifiedPrice();
        uint128 oldPrice = verifiedPrice;

        // Calculate the maximum allowed price change (e.g. 10%)
        uint128 maxPriceChange = uint128(verifiedPrice * 1000 / 10000); // 10%

        // If TWAP is enabled, check against the time-weighted average
        if (twapConfig.enabled) {
            uint128 twapPrice = calculateTWAP();

            // If we have enough observations and the new price deviates significantly from TWAP
            if (twapPrice > 0) {
                uint16 twapDeviation;

                if (_newPrice > twapPrice) {
                    twapDeviation = uint16(((_newPrice - twapPrice) * 10000) / twapPrice);
                } else {
                    twapDeviation = uint16(((twapPrice - _newPrice) * 10000) / twapPrice);
                }

                // If the deviation exceeds a threshold (e.g. 20%), reject the update
                require(twapDeviation <= 2000, "StabilityFund: deviates too much from TWAP");
            }
        }

        // Check for sudden large price changes
        if (verifiedPrice > 0) {
            uint128 priceChange;

            if (_newPrice > verifiedPrice) {
                priceChange = _newPrice - verifiedPrice;
            } else {
                priceChange = verifiedPrice - _newPrice;
            }

            // If the change is too large, reject the update
            require(priceChange <= maxPriceChange, "StabilityFund: price change too large");
        }

        // Update the price
        priceData.tokenPrice = _newPrice;
        priceData.lastUpdateTime = uint64(block.timestamp);

        // Record this observation
        recordPriceObservation();

        // Check if we should enter or exit low value mode
        updateValueMode();

        emit PriceUpdated(oldPrice, _newPrice);
    }

    /**
     * @dev Record a price observation for TWAP
     */
    function recordPriceObservation() public {
        // Only record if enough time has passed since last observation
        if (block.timestamp >= twapConfig.lastTimestamp + twapConfig.interval) {
            uint128 verifiedPrice = getVerifiedPrice();

            // Update the current observation
            priceHistory[twapConfig.currentIndex] = PriceObservation({
                timestamp: uint64(block.timestamp),
                price: verifiedPrice
            });

            emit PriceObservationRecorded(uint64(block.timestamp), verifiedPrice, twapConfig.currentIndex);

            // Update tracking variables
            twapConfig.lastTimestamp = uint64(block.timestamp);

            // Move to next slot in circular buffer
            twapConfig.currentIndex = (twapConfig.currentIndex + 1) % 24;
        }
    }

    /**
     * @dev Calculate time-weighted average price
     */
    function calculateTWAP() public view returns (uint128) {
        uint8 validObservations = 0;
        uint128 weightedPriceSum = 0;
        uint64 timeSum = 0;
        uint64 oldestAllowedTimestamp = uint64(block.timestamp - (twapConfig.windowSize * twapConfig.interval));

        // Start from newest and work backward
        uint8 startIndex = (twapConfig.currentIndex == 0) ? 23 : (twapConfig.currentIndex - 1);

        for (uint8 i = 0; i < 24 && validObservations < twapConfig.windowSize; i++) {
            uint8 index = (startIndex - i + 24) % 24;
            PriceObservation memory observation = priceHistory[index];

            // Skip if this slot has no observation or if it's too old
            if (observation.timestamp == 0 || observation.timestamp < oldestAllowedTimestamp) {
                continue;
            }

            uint64 timeWeight;
            if (validObservations == 0) {
                timeWeight = uint64(block.timestamp) - observation.timestamp;
            } else {
                uint8 prevIndex = (index + 1) % 24;
                timeWeight = priceHistory[prevIndex].timestamp - observation.timestamp;
            }

            weightedPriceSum += uint128(observation.price * timeWeight);
            timeSum += timeWeight;
            validObservations++;
        }

        // Return 0 if not enough observations
        if (timeSum == 0 || validObservations < twapConfig.windowSize / 2) {
            return 0;
        }

        return uint128(weightedPriceSum / timeSum);
    }

    /**
     * @dev Configure TWAP parameters
     */
    function configureTWAP(
        uint8 _windowSize,
        uint32 _interval,
        bool _enabled
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_windowSize > 0 && _windowSize <= 24, "StabilityFund: invalid window size");
        require(_interval > 0, "StabilityFund: interval cannot be zero");

        twapConfig.windowSize = _windowSize;
        twapConfig.interval = _interval;
        twapConfig.enabled = _enabled;

        emit TWAPConfigUpdated(_windowSize, _interval, _enabled);
    }

    /**
     * @dev Get the verified price (with TWAP protection)
     */
    function getVerifiedPrice() public view returns (uint128) {
        // If TWAP is enabled and we have enough observations, use TWAP
        if (twapConfig.enabled) {
            uint128 twapPrice = calculateTWAP();
            if (twapPrice > 0) {
                // Check if current price deviates too much from TWAP
                uint16 deviation;
                if (priceData.tokenPrice > twapPrice) {
                    deviation = uint16(((priceData.tokenPrice - twapPrice) * 10000) / twapPrice);
                } else {
                    deviation = uint16(((twapPrice - priceData.tokenPrice) * 10000) / twapPrice);
                }

                // If deviation is too large, return TWAP instead
                if (deviation > 2000) { // 20% threshold
                    return twapPrice;
                }
            }
        }

        return priceData.tokenPrice;
    }

    /**
     * @dev Updates the value mode based on current price vs baseline
     */
    function updateValueMode() internal {
        uint128 verifiedPrice = getVerifiedPrice();

        // Calculate how far below baseline we are (in percentage points)
        uint16 valueDropPercent = 0;
        if (verifiedPrice < priceData.baselinePrice) {
            valueDropPercent = uint16(((priceData.baselinePrice - verifiedPrice) * 10000) / priceData.baselinePrice);
        }

        // Update current fee based on new value mode
        updateCurrentFee();

        emit ValueModeChanged(valueDropPercent >= feeParams.priceDropThreshold);
    }

    /**
     * @dev Process burned tokens and convert a portion to reserves
     */
    function processBurnedTokens(uint96 _burnedAmount) external onlyRole(Constants.BURNER_ROLE) {
        require(_burnedAmount > 0, "StabilityFund: zero burn amount");

        // If the registry is set, verify the caller is either registered burner or token contract
        if (address(registry) != address(0)) {
            if (registry.isContractActive(Constants.TOKEN_NAME)) {
                address tokenAddress = registry.getContractAddress(Constants.TOKEN_NAME);
                require(
                    msg.sender == tokenAddress || hasRole(Constants.BURNER_ROLE, msg.sender),
                    "StabilityFund: not authorized"
                );
            }
        } else {
            require(hasRole(Constants.BURNER_ROLE, msg.sender), "StabilityFund: not authorized");
        }

        uint128 verifiedPrice = getVerifiedPrice();
        // Calculate value of burned tokens
        uint128 burnValue = uint128((_burnedAmount * verifiedPrice) / 1e18);

        // Calculate portion to add to reserves
        uint128 reservesToAdd = uint128((burnValue * reserveParams.burnToReservePercent) / 10000);

        if (reservesToAdd > 0) {
            // Owner is expected to transfer stablecoins to the contract
            totalReserves += reservesToAdd;
            emit TokensBurnedToReserves(_burnedAmount, reservesToAdd);
        }
    }

    /**
     * @dev Process platform fees and add portion to reserves
     */
    function processPlatformFees(uint96 _feeAmount) external onlyRole(Constants.ADMIN_ROLE) {
        require(_feeAmount > 0, "StabilityFund: zero fee amount");

        // Calculate portion to add to reserves
        uint128 reservesToAdd = uint128((_feeAmount * reserveParams.platformFeeToReservePercent) / 10000);

        if (reservesToAdd > 0) {
            // Require the owner to transfer the stablecoins
            require(stableCoin.transferFrom(msg.sender, address(this), reservesToAdd),
                "StabilityFund: transfer failed");

            totalReserves += reservesToAdd;
            emit PlatformFeesToReserves(_feeAmount, reservesToAdd);
        }
    }

    /**
     * @dev Sets the critical reserve threshold percentage
     */
    function setCriticalReserveThreshold(uint16 _threshold) external onlyRole(Constants.ADMIN_ROLE) {
        require(_threshold > 100, "StabilityFund: threshold must be > 100%");
        require(_threshold <= 200, "StabilityFund: threshold too high");

        emit CriticalThresholdUpdated(reserveParams.criticalThreshold, _threshold);
        reserveParams.criticalThreshold = _threshold;

        // Check if we need to pause based on new threshold
        checkAndPauseIfCritical();
    }

    /**
     * @dev Updates the emergency admin address
     */
    function setEmergencyAdmin(address _newAdmin) external onlyRole(Constants.ADMIN_ROLE) {
        require(_newAdmin != address(0), "StabilityFund: zero admin address");

        emit EmergencyAdminUpdated(emergencyAdmin, _newAdmin);
        emergencyAdmin = _newAdmin;
        _grantRole(Constants.EMERGENCY_ROLE, _newAdmin);
    }

    /**
     * @dev Updates fee adjustment parameters
     */
    function updateFeeParameters(
        uint16 _baseFee,
        uint16 _maxFee,
        uint16 _minFee,
        uint16 _adjustmentFactor,
        uint16 _dropThreshold,
        uint16 _maxDropPercent
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_maxFee >= _baseFee && _baseFee >= _minFee, "StabilityFund: invalid fee range");
        require(_maxDropPercent > _dropThreshold, "StabilityFund: invalid drop thresholds");
        require(_adjustmentFactor > 0, "StabilityFund: zero adjustment factor");

        feeParams.baseFeePercent = _baseFee;
        feeParams.maxFeePercent = _maxFee;
        feeParams.minFeePercent = _minFee;
        feeParams.adjustmentFactor = _adjustmentFactor;
        feeParams.priceDropThreshold = _dropThreshold;
        feeParams.maxPriceDropPercent = _maxDropPercent;

        emit FeeParametersUpdated(_baseFee, _maxFee, _minFee, _adjustmentFactor, _dropThreshold, _maxDropPercent);

        // Update current fee with new parameters
        updateCurrentFee();
    }

    /**
     * @dev Updates replenishment parameters
     */
    function updateReplenishmentParameters(
        uint16 _burnPercent,
        uint16 _feePercent
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_burnPercent <= 5000, "StabilityFund: burn percent too high");
        require(_feePercent <= 10000, "StabilityFund: fee percent too high");

        reserveParams.burnToReservePercent = _burnPercent;
        reserveParams.platformFeeToReservePercent = _feePercent;

        emit ReplenishmentParametersUpdated(_burnPercent, _feePercent);
    }

    /**
     * @dev Authorize or deauthorize a token burner
     */
    function setAuthBurner(address _burner, bool _authorized) external onlyRole(Constants.ADMIN_ROLE) {
        require(_burner != address(0), "StabilityFund: zero burner address");

        if (_authorized) {
            grantRole(Constants.BURNER_ROLE, _burner);
        } else {
            revokeRole(Constants.BURNER_ROLE, _burner);
        }

        authorizedBurners[_burner] = _authorized;
        emit BurnerAuthorization(_burner, _authorized);
    }

    /**
     * @dev Updates fund parameters
     */
    function updateFundParameters(
        uint16 _reserveRatio,
        uint16 _minReserveRatio,
        uint16 _platformFeePercent,
        uint16 _lowValueFeePercent,
        uint16 _valueThreshold
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_reserveRatio > _minReserveRatio, "StabilityFund: invalid reserve ratios");
        require(_platformFeePercent >= _lowValueFeePercent, "StabilityFund: fee config error");
        require(_valueThreshold > 0, "StabilityFund: zero threshold");

        reserveParams.reserveRatio = _reserveRatio;
        reserveParams.minReserveRatio = _minReserveRatio;
        feeParams.baseFeePercent = _platformFeePercent;
        feeParams.minFeePercent = _lowValueFeePercent;
        feeParams.priceDropThreshold = _valueThreshold;

        emit FundParametersUpdated(_reserveRatio, _minReserveRatio, _platformFeePercent, _lowValueFeePercent, _valueThreshold);

        // Re-check low value mode status with new parameters
        updateValueMode();
    }

    /**
     * @dev Configure flash loan protection parameters
     */
    function configureFlashLoanProtection(
        uint96 _maxDailyUserVolume,
        uint96 _maxSingleConversionAmount,
        uint32 _minTimeBetweenActions,
        bool _enabled
    ) external onlyRole(Constants.ADMIN_ROLE) {
        flashLoanParams.maxDailyUserVolume = _maxDailyUserVolume;
        flashLoanParams.maxSingleAmount = _maxSingleConversionAmount;
        flashLoanParams.minTimeBetween = _minTimeBetweenActions;
        flashLoanParams.enabled = _enabled;

        emit FlashLoanProtectionConfigured(
            _maxDailyUserVolume,
            _maxSingleConversionAmount,
            _minTimeBetweenActions,
            _enabled
        );
    }

    /**
     * @dev Place suspicious address in cooldown
     */
    function placeSuspiciousAddressInCooldown(address _suspiciousAddress) external onlyRole(Constants.EMERGENCY_ROLE) {
        addressCooldown[_suspiciousAddress] = true;
        emit AddressPlacedInCooldown(_suspiciousAddress, uint64(block.timestamp + suspiciousCooldownPeriod));
    }

    /**
     * @dev Remove address from cooldown
     */
    function removeSuspiciousAddressCooldown(address _address) external onlyRole(Constants.ADMIN_ROLE) {
        addressCooldown[_address] = false;
        emit AddressRemovedFromCooldown(_address);
    }

    /**
     * @dev Initialize emergency recovery
     */
    function initializeEmergencyRecovery(uint8 _requiredApprovals) external onlyRole(Constants.ADMIN_ROLE) {
        emergencyData.requiredApprovals = _requiredApprovals;
    }

    /**
     * @dev Initiate emergency recovery
     */
    function initiateEmergencyRecovery() external onlyRole(Constants.EMERGENCY_ROLE) {
        require(emergencyData.paused, "StabilityFund: not paused");
        emergencyData.inRecovery = true;
        emergencyData.approvalCount = 0;
        // Reset approvals
        emit EmergencyRecoveryInitiated(msg.sender, uint64(block.timestamp));
    }

    /**
     * @dev Approve recovery
     */
    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        require(emergencyData.inRecovery, "StabilityFund: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "StabilityFund: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;
        emergencyData.approvalCount++;

        if (emergencyData.approvalCount >= emergencyData.requiredApprovals) {
            // Execute recovery
            emergencyData.inRecovery = false;
            emergencyData.paused = false;
            emit EmergencyRecoveryCompleted(msg.sender, uint64(block.timestamp));
        }
    }

    /**
     * @dev Emergency notification to all connected contracts
     */
    function notifyEmergencyToConnectedContracts() external onlyRole(Constants.EMERGENCY_ROLE) {
        require(address(registry) != address(0), "StabilityFund: registry not set");

        // Loop through important contracts and notify them
        bytes32[] memory contractNames = new bytes32[](5);
        contractNames[0] = Constants.MARKETPLACE_NAME;
        contractNames[1] = Constants.CROWDSALE_NAME;
        contractNames[2] = Constants.STAKING_NAME;
        contractNames[3] = Constants.PLATFORM_REWARD_NAME;
        contractNames[4] = Constants.GOVERNANCE_NAME;

        for (uint8 i = 0; i < contractNames.length; i++) {
            if (registry.isContractActive(contractNames[i])) {
                address contractAddr = registry.getContractAddress(contractNames[i]);
                // Call appropriate emergency method based on contract
                if (contractAddr != address(0)) {
                    // We don't check return values to avoid reverting the whole operation
                    // Just continue to the next contract
                    if (contractNames[i] == Constants.MARKETPLACE_NAME) {
                        contractAddr.call(abi.encodeWithSignature("pauseMarketplace()"));
                    } else if (contractNames[i] == Constants.CROWDSALE_NAME) {
                        contractAddr.call(abi.encodeWithSignature("pausePresale()"));
                    } else if (contractNames[i] == Constants.STAKING_NAME) {
                        contractAddr.call(abi.encodeWithSignature("pauseStaking()"));
                    } else if (contractNames[i] == Constants.PLATFORM_REWARD_NAME) {
                        contractAddr.call(abi.encodeWithSignature("pauseRewards()"));
                    } else if (contractNames[i] == Constants.GOVERNANCE_NAME) {
                        contractAddr.call(abi.encodeWithSignature("triggerSystemEmergency(string)", "Stability Fund triggered emergency"));
                    }
                }
            }
        }

        // Also pause this contract
        emergencyData.paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Setup for upgrade
     */
    function _authorizeUpgrade(address) internal override onlyRole(Constants.UPGRADER_ROLE) {}
}