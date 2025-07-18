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
    function getCurrentTier() external view returns (uint8);
    function checkAndAdvanceTier() external;
    function tierCount() external view returns (uint8);
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

interface ITokenVesting {
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
    ITokenVesting public vestingContract;

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
    bool internal paused;
    
    // Presale timing
    uint64 public presaleStart;
    uint64 public presaleEnd;

    // TGE status
    bool public tgeCompleted;

    // USD price scaling factor (6 decimal places)
    uint256 public constant PRICE_DECIMALS = 1e6;

    bool public tgeAborted;
    
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

    mapping(address => uint256[]) public userVestingSchedules;
    
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
    event ExternalCallFailed(string method, address target);
    event TokenSwept(uint256 amount);
    event TGECompleted(uint256 timestamp);
    event TokensRecovered(address indexed token, uint256 amount);
    event RefundIssued(address indexed user, uint256 usdAmount, address token, uint256 tokenAmount);

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
    error InvalidContract();
    error TGEAlreadyCompleted();
    error PresaleStillActive();
    error TGEAborted();
    error MaxTokensMustBePositive();
    error NotInCriticalEmergency();
    error AlreadyProcessed();
    error NoRefundTokenAvailable();
    error CannotRecoverSaleToken();
    error NoTokensToRecover();
    error TokenRecoveryFailed();
    error CannotSweepBeforeTGE();
    error TokenNotSet();
    error NothingToSweep();
    error TransferFailed();
    error RefundsNotAllowed();
    error NoPurchaseFound();
    error NoRefundTokenConfigured();
    
    modifier onlySelf() {
        if (msg.sender != address(this)) revert UnauthorizedCaller();
        _;
    }
    
