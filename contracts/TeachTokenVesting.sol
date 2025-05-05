// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";
import {VestingCalculations} from "./Libraries/VestingCalculations.sol";

/**
 * @title TeachTokenVesting
 * @dev Vesting contract for the TEACH token with support for multiple schedules
 */
contract TeachTokenVesting is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // Token and records
    ERC20Upgradeable internal token;

    // Vesting schedule types
    enum VestingType {
        LINEAR,       // Linear vesting after cliff
        QUARTERLY,    // Quarterly releases
        MILESTONE     // Release based on milestones
    }

    // Vesting beneficiary group
    enum BeneficiaryGroup {
        TEAM,              // Development team
        ADVISORS,          // Advisors and early supporters
        PARTNERS,          // Educational partners
        PUBLIC_SALE,       // Public sale participants
        ECOSYSTEM          // Ecosystem growth and treasury
    }

    // Vesting schedule structure
    struct VestingSchedule {
        address beneficiary;         // Address of beneficiary
        uint96 totalAmount;         // Total amount of tokens to be vested
        uint96 claimedAmount;       // Amount of tokens already claimed
        uint40 startTime;           // Start time of the vesting
        uint40 cliffDuration;       // Cliff duration in seconds
        uint40 duration;            // Duration of the vesting in seconds after cliff
        uint8 tgePercentage;         // Percentage unlocked at TGE (scaled by 100)
        VestingType vestingType;     // Type of vesting schedule
        BeneficiaryGroup group;      // Beneficiary group
        bool revocable;              // Whether the vesting is revocable
        bool revoked;                // Whether the vesting has been revoked
    }

    // Schedule ID counter
    uint256 private _scheduleIdCounter;

    // Mapping from ID to vesting schedule
    mapping(uint256 => VestingSchedule) public vestingSchedules;

    // Mapping from beneficiary to their schedule IDs
    mapping(address => uint256[]) public beneficiarySchedules;

    // Milestone release tracking
    struct Milestone {
        string description;
        uint8 percentage;            // Percentage to release (scaled by 100)
        bool achieved;               // Whether milestone has been achieved
    }

    // Mapping from schedule ID to milestones
    mapping(uint256 => Milestone[]) public scheduleMilestones;

    // Quarterly release tracking
    struct QuarterlyRelease {
        uint40 releaseTime;         // Time when the quarterly release is available
        uint96 amount;              // Amount to release
        bool released;               // Whether it has been released
    }

    // Mapping from schedule ID to quarterly releases
    mapping(uint256 => QuarterlyRelease[]) public scheduleQuarterlyReleases;

    // TGE timestamp
    uint40 public tgeTime;

    // Whether TGE has occurred
    bool public tgeOccurred;

    // Pause state
    bool public paused;

    // Events
    event ScheduleCreated(uint256 indexed scheduleId, address indexed beneficiary, BeneficiaryGroup group, uint96 amount);
    event TokensClaimed(uint256 indexed scheduleId, address indexed beneficiary, uint96 amount);
    event ScheduleRevoked(uint256 indexed scheduleId, address indexed beneficiary, uint96 unclaimedAmount);
    event MilestoneAdded(uint256 indexed scheduleId, string description, uint8 percentage);
    event MilestoneAchieved(uint256 indexed scheduleId, uint256 milestoneIndex, string description);
    event QuarterlyReleaseAdded(uint256 indexed scheduleId, uint40 releaseTime, uint96 amount);
    event TGESet(uint40 timestamp);
    event Paused(address account);
    event Unpaused(address account);
    event BatchScheduleCreated(uint256 count, BeneficiaryGroup group);

    // Modifiers
    modifier whenNotPaused() {
        require(!paused, "TeachTokenVesting: paused");
        _;
    }

    modifier onlyAfterTGE() {
        require(tgeOccurred, "TeachTokenVesting: TGE not occurred yet");
        _;
    }

    modifier onlyScheduleOwner(uint256 scheduleId) {
        require(vestingSchedules[scheduleId].beneficiary == msg.sender, "TeachTokenVesting: not schedule owner");
        _;
    }

    /**
     * @dev Initializes the contract with initial parameters
     * @param _token Address of the TEACH token
     */
    function initialize(address _token) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();

        require(_token != address(0), "TeachTokenVesting: zero token address");
        token = ERC20Upgradeable(_token);

        _scheduleIdCounter = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Sets the TGE time, enabling token claim
     * @param _tgeTime Timestamp of the TGE
     */
    function setTGE(uint40 _tgeTime) external onlyRole(Constants.ADMIN_ROLE) {
        require(!tgeOccurred, "TeachTokenVesting: TGE already set");
        require(_tgeTime > 0, "TeachTokenVesting: invalid TGE time");

        tgeTime = _tgeTime;
        tgeOccurred = true;

        emit TGESet(_tgeTime);
    }

    /**
     * @dev Creates a new linear vesting schedule
     * @param _beneficiary Address of the beneficiary
     * @param _amount Total token amount to vest
     * @param _cliffDuration Cliff duration in seconds
     * @param _duration Total vesting duration in seconds after cliff
     * @param _tgePercentage Percentage to release at TGE (scaled by 100)
     * @param _group Beneficiary group
     * @param _revocable Whether the schedule is revocable
     * @return scheduleId ID of the created schedule
     */
    function createLinearVestingSchedule(
        address _beneficiary,
        uint96 _amount,
        uint40 _cliffDuration,
        uint40 _duration,
        uint8 _tgePercentage,
        BeneficiaryGroup _group,
        bool _revocable
    ) public onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        require(_beneficiary != address(0), "TeachTokenVesting: zero beneficiary address");
        require(_amount > 0, "TeachTokenVesting: zero amount");
        require(_duration > 0, "TeachTokenVesting: zero duration");
        require(_tgePercentage <= 100, "TeachTokenVesting: TGE percentage too high");

        uint256 scheduleId = _scheduleIdCounter++;

        vestingSchedules[scheduleId] = VestingSchedule({
            beneficiary: _beneficiary,
            totalAmount: _amount,
            claimedAmount: 0,
            startTime: uint40(block.timestamp),
            cliffDuration: _cliffDuration,
            duration: _duration,
            tgePercentage: _tgePercentage,
            vestingType: VestingType.LINEAR,
            group: _group,
            revocable: _revocable,
            revoked: false
        });

        beneficiarySchedules[_beneficiary].push(scheduleId);

        // Verify we have enough tokens for the vesting
        require(token.balanceOf(address(this)) >= _amount, "TeachTokenVesting: insufficient token balance");

        emit ScheduleCreated(scheduleId, _beneficiary, _group, _amount);

        return scheduleId;
    }

    /**
     * @dev Creates a quarterly vesting schedule
     * @param _beneficiary Address of the beneficiary
     * @param _totalAmount Total token amount to vest
     * @param _initialAmount Initial amount to release at TGE
     * @param _releasesCount Number of quarterly releases
     * @param _firstReleaseTime Timestamp of the first quarterly release
     * @param _group Beneficiary group
     * @param _revocable Whether the schedule is revocable
     * @return scheduleId ID of the created schedule
     */
    function createQuarterlyVestingSchedule(
        address _beneficiary,
        uint96 _totalAmount,
        uint96 _initialAmount,
        uint8 _releasesCount,
        uint40 _firstReleaseTime,
        BeneficiaryGroup _group,
        bool _revocable
    ) public onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        require(_beneficiary != address(0), "TeachTokenVesting: zero beneficiary address");
        require(_totalAmount > 0, "TeachTokenVesting: zero amount");
        require(_initialAmount < _totalAmount, "TeachTokenVesting: initial amount too high");
        require(_releasesCount > 0, "TeachTokenVesting: zero releases count");
        require(_firstReleaseTime > block.timestamp, "TeachTokenVesting: first release in the past");

        uint256 scheduleId = _scheduleIdCounter++;

        // Calculate TGE percentage
        uint8 tgePercentage = uint8((_initialAmount * 100) / _totalAmount);

        vestingSchedules[scheduleId] = VestingSchedule({
            beneficiary: _beneficiary,
            totalAmount: _totalAmount,
            claimedAmount: 0,
            startTime: uint40(block.timestamp),
            cliffDuration: _firstReleaseTime - uint40(block.timestamp),
            duration: 0, // Not used for quarterly releases
            tgePercentage: tgePercentage,
            vestingType: VestingType.QUARTERLY,
            group: _group,
            revocable: _revocable,
            revoked: false
        });

        beneficiarySchedules[_beneficiary].push(scheduleId);

        // Setup quarterly releases
        uint96 remainingAmount = _totalAmount - _initialAmount;
        uint96 quarterlyAmount = remainingAmount / _releasesCount;
        uint96 lastRelease = remainingAmount - (quarterlyAmount * (_releasesCount - 1));

        for (uint8 i = 0; i < _releasesCount; i++) {
            uint40 releaseTime = _firstReleaseTime + (i * 90 days);
            uint96 amount = (i == _releasesCount - 1) ? lastRelease : quarterlyAmount;

            scheduleQuarterlyReleases[scheduleId].push(QuarterlyRelease({
                releaseTime: releaseTime,
                amount: amount,
                released: false
            }));

            emit QuarterlyReleaseAdded(scheduleId, releaseTime, amount);
        }

        // Verify we have enough tokens for the vesting
        require(token.balanceOf(address(this)) >= _totalAmount, "TeachTokenVesting: insufficient token balance");

        emit ScheduleCreated(scheduleId, _beneficiary, _group, _totalAmount);

        return scheduleId;
    }

    /**
     * @dev Creates a milestone-based vesting schedule
     * @param _beneficiary Address of the beneficiary
     * @param _totalAmount Total token amount to vest
     * @param _tgePercentage Percentage to release at TGE (scaled by 100)
     * @param _group Beneficiary group
     * @param _revocable Whether the schedule is revocable
     * @return scheduleId ID of the created schedule
     */
    function createMilestoneVestingSchedule(
        address _beneficiary,
        uint96 _totalAmount,
        uint8 _tgePercentage,
        BeneficiaryGroup _group,
        bool _revocable
    ) external onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        require(_beneficiary != address(0), "TeachTokenVesting: zero beneficiary address");
        require(_totalAmount > 0, "TeachTokenVesting: zero amount");
        require(_tgePercentage <= 100, "TeachTokenVesting: TGE percentage too high");

        uint256 scheduleId = _scheduleIdCounter++;

        vestingSchedules[scheduleId] = VestingSchedule({
            beneficiary: _beneficiary,
            totalAmount: _totalAmount,
            claimedAmount: 0,
            startTime: uint40(block.timestamp),
            cliffDuration: 0, // Not used for milestone-based
            duration: 0, // Not used for milestone-based
            tgePercentage: _tgePercentage,
            vestingType: VestingType.MILESTONE,
            group: _group,
            revocable: _revocable,
            revoked: false
        });

        beneficiarySchedules[_beneficiary].push(scheduleId);

        // Verify we have enough tokens for the vesting
        require(token.balanceOf(address(this)) >= _totalAmount, "TeachTokenVesting: insufficient token balance");

        emit ScheduleCreated(scheduleId, _beneficiary, _group, _totalAmount);

        return scheduleId;
    }

    /**
     * @dev Adds a milestone to a milestone-based vesting schedule
     * @param _scheduleId ID of the vesting schedule
     * @param _description Description of the milestone
     * @param _percentage Percentage to release on achievement (scaled by 100)
     */
    function addMilestone(
        uint256 _scheduleId,
        string memory _description,
        uint8 _percentage
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(vestingSchedules[_scheduleId].vestingType == VestingType.MILESTONE, "TeachTokenVesting: not milestone-based");
        require(_percentage > 0 && _percentage <= 100, "TeachTokenVesting: invalid percentage");

        // Calculate total percentage across all milestones
        uint8 totalPercentage = vestingSchedules[_scheduleId].tgePercentage;
        Milestone[] storage milestones = scheduleMilestones[_scheduleId];

        for (uint8 i = 0; i < milestones.length; i++) {
            totalPercentage += milestones[i].percentage;
        }

        // Ensure we don't exceed 100%
        require(totalPercentage + _percentage <= 100, "TeachTokenVesting: total percentage exceeds 100%");

        // Add the new milestone
        milestones.push(Milestone({
            description: _description,
            percentage: _percentage,
            achieved: false
        }));

        emit MilestoneAdded(_scheduleId, _description, _percentage);
    }

    /**
     * @dev Marks a milestone as achieved
     * @param _scheduleId ID of the vesting schedule
     * @param _milestoneIndex Index of the milestone
     */
    function achieveMilestone(
        uint256 _scheduleId,
        uint256 _milestoneIndex
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(vestingSchedules[_scheduleId].vestingType == VestingType.MILESTONE, "TeachTokenVesting: not milestone-based");

        Milestone[] storage milestones = scheduleMilestones[_scheduleId];
        require(_milestoneIndex < milestones.length, "TeachTokenVesting: invalid milestone index");
        require(!milestones[_milestoneIndex].achieved, "TeachTokenVesting: milestone already achieved");

        milestones[_milestoneIndex].achieved = true;

        emit MilestoneAchieved(_scheduleId, _milestoneIndex, milestones[_milestoneIndex].description);
    }

    /**
     * @dev Calculates the amount of tokens that can be claimed for a linear vesting schedule
     * @param _schedule The vesting schedule
     * @return The claimable token amount
     */
    function _calculateClaimableLinear(VestingSchedule memory _schedule) internal view returns (uint96) {
        if (_schedule.revoked) {
            return 0;
        }

        // If TGE hasn't occurred yet, nothing can be claimed
        if (!tgeOccurred) {
            return 0;
        }

        // Calculate total vested amount
        uint96 totalVestedAmount;

        // If we're before cliff, only TGE amount is available
        uint96 tgeAmount = (_schedule.totalAmount * _schedule.tgePercentage) / 100;

        if (block.timestamp < _schedule.startTime + _schedule.cliffDuration) {
            return tgeAmount > _schedule.claimedAmount ? tgeAmount - _schedule.claimedAmount : 0;
        }

        // If we're after cliff but before end of vesting
        if (block.timestamp < _schedule.startTime + _schedule.cliffDuration + _schedule.duration) {
            uint40 timeFromCliff = uint40(block.timestamp - (_schedule.startTime + _schedule.cliffDuration));
            uint96 vestingAmount = _schedule.totalAmount - tgeAmount;

            uint96 vestedAmount = (vestingAmount * timeFromCliff) / _schedule.duration;
            totalVestedAmount = tgeAmount + vestedAmount;
        } else {
            // After vesting is complete
            totalVestedAmount = _schedule.totalAmount;
        }

        // Return claimable amount
        uint96 claimable = totalVestedAmount > _schedule.claimedAmount ?
            totalVestedAmount - _schedule.claimedAmount : 0;

        return claimable;
    }

    /**
     * @dev Calculates the amount of tokens that can be claimed for a quarterly vesting schedule
     * @param _schedule The vesting schedule
     * @param _scheduleId The schedule ID
     * @return The claimable token amount
     */
    function _calculateClaimableQuarterly(VestingSchedule memory _schedule, uint256 _scheduleId) internal view returns (uint96) {
        if (_schedule.revoked) {
            return 0;
        }

        // If TGE hasn't occurred yet, nothing can be claimed
        if (!tgeOccurred) {
            return 0;
        }

        // Calculate TGE amount
        uint96 tgeAmount = (_schedule.totalAmount * _schedule.tgePercentage) / 100;

        // Check if TGE amount is already claimed
        uint96 claimable = 0;

        if (_schedule.claimedAmount < tgeAmount) {
            claimable = tgeAmount - _schedule.claimedAmount;
        }

        // Check quarterly releases
        QuarterlyRelease[] storage releases = scheduleQuarterlyReleases[_scheduleId];

        for (uint8 i = 0; i < releases.length; i++) {
            if (!releases[i].released && block.timestamp >= releases[i].releaseTime) {
                claimable += releases[i].amount;
            }
        }

        return claimable;
    }

    /**
     * @dev Calculates the amount of tokens that can be claimed for a milestone vesting schedule
     * @param _schedule The vesting schedule
     * @param _scheduleId The schedule ID
     * @return The claimable token amount
     */
    function _calculateClaimableMilestone(VestingSchedule memory _schedule, uint256 _scheduleId) internal view returns (uint96) {
        if (_schedule.revoked) {
            return 0;
        }

        // If TGE hasn't occurred yet, nothing can be claimed
        if (!tgeOccurred) {
            return 0;
        }

        // Calculate TGE amount
        uint96 tgeAmount = (_schedule.totalAmount * _schedule.tgePercentage) / 100;

        // Check if TGE amount is already claimed
        uint96 claimable = 0;

        if (_schedule.claimedAmount < tgeAmount) {
            claimable = tgeAmount - _schedule.claimedAmount;
        }

        // Check milestones
        Milestone[] storage milestones = scheduleMilestones[_scheduleId];

        for (uint8 i = 0; i < milestones.length; i++) {
            if (milestones[i].achieved) {
                uint96 milestoneAmount = (_schedule.totalAmount * milestones[i].percentage) / 100;
                uint96 alreadyClaimed = (i == 0) ?
                    (_schedule.claimedAmount > tgeAmount ? _schedule.claimedAmount - tgeAmount : 0) :
                    _schedule.claimedAmount;

                if (alreadyClaimed < milestoneAmount) {
                    claimable += milestoneAmount - alreadyClaimed;
                }
            }
        }

        return claimable;
    }

    /**
     * @dev Calculates the total amount of tokens that can be claimed from a vesting schedule
     * @param _scheduleId ID of the vesting schedule
     * @return The claimable token amount
     */
    function calculateClaimableAmount(uint256 _scheduleId) public view returns (uint96) {
        VestingSchedule memory schedule = vestingSchedules[_scheduleId];

        if (schedule.beneficiary == address(0)) {
            return 0; // Schedule doesn't exist
        }

        if (schedule.vestingType == VestingType.LINEAR) {
            return _calculateClaimableLinear(schedule);
        } else if (schedule.vestingType == VestingType.QUARTERLY) {
            return _calculateClaimableQuarterly(schedule, _scheduleId);
        } else if (schedule.vestingType == VestingType.MILESTONE) {
            return _calculateClaimableMilestone(schedule, _scheduleId);
        }

        return 0;
    }

    /**
     * @dev Claims tokens from a vesting schedule
     * @param _scheduleId ID of the vesting schedule
     */
    function claimTokens(uint256 _scheduleId) external nonReentrant whenNotPaused onlyAfterTGE onlyScheduleOwner(_scheduleId) returns (uint96 claimable) {
         claimable = calculateClaimableAmount(_scheduleId);
        require(claimable > 0, "TeachTokenVesting: no tokens claimable");

        VestingSchedule storage schedule = vestingSchedules[_scheduleId];

        // Update claimed amount
        schedule.claimedAmount += claimable;

        // If it's a quarterly schedule, mark releases as released
        if (schedule.vestingType == VestingType.QUARTERLY) {
            QuarterlyRelease[] storage releases = scheduleQuarterlyReleases[_scheduleId];

            // Mark releases as claimed
            for (uint8 i = 0; i < releases.length; i++) {
                if (!releases[i].released && block.timestamp >= releases[i].releaseTime) {
                    releases[i].released = true;
                }
            }
        }

        // Transfer tokens to beneficiary
        require(token.transfer(schedule.beneficiary, claimable), "TeachTokenVesting: transfer failed");

        
        emit TokensClaimed(_scheduleId, schedule.beneficiary, claimable);
    }

    /**
     * @dev Revokes a vesting schedule
     * @param _scheduleId ID of the vesting schedule
     * Returns unclaimed tokens to owner
     */
    function revokeSchedule(uint256 _scheduleId) external onlyRole(Constants.ADMIN_ROLE) {
        VestingSchedule storage schedule = vestingSchedules[_scheduleId];

        require(schedule.beneficiary != address(0), "TeachTokenVesting: schedule doesn't exist");
        require(schedule.revocable, "TeachTokenVesting: not revocable");
        require(!schedule.revoked, "TeachTokenVesting: already revoked");

        // Calculate vested amount
        uint96 vestedAmount;

        if (schedule.vestingType == VestingType.LINEAR) {
            vestedAmount = _calculateClaimableLinear(schedule) + schedule.claimedAmount;
        } else if (schedule.vestingType == VestingType.QUARTERLY) {
            vestedAmount = _calculateClaimableQuarterly(schedule, _scheduleId) + schedule.claimedAmount;
        } else if (schedule.vestingType == VestingType.MILESTONE) {
            vestedAmount = _calculateClaimableMilestone(schedule, _scheduleId) + schedule.claimedAmount;
        }

        // Calculate amount to return to owner
        uint96 unclaimedAmount = schedule.totalAmount - vestedAmount;

        if (unclaimedAmount > 0) {
            // Transfer unclaimed tokens back to owner
            require(token.transfer(owner(), unclaimedAmount), "TeachTokenVesting: transfer failed");
        }

        // Mark schedule as revoked
        schedule.revoked = true;

        emit ScheduleRevoked(_scheduleId, schedule.beneficiary, unclaimedAmount);
    }

    /**
     * @dev Batch creation of linear vesting schedules
     * @param _beneficiaries Array of beneficiary addresses
     * @param _amounts Array of total token amounts
     * @param _cliffDuration Cliff duration in seconds
     * @param _duration Total vesting duration in seconds after cliff
     * @param _tgePercentage Percentage to release at TGE (scaled by 100)
     * @param _group Beneficiary group
     * @param _revocable Whether the schedules are revocable
     */
    function batchCreateLinearVestingSchedules(
        address[] calldata _beneficiaries,
        uint96[] calldata _amounts,
        uint40 _cliffDuration,
        uint40 _duration,
        uint8 _tgePercentage,
        BeneficiaryGroup _group,
        bool _revocable
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_beneficiaries.length == _amounts.length, "TeachTokenVesting: arrays length mismatch");

        uint96 totalAmount = 0;
        for (uint96 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // Verify we have enough tokens for all the vestings
        require(token.balanceOf(address(this)) >= totalAmount, "TeachTokenVesting: insufficient token balance");

        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            createLinearVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                _cliffDuration,
                _duration,
                _tgePercentage,
                _group,
                _revocable
            );
        }

        emit BatchScheduleCreated(_beneficiaries.length, _group);
    }

    /**
     * @dev Batch creation of standard public sale vesting schedules
     * @param _beneficiaries Array of beneficiary addresses
     * @param _amounts Array of total token amounts
     */
    function batchCreatePublicSaleVestingSchedules(
        address[] calldata _beneficiaries,
        uint96[] calldata _amounts
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_beneficiaries.length == _amounts.length, "TeachTokenVesting: arrays length mismatch");

        uint96 totalAmount = 0;
        for (uint96 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // Verify we have enough tokens for all the vestings
        require(token.balanceOf(address(this)) >= totalAmount, "TeachTokenVesting: insufficient token balance");

        // Standard public sale parameters: 20% TGE unlock with 6-month vesting
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            createLinearVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                0, // No cliff
                180 days, // 6 months
                20, // 20% at TGE
                BeneficiaryGroup.PUBLIC_SALE,
                false // Not revocable
            );
        }

        emit BatchScheduleCreated(_beneficiaries.length, BeneficiaryGroup.PUBLIC_SALE);
    }

    /**
     * @dev Batch creation of development team vesting schedules
     * @param _beneficiaries Array of team member addresses
     * @param _amounts Array of total token amounts
     */
    function batchCreateTeamVestingSchedules(
        address[] calldata _beneficiaries,
        uint96[] calldata _amounts
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_beneficiaries.length == _amounts.length, "TeachTokenVesting: arrays length mismatch");

        uint96 totalAmount = 0;
        for (uint96 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // Verify we have enough tokens for all the vestings
        require(token.balanceOf(address(this)) >= totalAmount, "TeachTokenVesting: insufficient token balance");

        // Standard dev team parameters: quarterly release with 2-3M tokens at TGE
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            // Calculate appropriate initial release (~2-3M tokens collectively for the team)
            uint96 initialRelease = _amounts[i] / 8; // Approximately 12.5% at TGE

            // Create a quarterly vesting schedule with 8 releases
            createQuarterlyVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                initialRelease,
                8, // 8 quarterly releases (2 years)
                uint40(block.timestamp) + 90 days, // First release in 3 months
                BeneficiaryGroup.TEAM,
                true // Revocable
            );
        }

        emit BatchScheduleCreated(_beneficiaries.length, BeneficiaryGroup.TEAM);
    }

    /**
     * @dev Batch creation of advisor vesting schedules
     * @param _beneficiaries Array of advisor addresses
     * @param _amounts Array of total token amounts
     */
    function batchCreateAdvisorVestingSchedules(
        address[] calldata _beneficiaries,
        uint96[] calldata _amounts
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_beneficiaries.length == _amounts.length, "TeachTokenVesting: arrays length mismatch");

        uint96 totalAmount = 0;
        for (uint96 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // Verify we have enough tokens for all the vestings
        require(token.balanceOf(address(this)) >= totalAmount, "TeachTokenVesting: insufficient token balance");

        // Standard advisor parameters: 1-year linear vesting with 3-month cliff
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            createLinearVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                90 days, // 3-month cliff
                365 days, // 1-year vesting
                10, // 10% at TGE
                BeneficiaryGroup.ADVISORS,
                true // Revocable
            );
        }

        emit BatchScheduleCreated(_beneficiaries.length, BeneficiaryGroup.ADVISORS);
    }

    /**
     * @dev Batch creation of partner vesting schedules
     * @param _beneficiaries Array of partner addresses
     * @param _amounts Array of total token amounts
     */
    function batchCreatePartnerVestingSchedules(
        address[] calldata _beneficiaries,
        uint96[] calldata _amounts
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_beneficiaries.length == _amounts.length, "TeachTokenVesting: arrays length mismatch");

        uint96 totalAmount = 0;
        for (uint96 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // Verify we have enough tokens for all the vestings
        require(token.balanceOf(address(this)) >= totalAmount, "TeachTokenVesting: insufficient token balance");

        // Standard partner parameters: 18-month linear vesting with 10% TGE
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            createLinearVestingSchedule(
                _beneficiaries[i],
                _amounts[i],
                0, // No cliff
                540 days, // 18-month vesting
                10, // 10% at TGE
                BeneficiaryGroup.PARTNERS,
                true // Revocable
            );
        }

        emit BatchScheduleCreated(_beneficiaries.length, BeneficiaryGroup.PARTNERS);
    }

    /**
     * @dev Calculates the total amount of tokens allocated to each beneficiary group
     * @return team Total tokens allocated to team members
     * @return advisors Total tokens allocated to advisors
     * @return partners Total tokens allocated to partners
     * @return publicSale Total tokens allocated to public sale participants
     * @return ecosystem Total tokens allocated to ecosystem
     */
    function getTotalAllocationsByGroup() external view returns (
        uint96 team,
        uint96 advisors,
        uint96 partners,
        uint96 publicSale,
        uint96 ecosystem
    ) {
        for (uint256 i = 1; i < _scheduleIdCounter; i++) {
            VestingSchedule memory schedule = vestingSchedules[i];

            if (schedule.beneficiary != address(0) && !schedule.revoked) {
                if (schedule.group == BeneficiaryGroup.TEAM) {
                    team += schedule.totalAmount;
                } else if (schedule.group == BeneficiaryGroup.ADVISORS) {
                    advisors += schedule.totalAmount;
                } else if (schedule.group == BeneficiaryGroup.PARTNERS) {
                    partners += schedule.totalAmount;
                } else if (schedule.group == BeneficiaryGroup.PUBLIC_SALE) {
                    publicSale += schedule.totalAmount;
                } else if (schedule.group == BeneficiaryGroup.ECOSYSTEM) {
                    ecosystem += schedule.totalAmount;
                }
            }
        }

        return (team, advisors, partners, publicSale, ecosystem);
    }

    /**
     * @dev Gets all vesting schedules for a beneficiary
     * @param _beneficiary Address of the beneficiary
     * @return scheduleIds Array of schedule IDs
     */
    function getSchedulesForBeneficiary(address _beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[_beneficiary];
    }

    /**
     * @dev Gets detailed information about a vesting schedule
     * @param _scheduleId ID of the vesting schedule
     * @return beneficiary Address of the beneficiary
     * @return totalAmount Total amount of tokens to be vested
     * @return claimedAmount Amount of tokens already claimed
     * @return startTime Start time of the vesting
     * @return cliffDuration Cliff duration in seconds
     * @return duration Total vesting duration in seconds after cliff
     * @return tgePercentage Percentage unlocked at TGE
     * @return vestingType Type of vesting schedule
     * @return group Beneficiary group
     * @return revocable Whether the vesting is revocable
     * @return revoked Whether the vesting has been revoked
     * @return claimableAmount Currently claimable token amount
     */
    function getScheduleDetails(uint256 _scheduleId) external view returns (
        address beneficiary,
        uint96 totalAmount,
        uint96 claimedAmount,
        uint40 startTime,
        uint40 cliffDuration,
        uint40 duration,
        uint8 tgePercentage,
        VestingType vestingType,
        BeneficiaryGroup group,
        bool revocable,
        bool revoked,
        uint96 claimableAmount
    ) {
        VestingSchedule memory schedule = vestingSchedules[_scheduleId];
        claimableAmount = calculateClaimableAmount(_scheduleId);

        return (
            schedule.beneficiary,
            schedule.totalAmount,
            schedule.claimedAmount,
            schedule.startTime,
            schedule.cliffDuration,
            schedule.duration,
            schedule.tgePercentage,
            schedule.vestingType,
            schedule.group,
            schedule.revocable,
            schedule.revoked,
            claimableAmount
        );
    }

    /**
     * @dev Pauses the contract, disabling token claims
     */
    function pause() external onlyRole(Constants.ADMIN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @dev Unpauses the contract, enabling token claims
     */
    function unpause() external onlyRole(Constants.ADMIN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @dev Set token address in case of token upgrade
     * @param _token New token address
     */
    function setToken(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        require(_token != address(0), "TeachTokenVesting: zero token address");
        token = ERC20Upgradeable(_token);
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Token address to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        require(_token != address(token), "TeachTokenVesting: cannot recover vesting token");
        uint96 balance = uint96(ERC20Upgradeable(_token).balanceOf(address(this)));
        require(balance > 0, "TeachTokenVesting: no tokens to recover");
        require(ERC20Upgradeable(_token).transfer(owner(), balance), "TeachTokenVesting: transfer failed");
    }
}