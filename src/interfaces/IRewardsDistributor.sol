// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRewardsDistributor {
    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external;

    function distribute(address user, uint256 amount) external;

    function notifyRewardAmount(uint256 amount) external;
}
