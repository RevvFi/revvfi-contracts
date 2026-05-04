// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IPopularityOracle {
    function updateScore(address bootstrapper, uint256 score) external;

    function calculateScore(address bootstrapper) external view returns (uint256);
    function getScoreDetails(address bootstrapper)
        external
        view
        returns (
            uint256 score,
            uint256 lastUpdateTime,
            uint256 depositVelocity,
            uint256 uniqueDepositors,
            uint256 socialScore,
            uint256 creatorReputation,
            uint256 timeToTargetScore
        );
}
