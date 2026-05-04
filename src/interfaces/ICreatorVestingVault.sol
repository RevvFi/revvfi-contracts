// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ICreatorVestingVault {
    function initializeVesting(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 startTime
    ) external;

    function release() external returns (uint256);
    function getClaimableAmount() external view returns (uint256);
    function getTotalVested() external view returns (uint256);
    function getRemainingLocked() external view returns (uint256);
}
