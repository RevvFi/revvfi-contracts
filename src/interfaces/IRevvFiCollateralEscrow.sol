// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiCollateralEscrow {
    enum HealthStatus {
        HEALTHY,
        WARNING,
        LIQUIDATABLE
    }

    // Initialization function (only callable by factory)
    function initialize(
        address _factory,
        address _market,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset,
        address _collateralOracle,
        uint8 _collateralDecimals,
        uint8 _borrowDecimals
    ) external;

    // Core functions
    function depositCollateral(address borrower, uint256 amount) external;
    function withdrawCollateral(address borrower, uint256 amount, uint256 currentDebt) external;
    function liquidate(address borrower, uint256 collateralToSeize, uint256 debtToCover, address liquidator)
        external
        returns (uint256, uint256);

    // View functions
    function getCollateralRatio(address borrower, uint256 debt) external view returns (uint256);
    function getCollateralBalance(address borrower) external view returns (uint256);
    function isHealthy(address borrower, uint256 debt) external view returns (bool);
    function isLiquidatable(address borrower, uint256 debt) external view returns (bool);
    function getHealthStatus(address borrower, uint256 debt) external view returns (HealthStatus);
    function getMaxBorrowable(address borrower) external view returns (uint256);
    function minCollateralRatio() external view returns (uint256);
    function liquidationThreshold() external view returns (uint256);
    function getCollateralValue(address borrower) external view returns (uint256 value, uint256 amount);
    function isLiquidationActive() external view returns (bool);

    // Liquidation management
    function startLiquidation() external;
    function endLiquidation() external;

    // Configuration (only factory)
    function setMinCollateralRatio(uint256 newRatio) external;
    function setLiquidationThreshold(uint256 newThreshold) external;
}
