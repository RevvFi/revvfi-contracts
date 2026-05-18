// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RevvFiLiquidator
 * @notice Handles auction-based liquidation of undercollateralized positions
 */
contract RevvFiLiquidator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

    error ZeroAddress();
    error ZeroAmount();
    error AuctionNotFound();
    error AuctionNotActive();
    error AuctionEnded();
    error BidTooLow();
    error UnauthorizedCaller();
    error AlreadyLiquidating();

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed market,
        address indexed borrower,
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
        uint256 bidAmount,
        uint256 collateralAmount
    );
    event AuctionCancelled(uint256 indexed auctionId);

    // ========================================================================== //
    //                                   Structs                                   //
    // ========================================================================== //

    struct Auction {
        uint256 id;
        address market;
        address borrower;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBid;
        address highestBidder;
        bool active;
        bool settled;
    }

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    address public immutable factory;
    mapping(uint256 => Auction) public auctions;
    uint256 public nextAuctionId;
    uint256 public auctionDuration = 3 days; // Default auction duration

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        nextAuctionId = 1;
    }

    // ========================================================================== //
    //                             Auction Management                              //
    // ========================================================================== //

    /**
     * @dev Create a new liquidation auction (called by market)
     */
    function createAuction(
        address market,
        address borrower,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external onlyFactory returns (uint256 auctionId) {
        auctionId = nextAuctionId++;

        auctions[auctionId] = Auction({
            id: auctionId,
            market: market,
            borrower: borrower,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionDuration,
            highestBid: 0,
            highestBidder: address(0),
            active: true,
            settled: false
        });

        emit AuctionCreated(
            auctionId,
            market,
            borrower,
            collateralAmount,
            debtAmount,
            block.timestamp,
            block.timestamp + auctionDuration
        );
    }

    /**
     * @dev Place a bid on an auction
     * @param auctionId Auction ID
     * @param bidAmount Amount of debt to cover (in borrowAsset)
     */
    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();
        if (block.timestamp > auction.endTime) revert AuctionEnded();
        if (bidAmount <= auction.highestBid) revert BidTooLow();
        if (bidAmount > auction.debtAmount) revert BidTooLow();

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            IERC20 token = IERC20(auction.market); // borrowAsset from market
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        // Transfer bid amount from bidder
        IERC20 token = IERC20(auction.market);
        token.safeTransferFrom(msg.sender, address(this), bidAmount);

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, bidAmount, auction.collateralAmount);
    }

    /**
     * @dev Settle an auction after it ends (anyone can call)
     */
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();
        if (block.timestamp <= auction.endTime) revert AuctionNotActive();
        if (auction.settled) revert AuctionEnded();

        auction.active = false;
        auction.settled = true;

        emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBid, auction.collateralAmount);
    }

    /**
     * @dev Cancel an auction (if liquidation was resolved)
     */
    function cancelAuction(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotFound();

        // Return bid amount to highest bidder if any
        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            IERC20 token = IERC20(auction.market);
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        auction.active = false;
        emit AuctionCancelled(auctionId);
    }

    /**
     * @dev Get auction details
     */
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    /**
     * @dev Get winning bid details for settlement
     */
    function getWinningBid(uint256 auctionId) external view returns (address winner, uint256 bidAmount, uint256 collateralAmount) {
        Auction storage auction = auctions[auctionId];
        return (auction.highestBidder, auction.highestBid, auction.collateralAmount);
    }

    /**
     * @dev Set auction duration (admin only via factory)
     */
    function setAuctionDuration(uint256 newDuration) external onlyFactory {
        auctionDuration = newDuration;
    }
}