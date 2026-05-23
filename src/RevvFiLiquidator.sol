// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiLiquidator.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiLiquidator is ReentrancyGuard, IRevvFiLiquidator {
    using SafeERC20 for IERC20;

    address public immutable factory;
    mapping(uint256 => Auction) public auctions;
    uint256 public nextAuctionId;
    uint256 public auctionDuration = 3 days;
    uint256 public minBidIncrementBps = 100;
    uint256 public auctionExtensionWindow = 15 minutes;
    uint256 public dutchAuctionStepDuration = 1 hours;
    uint256 public dutchAuctionPriceDecrementBps = 500;

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        nextAuctionId = 1;
    }

    function createAuction(
        address market,
        address borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) public onlyFactory returns (uint256 auctionId) {
        auctionId = nextAuctionId++;

        uint256 reservePrice = (debtAmount * 80) / 100;

        auctions[auctionId] = Auction({
            id: auctionId,
            market: market,
            borrower: borrower,
            borrowAsset: borrowAsset,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            reservePrice: reservePrice,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionDuration,
            highestBid: 0,
            highestBidder: address(0),
            active: true,
            settled: false,
            collateralTransferred: false
        });

        emit RevvFiEvents.AuctionCreated(
            auctionId,
            market,
            borrower,
            borrowAsset,
            collateralAsset,
            collateralAmount,
            debtAmount,
            block.timestamp,
            block.timestamp + auctionDuration
        );
    }

    function getCurrentPrice(uint256 auctionId) public view returns (uint256 currentPrice) {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) return 0;

        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 steps = elapsed / dutchAuctionStepDuration;

        uint256 priceDecrement = (auction.debtAmount * dutchAuctionPriceDecrementBps * steps) / (10000);

        if (priceDecrement >= auction.debtAmount - auction.reservePrice) {
            currentPrice = auction.reservePrice;
        } else {
            currentPrice = auction.debtAmount - priceDecrement;
        }
    }

    function receiveCollateral(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        auction.collateralTransferred = true;
    }

    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        if (block.timestamp > auction.endTime) revert RevvFiErrors.AuctionEnded();

        uint256 currentPrice = getCurrentPrice(auctionId);

        uint256 minBid = auction.highestBid == 0
            ? currentPrice
            : auction.highestBid + (auction.highestBid * minBidIncrementBps / 10000);
        if (bidAmount < minBid) revert RevvFiErrors.BidTooLow();
        if (bidAmount > auction.debtAmount) revert RevvFiErrors.BidTooLow();

        IERC20 token = IERC20(auction.borrowAsset);

        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        token.safeTransferFrom(msg.sender, address(this), bidAmount);

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;

        if (auction.endTime - block.timestamp < auctionExtensionWindow) {
            auction.endTime = block.timestamp + auctionExtensionWindow;
        }

        emit RevvFiEvents.BidPlaced(auctionId, msg.sender, bidAmount, auction.collateralAmount);
    }

    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        if (block.timestamp <= auction.endTime) revert RevvFiErrors.AuctionNotActive();
        if (auction.settled) revert RevvFiErrors.AuctionAlreadySettled();

        if (auction.highestBidder == address(0)) {
            _retryAuction(auctionId);
            return;
        }

        IERC20 borrowToken = IERC20(auction.borrowAsset);
        borrowToken.safeTransfer(auction.market, auction.highestBid);

        IERC20 collateralToken = IERC20(auction.collateralAsset);
        collateralToken.safeTransfer(auction.highestBidder, auction.collateralAmount);

        auction.active = false;
        auction.settled = true;

        emit RevvFiEvents.AuctionSettled(
            auctionId,
            auction.highestBidder,
            auction.collateralAsset,
            auction.collateralAmount,
            auction.highestBid,
            auction.highestBid
        );
    }

    function _retryAuction(uint256 oldAuctionId) internal {
        Auction storage oldAuction = auctions[oldAuctionId];

        uint256 newAuctionId = createAuction(
            oldAuction.market,
            oldAuction.borrower,
            oldAuction.borrowAsset,
            oldAuction.collateralAsset,
            oldAuction.collateralAmount,
            oldAuction.debtAmount
        );

        IERC20 collateralToken = IERC20(oldAuction.collateralAsset);
        collateralToken.safeTransfer(address(this), oldAuction.collateralAmount);

        oldAuction.active = false;

        emit RevvFiEvents.AuctionCancelled(oldAuctionId);
    }

    function cancelAuction(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();

        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            IERC20 token = IERC20(auction.borrowAsset);
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        auction.active = false;
        emit RevvFiEvents.AuctionCancelled(auctionId);
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    function getWinningBid(uint256 auctionId)
        external
        view
        returns (address winner, uint256 bidAmount, uint256 collateralAmount)
    {
        Auction storage auction = auctions[auctionId];
        return (auction.highestBidder, auction.highestBid, auction.collateralAmount);
    }

    function setAuctionDuration(uint256 newDuration) external onlyFactory {
        auctionDuration = newDuration;
    }

    function setMinBidIncrementBps(uint256 newIncrementBps) external onlyFactory {
        minBidIncrementBps = newIncrementBps;
    }

    function setAuctionExtensionWindow(uint256 newWindow) external onlyFactory {
        auctionExtensionWindow = newWindow;
    }

    function setDutchAuctionParams(uint256 stepDuration, uint256 decrementBps) external onlyFactory {
        dutchAuctionStepDuration = stepDuration;
        dutchAuctionPriceDecrementBps = decrementBps;
    }
}
