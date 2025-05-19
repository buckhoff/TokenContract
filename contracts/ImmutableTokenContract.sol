// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ImmutableTokenContract
 * @dev A non-upgradeable contract that stores immutable constants for the TEACH token ecosystem
 * These values can never be changed, even if the main token contract is upgraded
 */
contract ImmutableTokenContract {
    // Token Supply Constants - These will be immutable once deployed
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 10**18; // 5 billion tokens with 18 decimals

    // Token Distribution Constants - Original allocation percentages (basis points)
    uint256 public constant PUBLIC_PRESALE_ALLOCATION_BPS = 2500; // 25%
    uint256 public constant COMMUNITY_INCENTIVES_ALLOCATION_BPS = 2400; // 24%
    uint256 public constant PLATFORM_ECOSYSTEM_ALLOCATION_BPS = 2000; // 20%
    uint256 public constant INITIAL_LIQUIDITY_ALLOCATION_BPS = 1200; // 12%
    uint256 public constant TEAM_DEV_ALLOCATION_BPS = 800; // 8%
    uint256 public constant EDUCATIONAL_PARTNERS_ALLOCATION_BPS = 700; // 7%
    uint256 public constant RESERVE_ALLOCATION_BPS = 400; // 4%

    // Core token properties
    string public constant TOKEN_NAME = "TeacherSupport Token";
    string public constant TOKEN_SYMBOL = "TEACH";
    uint8 public constant TOKEN_DECIMALS = 18;

    // Version information - useful for tracking which constants version is deployed
    string public constant CONSTANTS_VERSION = "1.0.0";

    // Constructor does nothing special - all values are constants
    constructor() {
        // No initialization needed as all variables are constants
    }

    /**
     * @dev Validates that token allocations add up to 100%
     * @return true if allocations are valid
     */
    function validateAllocations() external pure returns (bool) {
        uint256 totalAllocation =
            PUBLIC_PRESALE_ALLOCATION_BPS +
            COMMUNITY_INCENTIVES_ALLOCATION_BPS +
            PLATFORM_ECOSYSTEM_ALLOCATION_BPS +
            INITIAL_LIQUIDITY_ALLOCATION_BPS +
            TEAM_DEV_ALLOCATION_BPS +
            EDUCATIONAL_PARTNERS_ALLOCATION_BPS +
            RESERVE_ALLOCATION_BPS;

        return totalAllocation == 10000; // Must equal 100% (10000 basis points)
    }

    /**
     * @dev Calculates the token amount for a specific allocation
     * @param allocationBPS The allocation in basis points (e.g., 2500 for 25%)
     * @return The token amount for this allocation
     */
    function calculateAllocation(uint256 allocationBPS) external pure returns (uint256) {
        return (MAX_SUPPLY * allocationBPS) / 10000;
    }
}
