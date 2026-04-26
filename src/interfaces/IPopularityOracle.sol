// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IPopularityOracle {
    function updateScore(
        address bootstrapper,
        uint256 score
    ) external;

    function calculateScore(
        address bootstrapper
    ) external view returns (uint256);
}