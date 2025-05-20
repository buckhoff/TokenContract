// MockTierManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockTierManager
 * @dev Mock implementation of ITierManager for testing
 */
contract MockTierManager {
    // Tier structure
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

    // Tiers storage
    mapping(uint8 => PresaleTier) public tiers;
    mapping(uint8 => uint8) public bonusPercentages;

    // Track total sold
    uint256 public totalSold;

    // Last purchase record
    uint8 public lastTierId;
    uint256 public lastTokenAmount;

    /**
     * @dev Constructor to set up default tiers
     */
    constructor() {
        // Set up default tiers
        tiers[0] = PresaleTier({
            price: 40000, // $0.04
            allocation: 250_000_000 * 10**6,
            sold: 0,
            minPurchase: 100 * 10**6, // $100 min
            maxPurchase: 50_000 * 10**6, // $50,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: true
        });

        tiers[1] = PresaleTier({
            price: 60000, // $0.06
            allocation: 375_000_000 * 10**6,
            sold: 0,
            minPurchase: 100 * 10**6,
            maxPurchase: 50_000 * 10**6,
            vestingTGE: 20,
            vestingMonths: 6,
            isActive: true
        });

        // Set default bonuses
        bonusPercentages[0] = 20; // 20% for tier 0
        bonusPercentages[1] = 15; // 15% for tier 1
    }

    /**
     * @dev Get current bonus for a tier
     */
    function getCurrentBonus(uint8 _tierId) external view returns (uint8) {
        return bonusPercentages[_tierId];
    }

    /**
     * @dev Record a purchase
     */
    function recordPurchase(uint8 _tierId, uint256 _tokenAmount) external {
        tiers[_tierId].sold += _tokenAmount;
        totalSold += _tokenAmount;

        // Record for testing
        lastTierId = _tierId;
        lastTokenAmount = _tokenAmount;
    }

    /**
     * @dev Get remaining tokens in tier
     */
    function tokensRemainingInTier(uint8 _tierId) external view returns (uint96) {
        if (tiers[_tierId].allocation <= tiers[_tierId].sold) {
            return 0;
        }
        return uint96(tiers[_tierId].allocation - tiers[_tierId].sold);
    }

    /**
     * @dev Get total tokens sold
     */
    function totalTokensSold() external view returns (uint256) {
        return totalSold;
    }

    /**
     * @dev Get tier details
     */
    function getTierDetails(uint8 _tierId) external view returns (PresaleTier memory) {
        return tiers[_tierId];
    }

    /**
     * @dev Check if tier is active
     */
    function isTierActive(uint8 _tierId) external view returns (bool) {
        return tiers[_tierId].isActive;
    }

    /**
     * @dev Get tier price
     */
    function getTierPrice(uint8 _tierId) external view returns (uint96) {
        return tiers[_tierId].price;
    }

    /**
     * @dev Get tier vesting params
     */
    function getTierVestingParams(uint8 _tierId) external view returns (uint8, uint16) {
        return (tiers[_tierId].vestingTGE, tiers[_tierId].vestingMonths);
    }

    /**
     * @dev Set tier active status
     */
    function setTierActive(uint8 _tierId, bool _isActive) external {
        tiers[_tierId].isActive = _isActive;
    }

    /**
     * @dev Set tier bonus percentage
     */
    function setTierBonus(uint8 _tierId, uint8 _bonusPercentage) external {
        bonusPercentages[_tierId] = _bonusPercentage;
    }
}