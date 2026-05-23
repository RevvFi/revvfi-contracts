// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiLiquidator {
    struct Auction {
        uint256 id;
        address market;
        address borrower;
        address borrowAsset;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 reservePrice;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBid;
        address highestBidder;
        bool active;
        bool settled;
        bool collateralTransferred;
    }

    function createAuction(
        address market,
        address borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external returns (uint256);
    function placeBid(uint256 auctionId, uint256 bidAmount) external;
    function settleAuction(uint256 auctionId) external;
    function cancelAuction(uint256 auctionId) external;
    function getAuction(uint256 auctionId) external view returns (Auction memory);
    function getWinningBid(uint256 auctionId) external view returns (address, uint256, uint256);
    function receiveCollateral(uint256 auctionId) external;
    function getCurrentPrice(uint256 auctionId) external view returns (uint256);
}
