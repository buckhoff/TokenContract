// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

/**
 * @title TierManager
 * @dev Manages presale tiers, tier progress, and bonus calculations
 */
contract TierManager is
AccessControlEnumerableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Presale tier structure
    struct PresaleTier {
        uint96 price;         // Price in USD (scaled by 1e6)
        uint256 allocation;    // Total allocation for this tier
        uint256 sold;          // Amount sold in this tier
        uint256 minPurchase;   // Minimum purchase amount in USD
        uint256 maxPurchase;   // Maximum purchase amount in USD
        uint8 vestingTGE;     // Percentage released at TGE (scaled by 100)
        uint16 vestingMonths; // Remaining vesting period in months
        bool isActive;        // Whether this tier is currently active
    }

    // Bonus bracket information
    struct BonusBracket {
        uint96 fillPercentage;  // Fill percentage threshold (e.g., 25%, 50%, 75%, 100%)
        uint8 bonusPercentage;   // Bonus percentage for this bracket (scaled by 100)
    }

    // USD price scaling factor (6 decimal places)
    uint256 public constant PRICE_DECIMALS = 1e6;

    bool internal paused;
    
    // Crowdsale reference
    address public crowdsaleContract;

    // Current tier index
    uint8 public currentTier;
    uint8 public tierCount;

    // Tier limits
    mapping(uint8 => uint256) public maxTokensForTier;

    // Presale tiers
    PresaleTier[] public tiers;

    // Bonus brackets for each tier (4 brackets per tier)
    mapping(uint256 => BonusBracket[4]) public tierBonuses;

    // Timestamps for tier deadlines
    mapping(uint8 => uint64) public tierDeadlines;

    mapping(uint8 => uint64) public tierStartTimes;
    mapping(uint8 => uint64) public tierEndTimes;
    
    // Events
    event TierConfigured(uint256 tierId, uint256 price, uint256 allocation);
    event BonusConfigured(uint256 tierId, uint256 bracketId, uint256 fillPercentage, uint8 bonusPercentage);
    event TierStatusChanged(uint8 tierId, bool isActive);
    event TierSaleRecorded(uint8 tierId, uint256 tokenAmount);
    event TierDeadlineUpdated(uint8 indexed tier, uint64 deadline);
    event TierAdvanced(uint8 indexed newTier);
    event TierExtended(uint8 indexed tier, uint64 newDeadline);
    event CrowdsaleSet(address indexed crowdsale);

    // Errors
    error InvalidTierId(uint8 tierId);
    error TierNotActive(uint8 tierId);
    error TierPriceInvalid();
    error TierAllocationInvalid();
    error TierPurchaseLimitsInvalid();
    error InsufficientTierAllocation(uint256 requested, uint256 available);
    error UnauthorizedCaller();
    error TierAlreadyAdvanced();
    error DeadlineInPast(uint64 deadline);
    error InvalidBracketID();
    error InvalidFillPercentage();

    modifier onlyCrowdsale() {
        if (msg.sender != crowdsaleContract) revert UnauthorizedCaller();
        _;
    }

    /**
     * @dev Initializer function to replace constructor
     */
    function initialize() initializer public {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);

        // Initialize default tiers
        tiers = _createStandardTiers();
        tierCount = uint8(tiers.length);
        currentTier = 0;

        // Calculate tier maximums
        _calculateTierMaximums();

        // Setup default bonuses
        _setupDefaultBonuses();
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Set the crowdsale contract address
     * @param _crowdsale Address of the crowdsale contract
     */
    function setCrowdsale(address _crowdsale) external onlyRole(Constants.ADMIN_ROLE) {
        require(_crowdsale != address(0), "Zero address");
        crowdsaleContract = _crowdsale;
        emit CrowdsaleSet(_crowdsale);
    }

    /**
     * @dev Creates standard tier configurations for token presale
     */
    function _createStandardTiers() internal pure returns (PresaleTier[] memory) {
        PresaleTier[] memory stdTiers = new PresaleTier[](4);

        // Tier 1:
        stdTiers[0] = PresaleTier({
            price: 40000, // $0.04
            allocation: uint256(250_000_000) * 10**6, // 250M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        // Tier 2: 
        stdTiers[1] = PresaleTier({
            price: 60000, // $0.06
            allocation: uint256(375_000_000) * 10**6, // 375M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        // Tier 3: 
        stdTiers[2] = PresaleTier({
            price: 80000, // $0.08
            allocation: uint256(375_000_000) * 10**6, // 375M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        // Tier 4:
        stdTiers[3] = PresaleTier({
            price: 100000, // $0.10
            allocation: uint256(250_000_000) * 10**6, // 250M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        return stdTiers;
    }

    /**
     * @dev Calculate tier maximum values
     */
    function _calculateTierMaximums() internal {
        for (uint8 i = 0; i < tiers.length; i++) {
            uint256 tierTotal = 0;
            for (uint8 j = 0; j <= i; j++) {
                tierTotal += tiers[j].allocation;
            }
            maxTokensForTier[i] = tierTotal;
        }
    }

    /**
     * @dev Sets up the default bonus structure for all tiers
     */
    function _setupDefaultBonuses() internal {
        // Tier 1 bonuses
        tierBonuses[0][0] = BonusBracket({ fillPercentage: 25, bonusPercentage: 20 });  // 20% bonus
        tierBonuses[0][1] = BonusBracket({ fillPercentage: 50, bonusPercentage: 15 });  // 15% bonus
        tierBonuses[0][2] = BonusBracket({ fillPercentage: 75, bonusPercentage: 10 });  // 10% bonus
        tierBonuses[0][3] = BonusBracket({ fillPercentage: 100, bonusPercentage: 5 });  // 5% bonus

        // Tier 2 bonuses
        tierBonuses[1][0] = BonusBracket({ fillPercentage: 25, bonusPercentage: 18 });  // 18% bonus
        tierBonuses[1][1] = BonusBracket({ fillPercentage: 50, bonusPercentage: 13 });  // 13% bonus
        tierBonuses[1][2] = BonusBracket({ fillPercentage: 75, bonusPercentage: 8 });   // 8% bonus
        tierBonuses[1][3] = BonusBracket({ fillPercentage: 100, bonusPercentage: 3 });  // 3% bonus

        // Tier 3 bonuses
        tierBonuses[2][0] = BonusBracket({ fillPercentage: 25, bonusPercentage: 15 });  // 15% bonus
        tierBonuses[2][1] = BonusBracket({ fillPercentage: 50, bonusPercentage: 10 });  // 10% bonus
        tierBonuses[2][2] = BonusBracket({ fillPercentage: 75, bonusPercentage: 5 });   // 5% bonus
        tierBonuses[2][3] = BonusBracket({ fillPercentage: 100, bonusPercentage: 2 });  // 2% bonus

        // Tier 4 bonuses
        tierBonuses[3][0] = BonusBracket({ fillPercentage: 25, bonusPercentage: 12 });  // 12% bonus
        tierBonuses[3][1] = BonusBracket({ fillPercentage: 50, bonusPercentage: 8 });   // 8% bonus
        tierBonuses[3][2] = BonusBracket({ fillPercentage: 75, bonusPercentage: 4 });   // 4% bonus
        tierBonuses[3][3] = BonusBracket({ fillPercentage: 100, bonusPercentage: 1 });  // 1% bonus

        // Emit events for all configured bonuses
        for (uint8 i = 0; i < 4; i++) {
            for (uint8 j = 0; j < 4; j++) {
                emit BonusConfigured(i, j, tierBonuses[i][j].fillPercentage, tierBonuses[i][j].bonusPercentage);
            }
        }
    }

    /**
     * @dev Updates a tier configuration
     * @param _tierId ID of the tier to update
     * @param _price New price in USD (scaled by 1e6)
     * @param _allocation New allocation in tokens
     * @param _minPurchase New minimum purchase amount in USD
     * @param _maxPurchase New maximum purchase amount in USD
     */
    function configureTier(
        uint8 _tierId,
        uint96 _price,
        uint256 _allocation,
        uint256 _minPurchase,
        uint256 _maxPurchase
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        if (_price == 0) revert TierPriceInvalid();
        if(_allocation == 0) revert TierAllocationInvalid();
        if(_minPurchase == 0 || _maxPurchase < _minPurchase) revert TierPurchaseLimitsInvalid();

        tiers[_tierId].price = _price;
        tiers[_tierId].allocation = _allocation;
        tiers[_tierId].minPurchase = _minPurchase;
        tiers[_tierId].maxPurchase = _maxPurchase;

        // Recalculate tier maximums after update
        _calculateTierMaximums();

        emit TierConfigured(_tierId, _price, _allocation);
    }

    /**
     * @dev Activate or deactivate a specific tier
     * @param _tierId Tier ID to modify
     * @param _isActive New active status
     */
    function setTierStatus(uint8 _tierId, bool _isActive) external onlyRole(Constants.ADMIN_ROLE) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        tiers[_tierId].isActive = _isActive;
        emit TierStatusChanged(_tierId, _isActive);
    }

    /**
     * @dev Updates a bonus bracket for a tier
     * @param _tierId ID of the tier
     * @param _bracketId ID of the bracket (0-3)
     * @param _fillPercentage New fill percentage threshold
     * @param _bonusPercentage New bonus percentage
     */
    function configureBonusBracket(
        uint8 _tierId,
        uint8 _bracketId,
        uint96 _fillPercentage,
        uint8 _bonusPercentage
    ) external onlyRole(Constants.ADMIN_ROLE) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        if(_bracketId >= 4) revert InvalidBracketID();
        if(_fillPercentage == 0 || _fillPercentage > 100) revert InvalidFillPercentage();

        // Ensure each bracket has a higher fill percentage than the previous
        if (_bracketId > 0) {
            require(_fillPercentage > tierBonuses[_tierId][_bracketId - 1].fillPercentage,
                "Fill percentage must be higher than previous bracket");
        }

        tierBonuses[_tierId][_bracketId] = BonusBracket({
            fillPercentage: _fillPercentage,
            bonusPercentage: _bonusPercentage
        });

        emit BonusConfigured(_tierId, _bracketId, _fillPercentage, _bonusPercentage);
    }

    /**
     * @dev Record a token purchase in a tier
     * @param _tierId ID of the tier
     * @param _tokenAmount Amount of tokens purchased
     */
    function recordPurchase(uint8 _tierId, uint256 _tokenAmount) external onlyCrowdsale {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        PresaleTier storage tier = tiers[_tierId];

        if (!tier.isActive) revert TierNotActive(_tierId);

        // Check if there's enough allocation left
        if (tier.sold + _tokenAmount > tier.allocation)
            revert InsufficientTierAllocation(_tokenAmount, tier.allocation - tier.sold);

        // Update tier data
        tier.sold += _tokenAmount;

        emit TierSaleRecorded(_tierId, _tokenAmount);
    }

    /**
     * @dev Calculates the current bonus percentage for a tier
     * @param _tierId ID of the tier
     * @return Bonus percentage (scaled by 100)
     */
    function getCurrentBonus(uint8 _tierId) public view returns (uint8) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);

        PresaleTier memory tier = tiers[_tierId];

        // If nothing sold yet, return the first bracket bonus
        if (tier.sold == 0) {
            return tierBonuses[_tierId][0].bonusPercentage;
        }

        // Calculate fill percentage
        uint256 fillPercentage = (tier.sold * 100) / tier.allocation;

        // Find the appropriate bracket
        for (uint256 i = 3; i >= 0; i--) {
            if (fillPercentage >= tierBonuses[_tierId][i].fillPercentage) {
                return tierBonuses[_tierId][i].bonusPercentage;
            }

            // Special case for the first bracket
            if (i == 0) {
                return tierBonuses[_tierId][0].bonusPercentage;
            }
        }

        // Default to the first bracket (should never reach here)
        return tierBonuses[_tierId][0].bonusPercentage;
    }

    /**
     * @dev Calculate tokens remaining in a tier
     */
    function tokensRemainingInTier(uint8 _tierId) public view returns (uint96) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        PresaleTier storage tier = tiers[_tierId];
        if (tier.allocation <= tier.sold) {
            return 0;
        }
        return uint96(tier.allocation - tier.sold);
    }

    /**
     * @dev Calculate total tokens sold across all tiers
     */
    function totalTokensSold() public view returns (uint256 total) {
        total = 0;
        for (uint8 i = 0; i < tiers.length; i++) {
            total += tiers[i].sold;
        }
        return total;
    }

    /**
     * @dev Get tier details
     * @param _tierId ID of the tier to query
     * @return Tier structure with details
     */
    function getTierDetails(uint8 _tierId) external view returns (PresaleTier memory) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        return tiers[_tierId];
    }

    /**
     * @dev Get bonus bracket details
     * @param _tierId ID of the tier
     * @param _bracketId ID of the bracket (0-3)
     * @return Bonus bracket structure
     */
    function getTierBonus(uint8 _tierId, uint8 _bracketId) external view returns (BonusBracket memory) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        if (_bracketId >= 4) revert InvalidBracketID();
        return tierBonuses[_tierId][_bracketId];
    }

    /**
     * @dev Get current tier based on tokens sold and deadlines
     * @return Current tier index
     */
    function getCurrentTier() public view returns (uint8) {
        // First check if any tier deadlines have passed
        for (uint8 i = 0; i < tierCount; i++) {
            if (
                block.timestamp >= tierStartTimes[i] &&
                block.timestamp <= tierEndTimes[i]
            ) {
                if (tiers[i].sold >= tiers[i].allocation) {
                    // Sold out, skip to next
                    continue;
                }
                return i;
            }
        }

        // fallback: last tier if no time match
        return currentTier;
    }

    function checkAndAdvanceTier() external {
        uint8 newTier = getCurrentTier();
        if (newTier != currentTier) {
            currentTier = newTier;
            emit TierAdvanced(newTier);
        }
    }
    
    /**
     * @dev Set tier deadline
     * @param _tier Tier ID
     * @param _deadline New deadline timestamp
     */
    function setTierDeadline(uint8 _tier, uint64 _deadline) external onlyRole(Constants.ADMIN_ROLE) {
        if (_tier >= tiers.length) revert InvalidTierId(_tier);
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);
        if (tierDeadlines[_tier] != _deadline) {
            tierDeadlines[_tier] = _deadline;
            emit TierDeadlineUpdated(_tier, _deadline);
        }
    }

    /**
     * @dev Manually advance to the next tier
     */
    function advanceTier() external onlyRole(Constants.ADMIN_ROLE) {
        if (currentTier >= tierCount - 1) revert TierAlreadyAdvanced();
        currentTier++;
        emit TierAdvanced(currentTier);
    }

    /**
     * @dev Extend current tier deadline
     * @param _newDeadline New deadline timestamp
     */
    function extendTier(uint64 _newDeadline) external onlyRole(Constants.ADMIN_ROLE) {
        if (_newDeadline <= tierDeadlines[currentTier]) revert DeadlineInPast(_newDeadline);
        tierDeadlines[currentTier] = _newDeadline;
        emit TierExtended(currentTier, _newDeadline);
    }

    /**
     * @dev Get vesting parameters for a tier
     * @param _tierId ID of the tier
     * @return tgePercentage Percentage released at TGE
     * @return vestingMonths Vesting duration in months
     */
    function getTierVestingParams(uint8 _tierId) external view returns (uint8 tgePercentage, uint16 vestingMonths) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        return (tiers[_tierId].vestingTGE, tiers[_tierId].vestingMonths);
    }

    /**
     * @dev Get tier price
     * @param _tierId ID of the tier
     * @return price Price in USD (scaled by 1e6)
     */
    function getTierPrice(uint8 _tierId) external view returns (uint96 price) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        return tiers[_tierId].price;
    }

    function setTierTimes(uint8 _tierId, uint64 _start, uint64 _end) external onlyRole(Constants.ADMIN_ROLE) {
        require(_start < _end, "Invalid time range");
        tierStartTimes[_tierId] = _start;
        tierEndTimes[_tierId] = _end;
    }

    /**
     * @dev Check if tier is active
     * @param _tierId ID of the tier
     * @return isActive Whether the tier is active
     */
    function isTierActive(uint8 _tierId) external view returns (bool isActive) {
        if (_tierId >= tiers.length) revert InvalidTierId(_tierId);
        return tiers[_tierId].isActive;
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
                require(!systemPaused, "TokenStaking: system still paused");
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
