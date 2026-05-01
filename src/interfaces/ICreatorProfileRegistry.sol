// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ICreatorProfileRegistry {
    function recordLaunch(
        address creator,
        uint256 launchId,
        address bootstrapper,
        uint256 targetLiquidityETH
    ) external;
    
    function canCreateLaunch(address creator) external view returns (bool, string memory);
    function getProfile(address creator) external view returns (
        string memory name,
        string memory website,
        string memory twitter,
        string memory github,
        bool kycVerified,
        uint256 successfulLaunches,
        uint256 failedLaunches,
        uint256 reputationScore
    );
}