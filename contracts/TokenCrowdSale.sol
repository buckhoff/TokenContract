// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

// Import interfaces for auxiliary contracts
interface ITokenPriceFeed {
    function getTokenUsdPrice(address token) external view returns (uint256);
    function convertTokenToUsd(address token, uint256 amount) external view returns (uint256);
    function convertUsdToToken(address token, uint256 usdAmount) external view returns (uint256);
    function isTokenSupported(address token) external view returns (bool);
    function getSupportedPaymentTokens() external view returns (address[] memory);
    function recordPaymentCollection(address token, uint256 amount) external;
}

interface ITierManager {
    struct PresaleTier {
        uint96 price;
        uint256 allocation;
        uint256 sold;
        uint256 minPurchase;
        uint256 maxPurchase;
        uint8 vestingTGE;
        uint16 vestingMonths;
        bool isActive;
    }

    function getCurrentBonus(uint8 tierId) external view returns (uint8);
    function recordPurchase(uint8 tierId, uint256 tokenAmount) external;
    function tokensRemainingInTier(uint8 tierId) external view returns (uint96);
    function totalTokensSold() external view returns (uint256);
    function getTierDetails(uint8 tierId) external view returns (PresaleTier memory);
    function isTierActive(uint8 tierId) external view returns (bool);
    function getTierPrice(uint8 tierId) external view returns (uint96);
    function getTierVestingParams(uint8 tierId) external view returns (uint8 tgePercentage, uint16 vestingMonths);
}

interface IEmergencyManager {
    enum EmergencyState { NORMAL, MINOR_EMERGENCY, CRITICAL_EMERGENCY }

    function getEmergencyState() external view returns (EmergencyState);
    function isEmergencyWithdrawalProcessed(address user) external view returns (bool);
    function processEmergencyWithdrawal(address user, uint256 amount) external;
}

interface ITeachTokenVesting {
    enum BeneficiaryGroup { TEAM, ADVISORS, PARTNERS, PUBLIC_SALE, ECOSYSTEM }

    function createLinearVestingSchedule(
        address _beneficiary,
        uint256 _amount,
        uint40 _cliffDuration,
        uint40 _duration,
        uint8 _tgePercentage,
        BeneficiaryGroup _group,
        bool _revocable
    ) external returns (uint256);

    function calculateClaimableAmount(uint256 _scheduleId) external view returns (uint256);
    function claimTokens(uint256 _scheduleId) external returns (uint256);
    function getSchedulesForBeneficiary(address _beneficiary) external view returns (uint256[] memory);
}

interface IPlatformStabilityFund {
    function getVerifiedPrice() external view returns (uint96);
}

/**
 * @title TokenCrowdSale
 * @dev Refactored multi-tier presale contract that leverages external
 * components for pricing, tier management, and emergency handling
 */
