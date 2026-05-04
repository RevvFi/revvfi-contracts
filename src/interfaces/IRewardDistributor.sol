// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRewardDistributor {
    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external;
    function addClaimer(address claimer) external;
    function addClaimers(address[] calldata claimers) external;
    function removeClaimer(address claimer) external;
    function claimRewards() external returns (uint256);
    function getClaimableRewards(address claimer) external view returns (uint256);
    function updateEmissionRate(uint256 newEmissionRate) external;
    function extendSchedule(uint256 newEndTime, uint256 additionalTokens) external;
    function addRewards(uint256 additionalTokens) external;
    function pause() external;
    function unpause() external;
    function notifyRewardAmount(uint256 amount) external;
    function distribute(address user, uint256 amount) external;
}
