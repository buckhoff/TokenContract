// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TeachTokenPresale
 * @dev Multi-tier presale contract for TEACH Token
 */
contract TeachTokenPresale is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

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

    uint256 public currentTier = 0;
    uint256 public tierCount;
    mapping(uint256 => uint256) public maxTokensForTier;

    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    // Payment token (USDC)
    IERC20 public paymentToken;

    // TEACH token contract
    IERC20 public teachToken;

    // Presale tiers
    PresaleTier[] public tiers;

    // Mapping from user address to purchase info
    mapping(address => Purchase) public purchases;

    // Whitelist for early tiers
    mapping(address => bool) public whitelist;
    
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

    // Events
    event TierPurchase(address indexed buyer, uint256 tierId, uint256 tokenAmount, uint256 usdAmount);
    event TierStatusChanged(uint256 tierId, bool isActive);
    event TokensWithdrawn(address indexed user, uint256 amount);
    event PresaleTimesUpdated(uint256 newStart, uint256 newEnd);
    event WhitelistUpdated(address indexed user, bool status);
    event TierDeadlineUpdated(uint256 indexed tier, uint256 deadline);
    event TierAdvanced(uint256 indexed newTier);
    event TierExtended(uint256 indexed tier, uint256 newDeadline);
    
    /**
     * @dev Constructor to initialize the presale contract
     * @param _paymentToken Address of the payment token (USDC)
     * @param _treasury Address to receive presale funds
     */
    constructor(IERC20 _paymentToken, address _treasury) {
        paymentToken = _paymentToken;
        treasury = _treasury;

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
        maxTokensPerAddress = 1_000_000 * 10**18; // 1M tokens by default
    }

    function addRecorder(address _recorder) external onlyOwner {
        _grantRole(RECORDER_ROLE, _recorder);
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "PlatformInsurance: caller doesn't have role");
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        // Implement role checking logic here
        // For simplicity, you could use a mapping:
        return roleMembership[role][account];
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
    ) external onlyRole(RECORDER_ROLE) {
        userTotalTokens[_user] += _tokenAmount;
        userTotalValue[_user] += _purchaseValue;
    }
    
    /**
     * @dev Set the TEACH token address after deployment
     * @param _teachToken Address of the TEACH token contract
     */
    function setTeachToken(IERC20 _teachToken) external onlyOwner {
        require(address(teachToken) == address(0), "TeachToken already set");
        teachToken = _teachToken;
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
     * @dev Add or remove an address from the whitelist
     * @param _user Address to modify
     * @param _status New whitelist status
     */
    function updateWhitelist(address _user, bool _status) external onlyOwner {
        whitelist[_user] = _status;
        emit WhitelistUpdated(_user, _status);
    }

    /**
     * @dev Add multiple addresses to the whitelist
     * @param _users Addresses to whitelist
     */
    function batchWhitelist(address[] calldata _users) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            whitelist[_users[i]] = true;
            emit WhitelistUpdated(_users[i], true);
        }
    }

    /**
     * @dev Purchase tokens in a specific tier
     * @param _tierId Tier to purchase from
     * @param _usdAmount USD amount to spend (scaled by 1e6)
     */
    function purchase(uint256 _tierId, uint256 _usdAmount) external nonReentrant whenNotPaused {
        require(block.timestamp >= presaleStart && block.timestamp <= presaleEnd, "Presale not active");
        require(_tierId < tiers.length, "Invalid tier ID");
        PresaleTier storage tier = tiers[_tierId];
        require(tier.isActive, "Tier not active");

        // For earlier tiers (0-3), require whitelist
        if (_tierId <= 3) {
            require(whitelist[msg.sender], "Not whitelisted for this tier");
        }

        // Validate purchase amount
        require(_usdAmount >= tier.minPurchase, "Below minimum purchase");
        require(_usdAmount <= tier.maxPurchase, "Above maximum purchase");

        // Check if user's total purchase would exceed max
        uint256 userTierTotal = purchases[msg.sender].tierAmounts.length > _tierId
            ? purchases[msg.sender].tierAmounts[_tierId] + _usdAmount
            : _usdAmount;
        require(userTierTotal <= tier.maxPurchase, "Would exceed max tier purchase");

        // Calculate token amount
        uint256 tokenAmount = _usdAmount.mul(10**18).div(tier.price);

        // Check total cap per address
        require(addressTokensPurchased[msg.sender] + uint96(tokenAmount) <= maxTokensPerAddress, "Exceeds max tokens per address");

        // Check if there's enough allocation left
        require(tier.sold.add(tokenAmount) <= tier.allocation, "Insufficient tier allocation");

        // Transfer payment tokens from user to treasury
        require(paymentToken.transferFrom(msg.sender, treasury, _usdAmount), "Payment failed");

        // Update tier data
        tier.sold = unint96(tier.sold.add(tokenAmount));

        // Update user purchase data
        Purchase storage userPurchase = purchases[msg.sender];
        userPurchase.tokens = uint96(userPurchase.tokens.add(tokenAmount));
        userPurchase.usdAmount = uint96(userPurchase.usdAmount.add(_usdAmount));

        // Update total tokens purchased by address
        addressTokensPurchased[msg.sender] += uint96(tokenAmount);
        
        // Ensure tierAmounts array is long enough
        while (userPurchase.tierAmounts.length <= _tierId) {
            userPurchase.tierAmounts.push(0);
        }
        userPurchase.tierAmounts[_tierId] = userPurchase.tierAmounts[_tierId].add(_usdAmount);

        emit TierPurchase(msg.sender, _tierId, tokenAmount, _usdAmount);
    }

    /**
     * @dev Complete Token Generation Event, allowing initial token claims
     */
    function completeTGE() external onlyOwner {
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

        for (uint256 tierId = 0; tierId < tiers.length; tierId++) {
            if (tierId >= userPurchase.tierAmounts.length || userPurchase.tierAmounts[tierId] == 0) continue;

            PresaleTier storage tier = tiers[tierId];
            uint256 tierTokens = userPurchase.tierAmounts[tierId].mul(10**18).div(tier.price);

            // TGE portion is immediately available
            uint256 tgeAmount = tierTokens.mul(tier.vestingTGE).div(100);

            // Calculate vested portion beyond TGE
            uint256 vestingAmount = tierTokens.sub(tgeAmount);
            uint256 vestedMonths = elapsedMonths > tier.vestingMonths ? tier.vestingMonths : elapsedMonths;
            uint256 vestedAmount = vestingAmount.mul(vestedMonths).div(tier.vestingMonths);

            totalClaimable = totalClaimable.add(tgeAmount).add(vestedAmount);
        }

        // Subtract already claimed tokens
        uint256 alreadyClaimed = totalPurchased.sub(userPurchase.tokens);
        return totalClaimable > alreadyClaimed ? totalClaimable.sub(alreadyClaimed) : 0;
    }

    /**
     * @dev Withdraw available tokens based on vesting schedule
     */
    function withdrawTokens() external nonReentrant {
        require(tgeCompleted, "TGE not completed yet");

        uint256 claimable = claimableTokens(msg.sender);
        require(claimable > 0, "No tokens available to claim");

        // Update user's token balance
        purchases[msg.sender].tokens = purchases[msg.sender].tokens.sub(claimable);

        // Transfer tokens to user
        require(teachToken.transfer(msg.sender, claimable), "Token transfer failed");

        emit TokensWithdrawn(msg.sender, claimable);
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(IERC20 _token) external onlyOwner {
        require(address(_token) != address(teachToken), "Cannot recover TEACH tokens");
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
    function pausePresale() external onlyOwner {
        paused = true;
    }

    /**
    * @dev Resume the presale
    */
    function resumePresale() external onlyOwner {
        paused = false;
    }
    
    
}