// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IRevvFiMarket {
    function depositCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function borrow(uint256 amount, bool useSeniorOnly, uint256 maxApr) external;
    function repay(uint256 amount) external;
    function repayFull() external;
    function closeMarket() external;
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration) external;
    function cancelOffer(uint256 offerId) external;
    function claimInterest(uint256 positionId) external;
    function claimPrincipal(uint256 positionId) external;
    function liquidate() external;
    function startLiquidation() external;
    function endLiquidation() external;
    function totalDebt() external view returns (uint256);
    function isClosed() external view returns (bool);
    function totalAssets() external view returns (uint256);
    function getCollateralRatio() external view returns (uint256);
    function isHealthy() external view returns (bool);
    function isLiquidatable() external view returns (bool);
    function getMaxBorrowable() external view returns (uint256);
    function getTotalOwed() external view returns (uint256);
    function getCurrentDebtIndex() external view returns (uint256);
    function getActivePositionsCount() external view returns (uint256);
    function getActivePositionsPaginated(uint256 start, uint256 limit) external view returns (uint256[] memory);
}
