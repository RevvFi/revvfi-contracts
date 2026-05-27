// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiMarket {
    struct Offer {
        uint256 id;
        address lender;
        uint256 amount;
        uint256 remainingAmount;
        uint256 apr;
        uint8 seniority;
        uint256 expiry;
        bool active;
        bool isSenior;
    }

    // Core functions
    function depositCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function borrow(uint256 amount, bool useSeniorOnly, uint256 maxApr) external;
    function repay(uint256 amount) external;
    function repayFull() external;
    function closeMarket() external;

    // Offer management
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration) external;
    function cancelOffer(uint256 offerId) external;

    // Claim functions
    function claimFunds(uint256 positionId) external;

    // Liquidation
    function liquidate() external;
    function startLiquidation() external;
    function endLiquidation() external;

    // View functions
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
    function getPositionClaimable(uint256 positionId) external view returns (uint256);
    function getPositionValue(uint256 positionId) external view returns (uint256);

    // Initialization (only callable by factory)
    function initialize(
        address _factory,
        address _archController,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset
    ) external;
    function setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator,
        address _reputationRegistry
    ) external;
}
