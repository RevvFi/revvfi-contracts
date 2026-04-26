// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ICreatorVestingVault {
    function claim() external;

    function vestedAmount() external view returns (uint256);

    function releasableAmount() external view returns (uint256);
}