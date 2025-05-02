// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title PresaleTiers
 * @dev Library for managing presale tier configurations in token sales
 */
library PresaleTiers {
    // Presale tiers structure
    struct PresaleTier {
        uint96 price;         // Price in USD (scaled by 1e6)
        uint96 allocation;    // Total allocation for this tier
        uint96 sold;          // Amount sold in this tier
        uint96 minPurchase;   // Minimum purchase amount in USD
        uint96 maxPurchase;   // Maximum purchase amount in USD
        uint8 vestingTGE;    // Percentage released at TGE (scaled by 100)
        uint16 vestingMonths; // Remaining vesting period in months
        bool isActive;        // Whether this tier is currently active
    }

    // USD price scaling factor (6 decimal places)
    uint32 internal constant PRICE_DECIMALS = 1e6;

    /**
     * @dev Creates standard tier configurations for a token presale
     * @return tiers Array of PresaleTier structures with standard configuration
     */
    function getStandardTiers() internal pure returns (PresaleTier[] memory) {
        PresaleTier[] memory tiers = new PresaleTier[](7);

        // Tier 1:
        tiers[0] = PresaleTier({
            price: 35000, // $0.035
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 50_000 * PRICE_DECIMALS, // $50,000 max
            vestingTGE: 10, // 10% at TGE
            vestingMonths: 18, // 18 months vesting
            isActive: false
        });

        // Tier 2: 
        tiers[1] = PresaleTier({
            price: 45000, // $0.045
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 25_000 * PRICE_DECIMALS, // $25,000 max
            vestingTGE: 15, // 15% at TGE
            vestingMonths: 15, // 15 months vesting
            isActive: false
        });

        // Tier 3: 
        tiers[2] = PresaleTier({
            price: 55000, // $0.055
            allocation: 100_000_000 * 10**18, // 100M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 10_000 * PRICE_DECIMALS, // $10,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 12, // 12 months vesting
            isActive: false
        });

        // Tier 4:
        tiers[3] = PresaleTier({
            price: 70000, // $0.07
            allocation: 75_000_000 * 10**18, // 75M tokens
            sold: 0,
            minPurchase: 100 * PRICE_DECIMALS, // $100 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 20, // 20% at TGE
            vestingMonths: 9, // 9 months vesting
            isActive: false
        });

        // Tier 5:
        tiers[4] = PresaleTier({
            price: 85000, // $0.085
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 50 * PRICE_DECIMALS, // $50 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 25, // 25% at TGE
            vestingMonths: 6, // 6 months vesting
            isActive: false
        });

        // Tier 6:
        tiers[5] = PresaleTier({
            price: 100000, // $0.10
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $20 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 30, // 30% at TGE
            vestingMonths: 4, // 4 months vesting
            isActive: false
        });

        // Tier 7:
        tiers[6] = PresaleTier({
            price: 120000, // $0.12
            allocation: 50_000_000 * 10**18, // 50M tokens
            sold: 0,
            minPurchase: 20 * PRICE_DECIMALS, // $20 min
            maxPurchase: 5_000 * PRICE_DECIMALS, // $5,000 max
            vestingTGE: 40, // 40% at TGE
            vestingMonths: 3, // 3 months vesting
            isActive: false
        });

        return tiers;
    }

    /**
     * @dev Calculate tier token allocations and maximums
     * @param tiers Array of PresaleTier structures
     * @param maxTokens maximum tokens across each tier
     */
    function calculateTierMaximums(PresaleTier[] memory tiers,
        mapping(uint96 => uint96) storage maxTokens
    ) internal {
        for (uint8 i = 0; i < tiers.length; i++) {
            uint96 tierTotal = 0;
            for (uint8 j = 0; j <= i; j++) {
                tierTotal += tiers[j].allocation;
            }
            maxTokens[i] = tierTotal;
        }
    }

    /**
     * @dev Calculate the number of tokens remaining in a tier
     * @param tier The tier to check
     * @return uint96 The number of tokens remaining in the tier
     */
    function tokensRemainingInTier(PresaleTier memory tier) internal pure returns (uint32) {
        return uint32(tier.allocation - tier.sold);
    }

    /**
     * @dev Calculate total tokens sold across all tiers
     * @param tiers Array of PresaleTier structures
     * @return total The total number of tokens sold
     */
    function calculateTotalTokensSold(PresaleTier[] memory tiers) internal pure returns (uint96 total) {
        total = 0;
        for (uint8 i = 0; i < tiers.length; i++) {
            total += tiers[i].sold;
        }
        return total;
    }
}