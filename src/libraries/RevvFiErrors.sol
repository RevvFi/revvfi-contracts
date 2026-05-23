// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

library RevvFiErrors {
    // ========================================================================== //
    //                              Generic Errors                                //
    // ========================================================================== //

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedCaller();
    error AlreadyInitialized();
    error NotInitialized();

    // ========================================================================== //
    //                              ArchController Errors                         //
    // ========================================================================== //

    error NotControllerFactory();
    error NotController();
    error BorrowerAlreadyExists();
    error ControllerFactoryAlreadyExists();
    error ControllerAlreadyExists();
    error MarketAlreadyExists();
    error BorrowerDoesNotExist();
    error AssetAlreadyBlacklisted();
    error ControllerFactoryDoesNotExist();
    error ControllerDoesNotExist();
    error AssetNotBlacklisted();
    error MarketDoesNotExist();
    error ZeroAddressNotAllowed();

    // ========================================================================== //
    //                           CollateralEscrow Errors                          //
    // ========================================================================== //

    error InsufficientCollateral();
    error CollateralBelowMinimum();
    error OracleNotSet();
    error InvalidDecimals();
    error OraclePriceStale();
    error InvalidCollateralRatio();
    error AlreadyLiquidating();
    error CollateralTransferFailed();

    // ========================================================================== //
    //                              Market Errors                                 //
    // ========================================================================== //

    error MarketClosed();
    error BorrowAmountTooHigh();
    error MaxAprExceeded();
    error NoOffersAvailable();
    error InsufficientLiquidity();
    error LiquidationInProgress();
    error AlreadyLiquidatingMarket();
    error NotLiquidatingMarket();
    error InsufficientRepayment();
    error PositionAlreadyRedeemed();
    error PositionNotFound();
    error NoPrincipalToClaim();
    error NoInterestToClaim();
    error EpochNotComplete();
    error WithdrawalTooEarly();
    error TooManyActivePositions();

    // ========================================================================== //
    //                              OfferBook Errors                              //
    // ========================================================================== //

    error ZeroApr();
    error OfferNotFound();
    error OfferExpired();
    error OfferNotActive();
    error InsufficientOfferAmount();
    error InvalidSeniority();
    error InsufficientLiquidityOffer();
    error MaxOffersExceeded();
    error NoActiveOffers();
    error MaxIterationsExceeded();

    // ========================================================================== //
    //                           PositionNFT Errors                               //
    // ========================================================================== //

    error PositionNotFoundNFT();
    error PositionAlreadyFinalized();
    error MarketAlreadyRegistered();
    error MarketNotRegistered();

    // ========================================================================== //
    //                           Liquidator Errors                                //
    // ========================================================================== //

    error AuctionNotFound();
    error AuctionNotActive();
    error AuctionEnded();
    error BidTooLow();
    error AuctionAlreadySettled();
    error NoBids();
    error LiquidationNotActive();
    error TransferFailed();
    error AuctionCollateralNotReceived();

    // ========================================================================== //
    //                              Factory Errors                                //
    // ========================================================================== //

    error BorrowerNotRegistered();
    error InsufficientFee();
    error DeploymentFailed();
    error PendingArchControllerNotSet();
    error FeeTransferFailed();

    // ========================================================================== //
    //                           Reputation Errors                                //
    // ========================================================================== //

    error BorrowerNotRegisteredForReputation();
}
