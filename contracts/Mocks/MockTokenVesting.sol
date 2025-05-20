// MockTokenVesting.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockTokenVesting
 * @dev Mock implementation of ITokenVesting for testing
 */
contract MockTokenVesting {
    // Beneficiary group enum (must match contract enum)
    enum BeneficiaryGroup { TEAM, ADVISORS, PARTNERS, PUBLIC_SALE, ECOSYSTEM }

    // Schedule tracking
    uint256 public nextScheduleId = 1;
    mapping(uint256 => address) public scheduleOwners;
    mapping(uint256 => uint256) public scheduleAmounts;
    mapping(uint256 => uint8) public scheduleTgePercentages;
    mapping(uint256 => uint40) public scheduleDurations;
    mapping(uint256 => BeneficiaryGroup) public scheduleGroups;
    mapping(uint256 => bool) public scheduleRevocable;

    // Claim tracking
    mapping(uint256 => uint256) public claimedAmounts;
    mapping(address => uint256[]) public beneficiarySchedules;

    // Last claimed amount for testing
    uint256 public lastClaimedAmount;

    /**
     * @dev Create a linear vesting schedule
     */
    function createLinearVestingSchedule(
        address _beneficiary,
        uint256 _amount,
        uint40 _cliffDuration,
        uint40 _duration,
        uint8 _tgePercentage,
        BeneficiaryGroup _group,
        bool _revocable
    ) external returns (uint256) {
        uint256 scheduleId = nextScheduleId++;

        scheduleOwners[scheduleId] = _beneficiary;
        scheduleAmounts[scheduleId] = _amount;
        scheduleTgePercentages[scheduleId] = _tgePercentage;
        scheduleDurations[scheduleId] = _duration;
        scheduleGroups[scheduleId] = _group;
        scheduleRevocable[scheduleId] = _revocable;

        beneficiarySchedules[_beneficiary].push(scheduleId);

        return scheduleId;
    }

    /**
     * @dev Calculate claimable amount
     */
    function calculateClaimableAmount(uint256 _scheduleId) external view returns (uint256) {
        // For simplicity in testing, return 10% of the total amount
        // In a real implementation, this would consider vesting progression
        uint256 totalAmount = scheduleAmounts[_scheduleId];
        uint256 claimed = claimedAmounts[_scheduleId];

        return (totalAmount * 10) / 100 > claimed ? (totalAmount * 10) / 100 - claimed : 0;
    }

    /**
     * @dev Claim tokens
     */
    function claimTokens(uint256 _scheduleId) external returns (uint256) {
        address beneficiary = scheduleOwners[_scheduleId];
        require(msg.sender == beneficiary, "Not the beneficiary");

        uint256 claimable = (scheduleAmounts[_scheduleId] * 10) / 100 - claimedAmounts[_scheduleId];
        require(claimable > 0, "Nothing to claim");

        claimedAmounts[_scheduleId] += claimable;
        lastClaimedAmount = claimable;

        return claimable;
    }

    /**
     * @dev Get schedules for beneficiary
     */
    function getSchedulesForBeneficiary(address _beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[_beneficiary];
    }

    /**
     * @dev Set claimable amount for testing
     */
    function setClaimableAmount(uint256 _scheduleId, uint256 _amount) external {
        // Reset claimed amount to control what's claimable
        claimedAmounts[_scheduleId] = scheduleAmounts[_scheduleId] - _amount;
    }
}