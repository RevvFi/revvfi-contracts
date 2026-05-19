// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RevvFiLiquidator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error AuctionNotFound();
    error AuctionNotActive();
    error AuctionEnded();
    error BidTooLow();
    error UnauthorizedCaller();
    error AuctionAlreadySettled();
    error NoBids();
    error LiquidationNotActive();
    error TransferFailed();

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
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bidAmount,
        uint256 collateralAmount
    );
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 bidAmount,
        uint256 debtRepaid
    );
    event AuctionCancelled(uint256 indexed auctionId);

    struct Auction {
        uint256 id;
        address market;
        address borrower;
        address borrowAsset;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBid;
        address highestBidder;
        bool active;
        bool settled;
        bool collateralTransferred;
    }

    address public immutable factory;
    mapping(uint256 => Auction) public auctions;
    uint256 public nextAuctionId;
    uint256 public auctionDuration = 3 days;
    uint256 public minBidIncrementBps = 100;
    uint256 public auctionExtensionWindow = 15 minutes;

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
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
    ) external onlyFactory returns (uint256 auctionId) {
        auctionId = nextAuctionId++;

        auctions[auctionId] = Auction({
            id: auctionId,
            market: market,
            borrower: borrower,
            borrowAsset: borrowAsset,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionDuration,
            highestBid: 0,
            highestBidder: address(0),
            active: true,
            settled: false,
            collateralTransferred: false
        });

        emit AuctionCreated(
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

    function receiveCollateral(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();
        auction.collateralTransferred = true;
    }

    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();
        if (block.timestamp > auction.endTime) revert AuctionEnded();
        
        uint256 minBid = auction.highestBid == 0 
            ? 1 
            : auction.highestBid + (auction.highestBid * minBidIncrementBps / 10000);
        if (bidAmount < minBid) revert BidTooLow();
        if (bidAmount > auction.debtAmount) revert BidTooLow();

        // REFUND PREVIOUS BIDDER - Critical fix
        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            IERC20 token = IERC20(auction.borrowAsset);
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        // Transfer new bid amount
        IERC20 token = IERC20(auction.borrowAsset);
        token.safeTransferFrom(msg.sender, address(this), bidAmount);

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;

        if (auction.endTime - block.timestamp < auctionExtensionWindow) {
            auction.endTime = block.timestamp + auctionExtensionWindow;
        }

        emit BidPlaced(auctionId, msg.sender, bidAmount, auction.collateralAmount);
    }

    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();
        if (block.timestamp <= auction.endTime) revert AuctionNotActive();
        if (auction.settled) revert AuctionAlreadySettled();

        if (auction.highestBidder == address(0)) revert NoBids();

        // Transfer bid amount to market to reduce debt
        IERC20 borrowToken = IERC20(auction.borrowAsset);
        borrowToken.safeTransfer(auction.market, auction.highestBid);

        // Transfer collateral to winner
        IERC20 collateralToken = IERC20(auction.collateralAsset);
        collateralToken.safeTransfer(auction.highestBidder, auction.collateralAmount);

        auction.active = false;
        auction.settled = true;

        emit AuctionSettled(
            auctionId,
            auction.highestBidder,
            auction.collateralAsset,
            auction.collateralAmount,
            auction.highestBid,
            auction.highestBid
        );
    }

    function cancelAuction(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();

        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            IERC20 token = IERC20(auction.borrowAsset);
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        auction.active = false;
        emit AuctionCancelled(auctionId);
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    function getWinningBid(
        uint256 auctionId
    ) external view returns (address winner, uint256 bidAmount, uint256 collateralAmount) {
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
}