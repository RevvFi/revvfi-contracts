// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiFactory {
    function updateLaunchSuccess(uint256 launchId, uint256 maturityTime) external;
    function updateLaunchFailure(uint256 launchId) external;
    function updateLaunchRewardsInitialized(uint256 launchId) external;
    function isDeployed(address bootstrapper) external view returns (bool);
}
