// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockTokenVestingEnhanced
 * @dev Enhanced mock implementation of ITokenVesting for comprehensive testing
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
    mapping(uint256 => uint40) public scheduleStartTimes;
    mapping(uint256 => BeneficiaryGroup) public scheduleGroups;
    mapping(uint256 => bool) public scheduleRevocable;

    // Claim tracking
    mapping(uint256 => uint256) public claimedAmounts;
    mapping(address => uint256[]) public beneficiarySchedules;

    // TGE status
    bool public tgeOccurred;
    uint40 public tgeTime;

    // Last claimed amount for testing
    uint256 public lastClaimedAmount;
    address public lastClaimant;

    // Enhanced features for testing
    mapping(uint256 => bool) public schedulesPaused;
    mapping(uint256 => uint256) public customClaimableAmounts;

    // Events
    event ScheduleCreated(uint256 indexed scheduleId, address indexed beneficiary, BeneficiaryGroup group, uint256 amount);
    event TokensClaimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event TGESet(uint40 timestamp);

    /**
     * @dev Set TGE time and status
     */
    function setTGE(uint40 _tgeTime) external {
        tgeTime = _tgeTime;
        tgeOccurred = true;
        emit TGESet(_tgeTime);
    }

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
        scheduleStartTimes[scheduleId] = uint40(block.timestamp);
        scheduleGroups[scheduleId] = _group;
        scheduleRevocable[scheduleId] = _revocable;

        beneficiarySchedules[_beneficiary].push(scheduleId);

        emit ScheduleCreated(scheduleId, _beneficiary, _group, _amount);

        return scheduleId;
    }

    /**
     * @dev Calculate claimable amount with enhanced logic
     */
    function calculateClaimableAmount(uint256 _scheduleId) external view returns (uint256) {
        // Check if custom amount is set for testing
        if (customClaimableAmounts[_scheduleId] > 0) {
            return customClaimableAmounts[_scheduleId] - claimedAmounts[_scheduleId];
        }

        // Check if schedule is paused
        if (schedulesPaused[_scheduleId]) {
            return 0;
        }

        // Check if TGE has occurred
        if (!tgeOccurred) {
            return 0;
        }

        uint256 totalAmount = scheduleAmounts[_scheduleId];
        uint256 claimed = claimedAmounts[_scheduleId];
        uint8 tgePercentage = scheduleTgePercentages[_scheduleId];
        uint40 duration = scheduleDurations[_scheduleId];
        uint40 startTime = scheduleStartTimes[_scheduleId];

        // Calculate TGE amount
        uint256 tgeAmount = (totalAmount * tgePercentage) / 100;

        // If we're just after TGE, return TGE amount
        if (block.timestamp <= tgeTime + 1 days) {
            return tgeAmount > claimed ? tgeAmount - claimed : 0;
        }

        // Calculate vested amount based on time elapsed
        uint256 timeElapsed = block.timestamp - tgeTime;
        if (timeElapsed >= duration) {
            // Fully vested
            return totalAmount > claimed ? totalAmount - claimed : 0;
        }

        // Partially vested
        uint256 vestingAmount = totalAmount - tgeAmount;
        uint256 vestedAmount = (vestingAmount * timeElapsed) / duration;
        uint256 totalVested = tgeAmount + vestedAmount;

        return totalVested > claimed ? totalVested - claimed : 0;
    }

    /**
     * @dev Claim tokens with enhanced validation
     */
    function claimTokens(uint256 _scheduleId) external returns (uint256) {
        address beneficiary = scheduleOwners[_scheduleId];
        require(msg.sender == beneficiary, "Not the beneficiary");
        require(!schedulesPaused[_scheduleId], "Schedule is paused");

        uint256 claimable = this.calculateClaimableAmount(_scheduleId);
        require(claimable > 0, "Nothing to claim");

        claimedAmounts[_scheduleId] += claimable;
        lastClaimedAmount = claimable;
        lastClaimant = msg.sender;

        emit TokensClaimed(_scheduleId, beneficiary, claimable);

        return claimable;
    }

    /**
     * @dev Get schedules for beneficiary
     */
    function getSchedulesForBeneficiary(address _beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[_beneficiary];
    }

    /**
     * @dev Set custom claimable amount for testing
     */
    function setClaimableAmount(uint256 _scheduleId, uint256 _amount) external {
        customClaimableAmounts[_scheduleId] = _amount + claimedAmounts[_scheduleId];
    }

    /**
     * @dev Pause/unpause a schedule for testing
     */
    function pauseSchedule(uint256 _scheduleId, bool _paused) external {
        schedulesPaused[_scheduleId] = _paused;
    }

    /**
     * @dev Get schedule details
     */
    function getScheduleDetails(uint256 _scheduleId) external view returns (
        address beneficiary,
        uint256 totalAmount,
        uint256 claimedAmount,
        uint40 startTime,
        uint40 duration,
        uint8 tgePercentage,
        BeneficiaryGroup group,
        bool revocable,
        bool paused
    ) {
        return (
            scheduleOwners[_scheduleId],
            scheduleAmounts[_scheduleId],
            claimedAmounts[_scheduleId],
            scheduleStartTimes[_scheduleId],
            scheduleDurations[_scheduleId],
            scheduleTgePercentages[_scheduleId],
            scheduleGroups[_scheduleId],
            scheduleRevocable[_scheduleId],
            schedulesPaused[_scheduleId]
        );
    }

    /**
     * @dev Simulate vesting progression (advance time effect)
     */
    function simulateTimeProgress(uint256 _scheduleId, uint40 _timeAdvance) external {
        scheduleStartTimes[_scheduleId] -= _timeAdvance;
    }

    /**
     * @dev Batch create schedules for testing
     */
    function batchCreateSchedules(
        address[] calldata _beneficiaries,
        uint256[] calldata _amounts,
        uint8 _tgePercentage,
        uint40 _duration,
        BeneficiaryGroup _group
    ) external returns (uint256[] memory scheduleIds) {
        require(_beneficiaries.length == _amounts.length, "Arrays length mismatch");

        scheduleIds = new uint256[](_beneficiaries.length);

        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            scheduleIds[i] = this.createLinearVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                0, // No cliff
                _duration,
                _tgePercentage,
                _group,
                false // Not revocable
            );
        }

        return scheduleIds;
    }

    /**
     * @dev Get total schedules count
     */
    function getTotalSchedules() external view returns (uint256) {
        return nextScheduleId - 1;
    }

    /**
     * @dev Get statistics for a beneficiary group
     */
    function getGroupStatistics(BeneficiaryGroup _group) external view returns (
        uint256 totalSchedules,
        uint256 totalAmount,
        uint256 totalClaimed
    ) {
        for (uint256 i = 1; i < nextScheduleId; i++) {
            if (scheduleGroups[i] == _group) {
                totalSchedules++;
                totalAmount += scheduleAmounts[i];
                totalClaimed += claimedAmounts[i];
            }
        }

        return (totalSchedules, totalAmount, totalClaimed);
    }

    /**
     * @dev Emergency function to revoke a schedule
     */
    function revokeSchedule(uint256 _scheduleId) external {
        require(scheduleRevocable[_scheduleId], "Schedule not revocable");

        // Mark as fully claimed to prevent further claims
        claimedAmounts[_scheduleId] = scheduleAmounts[_scheduleId];
    }

    /**
     * @dev Check if schedule exists
     */
    function scheduleExists(uint256 _scheduleId) external view returns (bool) {
        return scheduleOwners[_scheduleId] != address(0);
    }

    /**
     * @dev Get vesting progress percentage (0-100)
     */
    function getVestingProgress(uint256 _scheduleId) external view returns (uint256) {
        if (!tgeOccurred || scheduleAmounts[_scheduleId] == 0) {
            return 0;
        }

        uint256 claimable = this.calculateClaimableAmount(_scheduleId);
        uint256 claimed = claimedAmounts[_scheduleId];
        uint256 totalAvailable = claimable + claimed;

        return (totalAvailable * 100) / scheduleAmounts[_scheduleId];
    }

    /**
     * @dev Reset all data (for testing cleanup)
     */
    function resetAllData() external {
        nextScheduleId = 1;
        tgeOccurred = false;
        tgeTime = 0;
        lastClaimedAmount = 0;
        lastClaimant = address(0);
    }

    /**
     * @dev Get version
     */
    function getVersion() external pure returns (string memory) {
        return "MockTokenVestingEnhanced-v1.0.0";
    }
}