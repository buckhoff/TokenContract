// Helper function to expand TokenCrowdSale for testing
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../../contracts/TokenCrowdSale.sol";

/**
 * @title TokenCrowdSaleTestable
 * @dev Extension of TokenCrowdSale with test-only helper functions
 */
contract TokenCrowdSaleTestable is TokenCrowdSale {
    /**
     * @dev Set TGE completion status for testing
     */
    function setTGECompleted(bool _completed) external onlyRole(Constants.ADMIN_ROLE) {
        tgeCompleted = _completed;
    }

    /**
     * @dev Get raw tier amounts for testing
     * @param _user Address of the user
     */
    function getUserTierAmounts(address _user) external view returns (uint256[] memory) {
        return purchases[_user].tierAmounts;
    }

    /**
     * @dev Get raw vesting schedule ID for testing
     * @param _user Address of the user
     */
    function getUserVestingScheduleId(address _user) external view returns (uint256) {
        return purchases[_user].vestingScheduleId;
    }

    /**
     * @dev Get whether vesting schedule is created
     * @param _user Address of the user
     */
    function isVestingCreated(address _user) external view returns (bool) {
        return purchases[_user].vestingCreated;
    }
}