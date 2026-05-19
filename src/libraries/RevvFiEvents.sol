// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/**
 * @title RevvFiEvents
 * @notice Centralized event definitions for all RevvFi contracts
 * @dev All protocol contracts should import and use these events
 */
library RevvFiEvents {
    // ========================================================================== //
    //                           ArchController Events                            //
    // ========================================================================== //

    event MarketAdded(address indexed controller, address market);
    event MarketRemoved(address market);
    event ControllerFactoryAdded(address controllerFactory);
    event ControllerFactoryRemoved(address controllerFactory);
    event BorrowerAdded(address borrower);
    event BorrowerRemoved(address borrower);
    event AssetBlacklisted(address asset);
    event AssetPermitted(address asset);
    event ControllerAdded(address indexed controllerFactory, address controller);
    event ControllerRemoved(address controller);

    // ========================================================================== //
    //                           CollateralEscrow Events                          //
    // ========================================================================== //

    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event CollateralLiquidated(address indexed borrower, uint256 collateralAmount, uint256 debtAmount);
    event MinCollateralRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event OracleUpdated(address indexed collateralAsset, address oracle, uint8 decimals);
    event LiquidationStarted(address indexed borrower);
    event LiquidationEnded(address indexed borrower);

    // ========================================================================== //
    //                              Market Events                                 //
    // ========================================================================== //

    event Borrow(address indexed borrower, uint256 amount, uint256 weightedApr);
    event Repay(address indexed borrower, uint256 amount, uint256 interestPortion, uint256 principalPortion);
    event DrawdownExecuted(uint256 totalAmount, uint256 weightedApr, uint256[] positionIds);
    event MarketClosedEvent(address indexed borrower, uint256 timestamp);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 auctionId);
    event InterestAccrued(address indexed borrower, uint256 interestAmount);
    event LenderRepaid(address indexed lender, uint256 positionId, uint256 principal, uint256 interest);
    event LenderWithdrawn(address indexed lender, uint256 positionId, uint256 amount);
    event ContractsSet();
    event LiquidationStartedMarket(address indexed borrower);
    event LiquidationEndedMarket(address indexed borrower);
    event PositionSettled(uint256 indexed positionId, uint256 principalAmount, uint256 interestAmount);

    // ========================================================================== //
    //                              OfferBook Events                              //
    // ========================================================================== //

    event OfferSubmitted(
        uint256 indexed offerId, address indexed lender, uint256 amount, uint256 apr, uint8 seniority, uint256 expiry
    );
    event OfferCancelled(uint256 indexed offerId, address indexed lender);
    event OfferFilled(uint256 indexed offerId, address indexed lender, uint256 amountFilled);
    event DrawdownExecutedOffer(address indexed borrower, uint256 totalAmount, uint256 weightedApr);

    // ========================================================================== //
    //                           PositionNFT Events                               //
    // ========================================================================== //

    event PositionMinted(
        uint256 indexed tokenId,
        address indexed lender,
        address indexed market,
        uint256 principal,
        uint256 apr,
        uint8 seniority
    );
    event PositionBurned(uint256 indexed tokenId);
    event InterestClaimed(uint256 indexed tokenId, address indexed lender, uint256 amount);
    event PositionRedeemed(uint256 indexed tokenId, uint256 principalAmount, uint256 interestAmount);
    event MarketRegistered(address indexed market);
    event MarketUnregistered(address indexed market);

    // ========================================================================== //
    //                           Liquidator Events                                //
    // ========================================================================== //

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed market,
        address indexed borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 startTime,
        uint256 endTime
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 bidAmount, uint256 collateralAmount);
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 bidAmount,
        uint256 debtRepaid
    );
    event AuctionCancelled(uint256 indexed auctionId);

    // ========================================================================== //
    //                              Factory Events                                //
    // ========================================================================== //

    event MarketDeployed(
        address indexed market,
        address indexed borrower,
        address borrowAsset,
        address collateralAsset,
        address collateralOracle,
        uint256 timestamp
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ArchControllerUpdateRequested(address indexed newArchController);
    event ArchControllerUpdated(address indexed oldArchController, address indexed newArchController);
}
