// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IStrategicReserveVault {
    function release(address recipient, uint256 amount) external;

    function emergencyWithdraw(address token, address recipient, uint256 amount) external;

    function balance() external view returns (uint256);
}
