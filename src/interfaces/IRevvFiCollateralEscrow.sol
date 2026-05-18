// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IRevvFiCollateralEscrow {
    function depositCollateral(address borrower, uint256 amount) external;
    function withdrawCollateral(address borrower, uint256 amount) external;
    function liquidate(address borrower, uint256 collateralToSeize, uint256 debtToCover, address liquidator) external returns (uint256, uint256);
    function getCollateralRatio(address borrower, uint256 debt) external view returns (uint256);
    function getCollateralBalance(address borrower) external view returns (uint256);
    function isHealthy(address borrower, uint256 debt) external view returns (bool);
    function isLiquidatable(address borrower, uint256 debt) external view returns (bool);
    function getMaxBorrowable(address borrower) external view returns (uint256);
    function minCollateralRatio() external view returns (uint256);
    function liquidationThreshold() external view returns (uint256);
    function setMinCollateralRatio(uint256 newRatio) external;
    function setLiquidationThreshold(uint256 newThreshold) external;
}