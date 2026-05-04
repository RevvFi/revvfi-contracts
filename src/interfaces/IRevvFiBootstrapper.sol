// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiBootstrapper {
    function shares(address user) external view returns (uint256);

    function totalShares() external view returns (uint256);

    function launched() external view returns (bool);

    function failed() external view returns (bool);

    function creator() external view returns (address);

    function emergencyPause() external;
}
