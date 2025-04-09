// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title VolatilityInsurance
 * @dev Contract that provides price volatility protection for TEACH token holders
 *      and maintains a reserve fund to stabilize token price during market fluctuations
 */
contract VolatilityInsurance is Ownable, ReentrancyGuard {
    using Math for uint256;
    
    // The TeachToken contract
    IERC20 public teachToken;
    
    // Stable coin used for insurance payouts (e.g., USDC)
    IERC20 public stableCoin;
    
    // Insurance fund parameters
    uint256 public reserveRatio;               // Target reserve ratio (10000 = 100%)
    uint256 public minReserveRatio;            // Minimum reserve ratio to maintain solvency
    uint256 public insuranceFeePercent;        // Fee percentage for insurance claims (100 = 1%)
    uint256 public volatilityThreshold;        // Threshold for volatility protection (500 = 5%)
    uint256 public cooldownPeriod;             // Cooldown between claims in seconds
    uint256 public maxClaimAmount;             // Maximum tokens for a single claim
    
    // Price oracle data
    uint256 public tokenPrice;                 // Current price in stable coin units (scaled by 1e18)
    uint256 public lastPriceUpdateTime;        // Timestamp of last price update
    address public priceOracle;                // Address authorized to update price
    
    // Insurance state
    uint256 public totalReserves;              // Total stable coin reserves
    uint256 public totalClaims;                // Total claims processed
    uint256 public totalClaimsPaid;            // Total value of claims paid
    
    // User data
    mapping(address => uint256) public lastClaimTime;   // Last claim timestamp for user
    mapping(address => uint256) public userClaimCount;  // Number of claims per user
    
    // Events
    event ReservesAdded(address indexed contributor, uint256 amount);
    event ReservesWithdrawn(address indexed recipient, uint256 amount);
    event InsuranceClaimed(address indexed user, uint256 teachAmount, uint256 stableAmount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event InsuranceParametersUpdated(uint256 reserveRatio, uint256 minReserveRatio, uint256 feePercent, uint256 threshold);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    
    /**
     * @dev Modifier to restrict certain functions to the price oracle
     */
    modifier onlyPriceOracle() {
        require(msg.sender == priceOracle, "VolatilityInsurance: not oracle");
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
     * @param _insuranceFeePercent Fee percentage for claims
     * @param _volatilityThreshold Threshold for volatility protection
     * @param _cooldownPeriod Cooldown between claims
     * @param _maxClaimAmount Maximum tokens for a single claim
     */
    constructor(
        address _teachToken,
        address _stableCoin,
        address _priceOracle,
        uint256 _initialPrice,
        uint256 _reserveRatio,
        uint256 _minReserveRatio,
        uint256 _insuranceFeePercent,
        uint256 _volatilityThreshold,
        uint256 _cooldownPeriod,
        uint256 _maxClaimAmount
    ) Ownable(msg.sender) {
        require(_teachToken != address(0), "VolatilityInsurance: zero teach token address");
        require(_stableCoin != address(0), "VolatilityInsurance: zero stable coin address");
        require(_priceOracle != address(0), "VolatilityInsurance: zero oracle address");
        require(_initialPrice > 0, "VolatilityInsurance: zero initial price");
        require(_reserveRatio > _minReserveRatio, "VolatilityInsurance: invalid reserve ratios");
        require(_insuranceFeePercent <= 3000, "VolatilityInsurance: fee too high");
        require(_volatilityThreshold > 0, "VolatilityInsurance: zero threshold");
        
        teachToken = IERC20(_teachToken);
        stableCoin = IERC20(_stableCoin);
        priceOracle = _priceOracle;
        tokenPrice = _initialPrice;
        lastPriceUpdateTime = block.timestamp;
        reserveRatio = _reserveRatio;
        minReserveRatio = _minReserveRatio;
        insuranceFeePercent = _insuranceFeePercent;
        volatilityThreshold = _volatilityThreshold;
        cooldownPeriod = _cooldownPeriod;
        maxClaimAmount = _maxClaimAmount;
    }
    
    /**
     * @dev Updates the token price (only callable by oracle)
     * @param _newPrice New token price in stable coin units (scaled by 1e18)
     */
    function updatePrice(uint256 _newPrice) external onlyPriceOracle {
        require(_newPrice > 0, "VolatilityInsurance: zero price");
        
        emit PriceUpdated(tokenPrice, _newPrice);
        
        tokenPrice = _newPrice;
        lastPriceUpdateTime = block.timestamp;
    }
    
    /**
     * @dev Adds stable coins to the insurance reserves
     * @param _amount Amount of stable coins to add
     */
    function addReserves(uint256 _amount) external nonReentrant {
        require(_amount > 0, "VolatilityInsurance: zero amount");
        
        // Transfer stable coins to contract
        require(stableCoin.transferFrom(msg.sender, address(this), _amount), "VolatilityInsurance: transfer failed");
        
        totalReserves += _amount;
        
        emit ReservesAdded(msg.sender, _amount);
    }
    
    /**
     * @dev Withdraws stable coins from reserves (only owner)
     * @param _amount Amount of stable coins to withdraw
     */
    function withdrawReserves(uint256 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "VolatilityInsurance: zero amount");
        
        // Calculate maximum withdrawable amount based on min reserve ratio
        uint256 totalSupplyValue = (teachToken.totalSupply() * tokenPrice) / 1e18;
        uint256 minReserveRequired = (totalSupplyValue * minReserveRatio) / 10000;
        
        uint256 excessReserves = 0;
        if (totalReserves > minReserveRequired) {
            excessReserves = totalReserves - minReserveRequired;
        }
        
        require(_amount <= excessReserves, "VolatilityInsurance: exceeds available reserves");
        
        totalReserves -= _amount;
        
        // Transfer stable coins from contract
        require(stableCoin.transfer(msg.sender, _amount), "VolatilityInsurance: transfer failed");
        
        emit ReservesWithdrawn(msg.sender, _amount);
    }
    
    /**
     * @dev Claims insurance for token price protection
     * @param _teachAmount Amount of TEACH tokens to insure
     * @param _minReturn Minimum stable coin amount to receive
     */
    function claimInsurance(uint256 _teachAmount, uint256 _minReturn) external nonReentrant {
        require(_teachAmount > 0, "VolatilityInsurance: zero amount");
        require(_teachAmount <= maxClaimAmount, "VolatilityInsurance: exceeds max claim");
        require(block.timestamp >= lastClaimTime[msg.sender] + cooldownPeriod, "VolatilityInsurance: cooldown period");
        
        // Calculate price drop percentage (scaled by 10000)
        uint256 buyPrice = getUserBuyPrice(msg.sender);
        require(buyPrice > 0, "VolatilityInsurance: no buy price");
        
        uint256 currentPrice = tokenPrice;
        require(currentPrice < buyPrice, "VolatilityInsurance: price not decreased");
        
        uint256 priceDrop = ((buyPrice - currentPrice) * 10000) / buyPrice;
        require(priceDrop >= volatilityThreshold, "VolatilityInsurance: below threshold");
        
        // Calculate insurance payout
        uint256 teachValue = (_teachAmount * currentPrice) / 1e18;
        uint256 insuranceValue = (_teachAmount * (buyPrice - currentPrice)) / 1e18;
        uint256 fee = (insuranceValue * insuranceFeePercent) / 10000;
        uint256 payoutAmount = insuranceValue - fee;
        
        require(payoutAmount >= _minReturn, "VolatilityInsurance: below min return");
        require(payoutAmount <= totalReserves, "VolatilityInsurance: insufficient reserves");
        
        // Update state
        totalReserves -= payoutAmount;
        totalClaims += 1;
        totalClaimsPaid += payoutAmount;
        lastClaimTime[msg.sender] = block.timestamp;
        userClaimCount[msg.sender] += 1;
        
        // Transfer tokens from user to contract
        require(teachToken.transferFrom(msg.sender, address(this), _teachAmount), "VolatilityInsurance: teach transfer failed");
        
        // Transfer stable coins to user
        require(stableCoin.transfer(msg.sender, payoutAmount), "VolatilityInsurance: stable transfer failed");
        
        emit InsuranceClaimed(msg.sender, _teachAmount, payoutAmount);
    }
    
    /**
     * @dev Get the reserve ratio health of the insurance fund
     * @return uint256 Current reserve ratio (10000 = 100%)
     */
    function getReserveRatioHealth() public view returns (uint256) {
        uint256 totalSupplyValue = (teachToken.totalSupply() * tokenPrice) / 1e18;
        
        if (totalSupplyValue == 0) {
            return 10000; // 100% if no tokens
        }
        
        return (totalReserves * 10000) / totalSupplyValue;
    }
    
    /**
     * @dev Simulates an insurance claim without executing it
     * @param _teachAmount Amount of TEACH tokens to insure
     * @param _user Address of the user
     * @return claimable Whether the insurance is claimable
     * @return payoutAmount Estimated payout amount in stable coins
     * @return reason Reason code if not claimable (0 = claimable)
     */
    function simulateClaim(uint256 _teachAmount, address _user) external view returns (
        bool claimable,
        uint256 payoutAmount,
        uint8 reason
    ) {
        // Check cooldown
        if (block.timestamp < lastClaimTime[_user] + cooldownPeriod) {
            return (false, 0, 1); // Cooldown period
        }
        
        // Check amount
        if (_teachAmount == 0) {
            return (false, 0, 2); // Zero amount
        }
        
        if (_teachAmount > maxClaimAmount) {
            return (false, 0, 3); // Exceeds max claim
        }
        
        // Check price drop
        uint256 buyPrice = getUserBuyPrice(_user);
        if (buyPrice == 0) {
            return (false, 0, 4); // No buy price
        }
        
        uint256 currentPrice = tokenPrice;
        if (currentPrice >= buyPrice) {
            return (false, 0, 5); // Price not decreased
        }
        
        uint256 priceDrop = ((buyPrice - currentPrice) * 10000) / buyPrice;
        if (priceDrop < volatilityThreshold) {
            return (false, 0, 6); // Below threshold
        }
        
        // Calculate insurance payout
        uint256 insuranceValue = (_teachAmount * (buyPrice - currentPrice)) / 1e18;
        uint256 fee = (insuranceValue * insuranceFeePercent) / 10000;
        payoutAmount = insuranceValue - fee;
        
        if (payoutAmount > totalReserves) {
            return (false, payoutAmount, 7); // Insufficient reserves
        }
        
        return (true, payoutAmount, 0);
    }
    
    /**
     * @dev Get the buy price for a user (to be implemented by marketplace integration)
     * @param _user Address of the user
     * @return uint256 User's average buy price
     */
    function getUserBuyPrice(address _user) public view returns (uint256) {
        // This is a simplified implementation
        // In a real-world scenario, this would pull data from token purchase history
        // For this example, we'll use a simple price estimate based on tokenPrice
        
        // This logic would be replaced with actual user purchase data
        return tokenPrice + ((tokenPrice * volatilityThreshold) / 10000);
    }
    
    /**
     * @dev Updates insurance parameters (only owner)
     * @param _reserveRatio New target reserve ratio
     * @param _minReserveRatio New minimum reserve ratio
     * @param _insuranceFeePercent New fee percentage for claims
     * @param _volatilityThreshold New threshold for protection
     */
    function updateInsuranceParameters(
        uint256 _reserveRatio,
        uint256 _minReserveRatio,
        uint256 _insuranceFeePercent,
        uint256 _volatilityThreshold
    ) external onlyOwner {
        require(_reserveRatio > _minReserveRatio, "VolatilityInsurance: invalid reserve ratios");
        require(_insuranceFeePercent <= 3000, "VolatilityInsurance: fee too high");
        require(_volatilityThreshold > 0, "VolatilityInsurance: zero threshold");
        
        reserveRatio = _reserveRatio;
        minReserveRatio = _minReserveRatio;
        insuranceFeePercent = _insuranceFeePercent;
        volatilityThreshold = _volatilityThreshold;
        
        emit InsuranceParametersUpdated(_reserveRatio, _minReserveRatio, _insuranceFeePercent, _volatilityThreshold);
    }
    
    /**
     * @dev Updates claim parameters (only owner)
     * @param _cooldownPeriod New cooldown period
     * @param _maxClaimAmount New maximum claim amount
     */
    function updateClaimParameters(
        uint256 _cooldownPeriod,
        uint256 _maxClaimAmount
    ) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
        maxClaimAmount = _maxClaimAmount;
    }
    
    /**
     * @dev Updates the price oracle address
     * @param _newOracle New price oracle address
     */
    function updatePriceOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "VolatilityInsurance: zero oracle address");
        
        emit PriceOracleUpdated(priceOracle, _newOracle);
        
        priceOracle = _newOracle;
    }
}