    modifier whenNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if (systemPaused) revert SystemPaused();
            } catch {
                // If registry call fails, fall back to local pause state
                IEmergencyManager.EmergencyState state = emergencyManager.getEmergencyState();
                require(state == IEmergencyManager.EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
            }
        } else {
            IEmergencyManager.EmergencyState state = emergencyManager.getEmergencyState();
            require(state == IEmergencyManager.EmergencyState.NORMAL, "TokenCrowdSale: contract is paused");
        }
        _;
    }

    /**
     * @dev Initializer function to replace constructor 
     * @param _treasury Address to receive presale funds
     */
    function initialize(
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
        vestingContract = ITokenVesting(_vestingContract);
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
     * @param _paymentToken Payment token address
     * @param _paymentAmount Amount of payment tokens
     */
    function purchaseWithToken(
        address _paymentToken,
        uint256 _paymentAmount
    ) public nonReentrant whenNotPaused {
        // Validate payment token
        if (!priceFeed.isTokenSupported(_paymentToken)) revert UnsupportedPaymentToken(_paymentToken);

        // Convert payment to USD
        uint256 usdAmount = priceFeed.convertTokenToUsd(_paymentToken, _paymentAmount);

        _enforcePurchaseRateLimit(msg.sender, usdAmount);
        
        // Validate presale status and tier
        if (block.timestamp < presaleStart || block.timestamp > presaleEnd) revert PresaleNotActive();

        tierManager.checkAndAdvanceTier();
        uint8 tierId = tierManager.getCurrentTier();
        // Fetch tier details
        ITierManager.PresaleTier memory tier = tierManager.getTierDetails(tierId);
        if (!tier.isActive) revert TierNotActive(tierId);

        // Validate purchase amount in USD
        if (usdAmount < tier.minPurchase) revert BelowMinPurchase(usdAmount, tier.minPurchase);
        if (usdAmount > tier.maxPurchase) revert AboveMaxPurchase(usdAmount, tier.maxPurchase);

        // Check user tier limits
        uint256 userTierTotal = purchases[msg.sender].tierAmounts.length > tierId
            ? purchases[msg.sender].tierAmounts[tierId] + usdAmount
            : usdAmount;
        if (userTierTotal > tier.maxPurchase) revert ExceedsMaxTierPurchase(userTierTotal, tier.maxPurchase);

        // Calculate token amount based on USD value
        uint256 tokenAmount = (usdAmount * 10**18) / tier.price;

        // Check total address limit
        if (addressTokensPurchased[msg.sender] + tokenAmount > maxTokensPerAddress)
            revert ExceedsMaxTokensPerAddress(addressTokensPurchased[msg.sender] + tokenAmount, maxTokensPerAddress);

        // Check if there's enough allocation left
        if (tier.sold + tokenAmount > tier.allocation)
            revert InsufficientTierAllocation(tokenAmount, tier.allocation - tier.sold);

        // Calculate bonus
        uint8 bonusPercentage = tierManager.getCurrentBonus(tierId);
        uint256 bonusTokenAmount = 0;

        if (bonusPercentage > 0) {
            bonusTokenAmount = (tokenAmount * bonusPercentage) / 100;
        }

        // Total tokens
        uint256 totalTokenAmount = tokenAmount + bonusTokenAmount;

        // Update tier data
        tierManager.recordPurchase(tierId, tokenAmount);

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens += tokenAmount;
        userPurchase.bonusAmount += bonusTokenAmount;
        userPurchase.usdAmount += usdAmount;
        userPurchase.paymentsByToken[_paymentToken] += _paymentAmount;

        // Ensure tierAmounts array is long enough
        while (userPurchase.tierAmounts.length <= tierId) {
            userPurchase.tierAmounts.push(0);
        }
        userPurchase.tierAmounts[tierId] += usdAmount;

        // Record payment collection
        priceFeed.recordPaymentCollection(_paymentToken, _paymentAmount);

        // Transfer payment tokens to treasury
        ERC20Upgradeable paymentTokenErc20 = ERC20Upgradeable(_paymentToken);
        bool transferSuccess = paymentTokenErc20.transferFrom(msg.sender, treasury, _paymentAmount);
        if (!transferSuccess) revert PaymentTransferFailed();

        // Update user tokens purchased
        addressTokensPurchased[msg.sender] += totalTokenAmount;

        // Create vesting schedule if needed
      
        (uint8 tgePercentage, uint16 vestingMonths) = tierManager.getTierVestingParams(tierId);

        uint256 scheduleId = vestingContract.createLinearVestingSchedule(
            msg.sender,
            totalTokenAmount,
            0, // No cliff
            vestingMonths * 30 days,
            tgePercentage,
            ITokenVesting.BeneficiaryGroup.PUBLIC_SALE,
            false // Not revocable
        );
        userPurchase.vestingScheduleId = scheduleId;
        userVestingSchedules[msg.sender].push(scheduleId);
        userPurchase.vestingCreated = true;
        
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
            tierId,
            _paymentToken,
            _paymentAmount,
            tokenAmount,
            usdAmount
        );
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
    ) external onlySelf nonReentrant returns (bool success) {
        if (msg.sender != address(this)) revert UnauthorizedCaller();

        // Verify registry and stability fund are properly set
        if (address(registry) == address(0) || !registry.isContractActive(Constants.STABILITY_FUND_NAME)) {
            emit StabilityFundRecordingFailed(_user, "Registry or StabilityFund not available");
            return false;
        }

        address stabilityFund = registry.getContractAddress(Constants.STABILITY_FUND_NAME);

        if (stabilityFund== address(0)) revert InvalidContract();

        // Call the recordTokenPurchase function in StabilityFund
        (success,) = stabilityFund.call(
            abi.encodeWithSignature(
                "recordTokenPurchase(address,uint256,uint256)",
                _user,
                _tokenAmount,
                _usdAmount
            )
        );

        if (!success) {
            emit ExternalCallFailed("recordTokenPurchase", stabilityFund);
        }
        
        return success;
    }

    /**
     * @dev Complete Token Generation Event, allowing initial token claims
     */
    function completeTGE() external onlyRole(Constants.ADMIN_ROLE) whenNotPaused {
        if (tgeCompleted) revert TGEAlreadyCompleted();
        if (block.timestamp <= presaleEnd) revert PresaleStillActive();
        tgeCompleted = true;
        emit TGECompleted(block.timestamp);
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
        if (tgeAborted) revert TGEAborted();
        
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
        if (_maxTokens == 0) revert MaxTokensMustBePositive();
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
        if (emergencyManager.getEmergencyState() != IEmergencyManager.EmergencyState.CRITICAL_EMERGENCY) revert NotInCriticalEmergency();
        if (emergencyManager.isEmergencyWithdrawalProcessed(msg.sender)) revert AlreadyProcessed();

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
            if (refundToken == address(0)) revert NoRefundTokenAvailable();

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
        if (_token == address(token)) revert CannotRecoverSaleToken();
        uint256 balance = ERC20Upgradeable(_token).balanceOf(address(this));
        if (balance == 0) revert NoTokensToRecover();
        if (!ERC20Upgradeable(_token).transfer(owner(), balance)) revert TokenRecoveryFailed();
        emit TokensRecovered(_token, balance);
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
    function updateContractReferences() external onlyRole(Constants.ADMIN_ROLE) {
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

        // Update vesting contract reference
        if (registry.isContractActive(Constants.VESTING_NAME)) {
            address vestingAddr = registry.getContractAddress(Constants.VESTING_NAME);
            if (vestingAddr != address(0) && vestingAddr != address(vestingContract)) {
                address oldVesting = address(vestingContract);
                vestingContract = ITokenVesting(vestingAddr);
                emit ContractReferenceUpdated(Constants.VESTING_NAME, oldVesting, vestingAddr);
            }
        }

        // Update tier manager reference
        if (registry.isContractActive(Constants.TIER_MANAGER)) {
            address tierAddr = registry.getContractAddress(Constants.TIER_MANAGER);
            if (tierAddr != address(0) && tierAddr != address(tierManager)) {
                address oldTierManager = address(tierManager);
                tierManager = ITierManager(tierAddr);
                emit ContractReferenceUpdated(Constants.TIER_MANAGER, oldTierManager, tierAddr);
            }
        }

        // Update emergency manager reference
        if (registry.isContractActive(Constants.EMERGENCY_MANAGER)) {
            address emergencyAddr = registry.getContractAddress(Constants.EMERGENCY_MANAGER);
            if (emergencyAddr != address(0) && emergencyAddr != address(emergencyManager)) {
                address oldEmergencyManager = address(emergencyManager);
                emergencyManager = IEmergencyManager(emergencyAddr);
                emit ContractReferenceUpdated(Constants.EMERGENCY_MANAGER, oldEmergencyManager, emergencyAddr);
            }
        }

        // Update price feed reference
        if (registry.isContractActive(Constants.TOKEN_PRICE_FEED_NAME)) {
            address priceFeedAddr = registry.getContractAddress(Constants.TOKEN_PRICE_FEED_NAME);
            if (priceFeedAddr != address(0) && priceFeedAddr != address(priceFeed)) {
                address oldPriceFeed = address(priceFeed);
                priceFeed = ITokenPriceFeed(priceFeedAddr);
                emit ContractReferenceUpdated(Constants.TOKEN_PRICE_FEED_NAME, oldPriceFeed, priceFeedAddr);
            }
        }
        else{
            revert("PF Contract inactive");
        }
    }

    function _enforcePurchaseRateLimit(address user, uint256 usdAmount) internal {
        uint256 userLast = lastPurchaseTime[user];

        if (userLast != 0 && block.timestamp < userLast + minTimeBetweenPurchases) {
            revert PurchaseTooSoon(userLast + minTimeBetweenPurchases, block.timestamp);
        }

        if (usdAmount > maxPurchaseAmount)
            revert AboveMaxPurchase(usdAmount, maxPurchaseAmount);

        lastPurchaseTime[user] = block.timestamp;
    }

    function sweepUnallocatedTokens() external onlyRole(Constants.ADMIN_ROLE) {
        if (!tgeCompleted) revert CannotSweepBeforeTGE();
        if (address(token) == address(0)) revert TokenNotSet();

        uint256 totalUnsold = 0;
        uint8 tierCount = tierManager.tierCount();

        for (uint8 i = 0; i < tierCount; i++) {
            uint256 remaining = tierManager.tokensRemainingInTier(i);
            totalUnsold += remaining;
        }

        if (totalUnsold == 0) revert NothingToSweep();

        // Mint or transfer remaining tokens to treasury
        if (!token.transfer(treasury, totalUnsold)) revert TransferFailed();

        emit TokenSwept(totalUnsold);
    }

    function abortTGE() external onlyRole(Constants.ADMIN_ROLE) {
        if (tgeCompleted) revert TGEAlreadyCompleted();
        tgeAborted = true;
    }

    function claimRefund() external nonReentrant {
        if (!tgeAborted) revert RefundsNotAllowed();

        Purchase storage p = purchases[msg.sender];
        if (p.usdAmount == 0) revert NoPurchaseFound();

        address[] memory supportedTokens = priceFeed.getSupportedPaymentTokens();
        address refundToken = supportedTokens.length > 0 ? supportedTokens[0] : address(0);
        if (refundToken == address(0)) revert NoRefundTokenConfigured();

        uint256 refundAmount = priceFeed.convertUsdToToken(refundToken, p.usdAmount);

        // Clear the user's purchase before transfer to prevent reentrancy issues
        delete purchases[msg.sender];
        addressTokensPurchased[msg.sender] = 0;

        if (!ERC20Upgradeable(refundToken).transferFrom(treasury, msg.sender, refundAmount)) revert TransferFailed();
        
        emit RefundIssued(msg.sender,p.usdAmount,refundToken,refundAmount);
    }

    /**
    * @dev Pauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function pause() public onlyRole(Constants.ADMIN_ROLE){
        paused=true;
    }

    /**
     * @dev Unpauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function unpause() public onlyRole(Constants.ADMIN_ROLE) {
        // Check if system is still paused before unpausing locally
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if (systemPaused) revert SystemPaused();
            } catch {
                // If registry call fails, proceed with unpause
            }
        }

        paused = false;
    }

    function _isContractPaused() internal override view returns (bool) {
        return paused;
    }
}