contract TokenCrowdSale is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // External components
    ITokenPriceFeed public priceFeed;
    ITierManager public tierManager;
    IEmergencyManager public emergencyManager;
    ITeachTokenVesting public vestingContract;

    // Purchase tracking
    struct Purchase {
        uint256 tokens;          // Total tokens purchased
        uint256 bonusAmount;     // Amount of bonus tokens received
        uint256 usdAmount;       // USD equivalent amount
        uint256[] tierAmounts;   // Amount purchased in each tier
        uint256 lastClaimTime;   // Last time user claimed tokens
        uint256 vestingScheduleId; // Vesting Schedule ID
        bool vestingCreated;     // Whether vesting schedule was created
        mapping(address => uint256) paymentsByToken; // Amount purchased with each token
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

    // Token and treasury
    ERC20Upgradeable public token;
    address public treasury;

    // Presale timing
    uint64 public presaleStart;
    uint64 public presaleEnd;

    // TGE status
    bool public tgeCompleted;

    // USD price scaling factor (6 decimal places)
    uint256 public constant PRICE_DECIMALS = 1e6;

    // Purchase limits
    uint96 public maxTokensPerAddress;
    mapping(address => uint256) public addressTokensPurchased;
    mapping(address => uint256) public lastPurchaseTime;
    uint32 public minTimeBetweenPurchases;
    uint256 public maxPurchaseAmount;

    // Purchase and claim tracking
    mapping(address => Purchase) public purchases;
    mapping(address => ClaimEvent[]) public claimHistory;
    mapping(address => bool) public autoCompoundEnabled;

    // Cache management
    CachedAddresses private _cachedAddresses;

    // Events
    event TierPurchase(address indexed buyer, uint8 tierId, uint256 tokenAmount, uint256 usdAmount);
    event TokensWithdrawn(address indexed user, uint256 amount);
    event PresaleTimesUpdated(uint64 newStart, uint64 newEnd);
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);
    event AutoCompoundUpdated(address indexed user, bool enabled);
    event StabilityFundRecordingFailed(address indexed user, string reason);
    event ComponentSet(string indexed componentName, address componentAddress);
    event PurchaseWithToken(
        address indexed buyer,
        uint8 tierId,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 tokenAmount,
        uint256 usdEquivalent
    );

    // Errors
    error ZeroTokenAddress();
    error ZeroPaymentTokenAddress();
    error ZeroTreasuryAddress();
    error InvalidTierId(uint8 tierId);
    error TierNotActive(uint8 tierId);
    error BelowMinPurchase(uint256 amount, uint256 minRequired);
    error AboveMaxPurchase(uint256 amount, uint256 maxAllowed);
    error ExceedsMaxTierPurchase(uint256 totalAmount, uint256 maxAllowed);
    error ExceedsMaxTokensPerAddress(uint256 totalAmount, uint256 maxAllowed);
    error InsufficientTierAllocation(uint256 requested, uint256 available);
    error PaymentTransferFailed();
    error TGENotCompleted();
    error NoTokensToWithdraw();
    error PresaleNotActive();
    error ScheduleAlreadyCreated();
    error UnauthorizedCaller();
    error PurchaseTooSoon(uint256 deadline, uint256 current);
    error TokenAlreadySet();
    error UnsupportedPaymentToken(address token);
    error ZeroComponentAddress();
    error InvalidPresaleTimes(uint64 start, uint64 end);

    modifier whenNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "TokenCrowdSale: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                IEmergencyManager.EmergencyState state = emergencyManager.getEmergencyState();
                require(state == IEmergencyManager.EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
            }
            require(!registryOfflineMode, "TokenCrowdSale: registry Offline");
        } else {
            IEmergencyManager.EmergencyState state = emergencyManager.getEmergencyState();
            require(state == IEmergencyManager.EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
        }
        _;
    }

    modifier purchaseRateLimit(uint256 _usdAmount) {
        address msgr = msg.sender;
        uint256 userLastPurchase = lastPurchaseTime[msgr];

        if (userLastPurchase != 0) {
            if (block.timestamp < userLastPurchase + minTimeBetweenPurchases) {
                revert PurchaseTooSoon(userLastPurchase + minTimeBetweenPurchases, block.timestamp);
            }
        }

        if (_usdAmount > maxPurchaseAmount)
            revert AboveMaxPurchase(_usdAmount, maxPurchaseAmount);

        lastPurchaseTime[msg.sender] = block.timestamp;
        _;
    }

    /**
     * @dev Initializer function to replace constructor
     * @param _defaultStablecoin Address of the default payment token 
     * @param _treasury Address to receive presale funds
     */
    function initialize(
        address _defaultStablecoin,
        address _treasury
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.EMERGENCY_ROLE, msg.sender);
        _grantRole(Constants.RECORDER_ROLE, msg.sender);

        // Initialize state variables
        tgeCompleted = false;
        minTimeBetweenPurchases = 1 hours;
        maxPurchaseAmount = 50_000 * PRICE_DECIMALS; // $50,000 default max
        maxTokensPerAddress = 1_500_000 * 10**6; // 1.5M tokens by default

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

    /**
     * @dev Set the token address after deployment
     * @param _token Address of the ERC20 token contract
     */
    function setSaleToken(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (_token == address(0)) revert ZeroTokenAddress();
        token = ERC20Upgradeable(_token);
        emit ContractReferenceUpdated(Constants.TOKEN_NAME, address(0), _token);
    }

    /**
     * @dev Set the vesting contract
     * @param _vestingContract Address of the vesting contract
     */
    function setVestingContract(address _vestingContract) external onlyRole(Constants.ADMIN_ROLE) {
        if (_vestingContract == address(0)) revert ZeroComponentAddress();
        vestingContract = ITeachTokenVesting(_vestingContract);
        emit ComponentSet("VestingContract", _vestingContract);
    }

    /**
     * @dev Set the price feed contract
     * @param _priceFeed Address of the price feed contract
     */
    function setPriceFeed(address _priceFeed) external onlyRole(Constants.ADMIN_ROLE) {
        if (_priceFeed == address(0)) revert ZeroComponentAddress();
        priceFeed = ITokenPriceFeed(_priceFeed);
        emit ComponentSet("PriceFeed", _priceFeed);
    }

    /**
     * @dev Set the tier manager contract
     * @param _tierManager Address of the tier manager contract
     */
    function setTierManager(address _tierManager) external onlyRole(Constants.ADMIN_ROLE) {
        if (_tierManager == address(0)) revert ZeroComponentAddress();
        tierManager = ITierManager(_tierManager);
        emit ComponentSet("TierManager", _tierManager);
    }

    /**
     * @dev Set the emergency manager contract
     * @param _emergencyManager Address of the emergency manager contract
     */
    function setEmergencyManager(address _emergencyManager) external onlyRole(Constants.ADMIN_ROLE) {
        if (_emergencyManager == address(0)) revert ZeroComponentAddress();
        emergencyManager = IEmergencyManager(_emergencyManager);
        emit ComponentSet("EmergencyManager", _emergencyManager);
    }

    /**
     * @dev Set the presale start and end times
     * @param _start Start timestamp
     * @param _end End timestamp
     */
    function setPresaleTimes(uint64 _start, uint64 _end) external onlyRole(Constants.ADMIN_ROLE) {
        if (_end <= _start) revert InvalidPresaleTimes(_start, _end);
        presaleStart = _start;
        presaleEnd = _end;
        emit PresaleTimesUpdated(_start, _end);
    }

    /**
     * @dev Purchase tokens with any supported payment token
     * @param _tierId Tier to purchase from
     * @param _paymentToken Payment token address
     * @param _paymentAmount Amount of payment tokens
     */
    function purchaseWithToken(
        uint8 _tierId,
        address _paymentToken,
        uint256 _paymentAmount
    ) public nonReentrant whenNotPaused {
        // Validate payment token
        if (!priceFeed.isTokenSupported(_paymentToken)) revert UnsupportedPaymentToken(_paymentToken);

        // Convert payment to USD
        uint256 usdAmount = priceFeed.convertTokenToUsd(_paymentToken, _paymentAmount);

        // Check rate limit
        _validateRateLimit(usdAmount);

        // Validate presale status and tier
        if (block.timestamp < presaleStart || block.timestamp > presaleEnd) revert PresaleNotActive();

        // Fetch tier details
        ITierManager.PresaleTier memory tier = tierManager.getTierDetails(_tierId);
        if (!tier.isActive) revert TierNotActive(_tierId);

        // Validate purchase amount in USD
        if (usdAmount < tier.minPurchase) revert BelowMinPurchase(usdAmount, tier.minPurchase);
        if (usdAmount > tier.maxPurchase) revert AboveMaxPurchase(usdAmount, tier.maxPurchase);

        // Check user tier limits
        uint256 userTierTotal = purchases[msg.sender].tierAmounts.length > _tierId
            ? purchases[msg.sender].tierAmounts[_tierId] + usdAmount
            : usdAmount;
        if (userTierTotal > tier.maxPurchase) revert ExceedsMaxTierPurchase(userTierTotal, tier.maxPurchase);

        // Calculate TEACH token amount based on USD value
        uint256 tokenAmount = (usdAmount * 10**18) / tier.price;

        // Check total address limit
        if (addressTokensPurchased[msg.sender] + tokenAmount > maxTokensPerAddress)
            revert ExceedsMaxTokensPerAddress(addressTokensPurchased[msg.sender] + tokenAmount, maxTokensPerAddress);

        // Check if there's enough allocation left
        if (tier.sold + tokenAmount > tier.allocation)
            revert InsufficientTierAllocation(tokenAmount, tier.allocation - tier.sold);

        // Calculate bonus
        uint8 bonusPercentage = tierManager.getCurrentBonus(_tierId);
        uint256 bonusTokenAmount = 0;

        if (bonusPercentage > 0) {
            bonusTokenAmount = (tokenAmount * bonusPercentage) / 100;
        }

        // Total tokens
        uint256 totalTokenAmount = tokenAmount + bonusTokenAmount;

        // Update tier data
        tierManager.recordPurchase(_tierId, tokenAmount);

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens += tokenAmount;
        userPurchase.bonusAmount += bonusTokenAmount;
        userPurchase.usdAmount += usdAmount;
        userPurchase.paymentsByToken[_paymentToken] += _paymentAmount;

        // Ensure tierAmounts array is long enough
        while (userPurchase.tierAmounts.length <= _tierId) {
            userPurchase.tierAmounts.push(0);
        }
        userPurchase.tierAmounts[_tierId] += usdAmount;

        // Record payment collection
        priceFeed.recordPaymentCollection(_paymentToken, _paymentAmount);

        // Transfer payment tokens to treasury
        ERC20Upgradeable paymentTokenErc20 = ERC20Upgradeable(_paymentToken);
        bool transferSuccess = paymentTokenErc20.transferFrom(msg.sender, treasury, _paymentAmount);
        if (!transferSuccess) revert PaymentTransferFailed();

        // Update user tokens purchased
        addressTokensPurchased[msg.sender] += totalTokenAmount;

        // Create vesting schedule if needed
        if (!userPurchase.vestingCreated) {
            (uint8 tgePercentage, uint16 vestingMonths) = tierManager.getTierVestingParams(_tierId);

            uint256 scheduleId = vestingContract.createLinearVestingSchedule(
                msg.sender,
                totalTokenAmount,
                0, // No cliff
                vestingMonths * 30 days,
                tgePercentage,
                ITeachTokenVesting.BeneficiaryGroup.PUBLIC_SALE,
                false // Not revocable
            );
            userPurchase.vestingScheduleId = scheduleId;
            userPurchase.vestingCreated = true;
        }

        // Update rate limit tracking
        lastPurchaseTime[msg.sender] = block.timestamp;

        // Record purchase with StabilityFund
        if (address(registry) != address(0) &&
            registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            try this.recordPurchaseInStabilityFund(msg.sender, tokenAmount, usdAmount) {}
            catch (bytes memory reason) {
                emit StabilityFundRecordingFailed(msg.sender, string(reason));
            }
        }

        // Emit event
        emit PurchaseWithToken(
            msg.sender,
            _tierId,
            _paymentToken,
            _paymentAmount,
            tokenAmount,
            usdAmount
        );
    }

    /**
     * @dev Purchase tokens in a specific tier with the default stablecoin
     * @param _tierId Tier to purchase from
     * @param _usdAmount USD amount to spend (scaled by 1e6)
     */
    function purchase(uint8 _tierId, uint256 _usdAmount) external nonReentrant whenNotPaused purchaseRateLimit(_usdAmount) {
        // Get supported payment tokens
        address[] memory supportedTokens = priceFeed.getSupportedPaymentTokens();

        // Default to first token (usually stablecoin)
        address defaultToken = supportedTokens.length > 0 ? supportedTokens[0] : address(0);
        require(defaultToken != address(0), "No payment tokens configured");

        // Convert USD to default token amount
        uint256 paymentAmount = priceFeed.convertUsdToToken(defaultToken, _usdAmount);

        // Call multi-token purchase function
        purchaseWithToken(_tierId, defaultToken, paymentAmount);
    }

    /**
     * @dev Validate rate limiting based on USD amount
     * @param _usdAmount USD amount to validate
     */
    function _validateRateLimit(uint256 _usdAmount) internal view {
        address msgr = msg.sender;
        uint256 userLastPurchase = lastPurchaseTime[msgr];

        if (userLastPurchase > 0) {
            if (block.timestamp < userLastPurchase + minTimeBetweenPurchases) {
                revert PurchaseTooSoon(userLastPurchase + minTimeBetweenPurchases, block.timestamp);
            }
        }

        if (_usdAmount > maxPurchaseAmount) {
            revert AboveMaxPurchase(_usdAmount, maxPurchaseAmount);
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
    ) external returns (bool success) {
        if (msg.sender != address(this)) revert UnauthorizedCaller();

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
     * @dev Complete Token Generation Event, allowing initial token claims
     */
    function completeTGE() external onlyRole(Constants.ADMIN_ROLE) whenNotPaused {
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
        if (userPurchase.vestingScheduleId == 0) return 0;

        // Get claimable amount from vesting contract
        claimable = vestingContract.calculateClaimableAmount(userPurchase.vestingScheduleId);

        return claimable;
    }

    /**
     * @dev Withdraw available tokens based on vesting schedule
     */
    function withdrawTokens() external nonReentrant whenNotPaused {
        if (!tgeCompleted) revert TGENotCompleted();

        Purchase storage userPurchase = purchases[msg.sender];
        uint256 scheduleId = userPurchase.vestingScheduleId;
        if (scheduleId == 0) revert NoTokensToWithdraw();

        // Claim tokens through vesting contract
        uint256 claimed = vestingContract.claimTokens(scheduleId);
        if (claimed == 0) revert NoTokensToWithdraw();

        // Record this claim event
        claimHistory[msg.sender].push(ClaimEvent({
            amount: uint128(claimed),
            timestamp: uint64(block.timestamp)
        }));

        emit TokensWithdrawn(msg.sender, claimed);
    }

    /**
     * @dev Set the maximum tokens that can be purchased by a single address
     * @param _maxTokens The maximum number of tokens
     */
    function setMaxTokensPerAddress(uint96 _maxTokens) external onlyRole(Constants.ADMIN_ROLE) {
        require(_maxTokens > 0, "Max tokens must be positive");
        maxTokensPerAddress = _maxTokens;
    }

    /**
     * @dev Set purchase rate limits
     * @param _minTimeBetweenPurchases Minimum time between purchases
     * @param _maxPurchaseAmount Maximum purchase amount in USD
     */
    function setPurchaseRateLimits(
        uint32 _minTimeBetweenPurchases,
        uint256 _maxPurchaseAmount
    ) external onlyRole(Constants.ADMIN_ROLE) {
        minTimeBetweenPurchases = _minTimeBetweenPurchases;
        maxPurchaseAmount = _maxPurchaseAmount;
    }

    /**
     * @dev Toggle auto-compound feature for a user
     * @param _enabled Whether to enable auto-compounding
     */
    function setAutoCompound(bool _enabled) external {
        autoCompoundEnabled[msg.sender] = _enabled;
        emit AutoCompoundUpdated(msg.sender, _enabled);
    }

    /**
     * @dev In case of critical emergency, allows users to withdraw their USDC
     */
    function emergencyWithdraw() external nonReentrant {
        require(emergencyManager.getEmergencyState() == IEmergencyManager.EmergencyState.CRITICAL_EMERGENCY,
            "Not in critical emergency");
        require(!emergencyManager.isEmergencyWithdrawalProcessed(msg.sender), "Already processed");

        // Calculate refundable amount
        Purchase storage userPurchase = purchases[msg.sender];
        uint256 refundAmount = userPurchase.usdAmount;

        if (refundAmount > 0) {
            // Get supported payment tokens
            address[] memory supportedTokens = priceFeed.getSupportedPaymentTokens();

            // Mark as processed via emergency manager
            emergencyManager.processEmergencyWithdrawal(msg.sender, refundAmount);

            // Find a supported token to refund with
            address refundToken = supportedTokens.length > 0 ? supportedTokens[0] : address(0);
            require(refundToken != address(0), "No refund token available");

            // Calculate token amount to refund
            uint256 tokenRefundAmount = priceFeed.convertUsdToToken(refundToken, refundAmount);

            // Transfer funds from treasury
            ERC20Upgradeable(refundToken).transferFrom(treasury, msg.sender, tokenRefundAmount);
        }
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        require(_token != address(token), "Cannot recover tokens");
        uint256 balance = ERC20Upgradeable(_token).balanceOf(address(this));
        require(balance > 0, "No tokens to recover");
        require(ERC20Upgradeable(_token).transfer(owner(), balance), "Token recovery failed");
    }

    /**
     * @dev Get user's purchase details including payments by token
     * @param _user User address
     * @param _token Payment token address (use address(0) for total USD)
     * @return tokenAmount Total token amount purchased
     * @return usdAmount Total USD equivalent
     * @return paymentAmount Payment token amount for the specified token
     */
    function getUserPurchaseDetails(address _user, address _token) external view returns (
        uint256 tokenAmount,
        uint256 usdAmount,
        uint256 paymentAmount
    ) {
        Purchase storage userPurchase = purchases[_user];
        tokenAmount = userPurchase.tokens + userPurchase.bonusAmount;
        usdAmount = userPurchase.usdAmount;

        if (_token == address(0)) {
            // Return total USD amount for all tokens
            paymentAmount = usdAmount;
        } else {
            // Return specific token payment amount
            paymentAmount = userPurchase.paymentsByToken[_token];
        }

        return (tokenAmount, usdAmount, paymentAmount);
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
     * @dev Get the count of user's claim events
     * @param _user User address
     * @return count Number of claim events
     */
    function getClaimCount(address _user) external view returns (uint256) {
        return claimHistory[_user].length;
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
     */
    function updateContractReferences() external {
        if (address(registry) == address(0)) return;

        // Update token reference
        if (registry.isContractActive(Constants.TOKEN_NAME)) {
            address tokenAddr = registry.getContractAddress(Constants.TOKEN_NAME);
            if (tokenAddr != address(0) && tokenAddr != address(token)) {
                address oldToken = address(token);
                token = ERC20Upgradeable(tokenAddr);
                emit ContractReferenceUpdated(Constants.TOKEN_NAME, oldToken, tokenAddr);
            }
        }
    }
}