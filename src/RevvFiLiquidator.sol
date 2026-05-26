// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiLiquidator.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiLiquidator
 * @author Preet Singh
 * @notice Handles liquidation auctions for underwater positions using Dutch auction mechanism
 * @dev Creates and manages auctions for collateral seized from liquidated positions
 */
contract RevvFiLiquidator is ReentrancyGuard, IRevvFiLiquidator {
    using SafeERC20 for IERC20;

    /// @dev Factory contract that deployed this liquidator
    address public immutable factory;

    /// @dev Mapping from auction ID to auction details
    mapping(uint256 => Auction) public auctions;

    /// @dev Markets authorized to create auctions
    mapping(address => bool) public approvedMarkets;

    /// @dev Next available auction ID
    uint256 public nextAuctionId;

    /// @dev Duration of each auction in seconds
    uint256 public auctionDuration = 3 days;

    /// @dev Minimum bid increment in basis points (1% = 100)
    uint256 public minBidIncrementBps = 100;

    /// @dev Time added to auction when a late bid is placed
    uint256 public auctionExtensionWindow = 15 minutes;

    /// @dev Time between price decreases in Dutch auction
    uint256 public dutchAuctionStepDuration = 1 hours;

    /// @dev Price decrease per step in basis points (5% = 500)
    uint256 public dutchAuctionPriceDecrementBps = 500;

    /// @dev Restricts function calls to the factory contract
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts function calls to approved markets
    modifier onlyApprovedMarket() {
        if (msg.sender != factory && !approvedMarkets[msg.sender]) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
        _;
    }

    /**
     * @dev Sets up liquidator with factory address
     * @param _factory Address of the RevvFiFactory
     */
    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        nextAuctionId = 1;
    }

    /**
     * @dev Authorizes a market to create auctions (factory only)
     * @param market Address of the lending market
     */
    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        approvedMarkets[market] = true;
    }

    /**
     * @dev Creates a new auction for liquidated collateral
     * @param market Address of the lending market
     * @param borrower Address of the defaulted borrower
     * @param borrowAsset Token being borrowed
     * @param collateralAsset Token being sold
     * @param collateralAmount Amount of collateral for auction
     * @param debtAmount Amount of debt to cover
     * @return auctionId Unique identifier for the auction
     */
    function createAuction(
        address market,
        address borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) public onlyApprovedMarket returns (uint256 auctionId) {
        auctionId = nextAuctionId++;

        // Reserve price is 80% of debt to ensure minimum recovery
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

    /**
     * @dev Calculates current price in Dutch auction based on elapsed time
     * @param auctionId ID of the auction
     * @return currentPrice Current price in borrow asset units
     */
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

    /**
     * @dev Records that collateral has been transferred to the liquidator
     * @param auctionId ID of the auction
     */
    function receiveCollateral(uint256 auctionId) external onlyApprovedMarket {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        auction.collateralTransferred = true;
    }

    /**
     * @dev Places a bid on an active auction
     * @param auctionId ID of the auction
     * @param bidAmount Amount to bid in borrow asset units
     */
    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        if (block.timestamp > auction.endTime) revert RevvFiErrors.AuctionEnded();

        uint256 currentPrice = getCurrentPrice(auctionId);

        // Calculate minimum acceptable bid
        uint256 minBid = auction.highestBid == 0
            ? currentPrice
            : auction.highestBid + (auction.highestBid * minBidIncrementBps / 10000);
        if (bidAmount < minBid) revert RevvFiErrors.BidTooLow();
        if (bidAmount > auction.debtAmount) revert RevvFiErrors.BidTooLow();

        IERC20 token = IERC20(auction.borrowAsset);

        // Refund previous highest bidder
        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        // Collect new bid
        token.safeTransferFrom(msg.sender, address(this), bidAmount);

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;

        // Extend auction if bid placed near end
        if (auction.endTime - block.timestamp < auctionExtensionWindow) {
            auction.endTime = block.timestamp + auctionExtensionWindow;
        }

        emit RevvFiEvents.BidPlaced(auctionId, msg.sender, bidAmount, auction.collateralAmount);
    }

    /**
     * @dev Settles auction, transferring funds and collateral to winner
     * @param auctionId ID of the auction
     */
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();
        if (block.timestamp <= auction.endTime) revert RevvFiErrors.AuctionNotActive();
        if (auction.settled) revert RevvFiErrors.AuctionAlreadySettled();

        // No bids received, retry with lower starting price
        if (auction.highestBidder == address(0)) {
            _retryAuction(auctionId);
            return;
        }

        // Transfer funds to market
        IERC20 borrowToken = IERC20(auction.borrowAsset);
        borrowToken.safeTransfer(auction.market, auction.highestBid);

        // Transfer collateral to winner
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

    /**
     * @dev Creates a new auction when previous one receives no bids
     * @param oldAuctionId ID of the failed auction
     */
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

        // IMPORTANT: No token transfer needed - collateral is already in this contract

        oldAuction.active = false;

        emit RevvFiEvents.AuctionCancelled(oldAuctionId);
    }

    /**
     * @dev Cancels an auction and refunds highest bidder (factory only)
     * @param auctionId ID of the auction
     */
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

    /**
     * @dev Returns complete auction details
     * @param auctionId ID of the auction
     * @return Auction struct with all fields
     */
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    /**
     * @dev Returns winning bid details
     * @param auctionId ID of the auction
     * @return winner Address of highest bidder
     * @return bidAmount Amount of highest bid
     * @return collateralAmount Amount of collateral for sale
     */
    function getWinningBid(uint256 auctionId)
        external
        view
        returns (address winner, uint256 bidAmount, uint256 collateralAmount)
    {
        Auction storage auction = auctions[auctionId];
        return (auction.highestBidder, auction.highestBid, auction.collateralAmount);
    }

    /**
     * @dev Updates auction duration (factory only)
     * @param newDuration New duration in seconds
     */
    function setAuctionDuration(uint256 newDuration) external onlyFactory {
        auctionDuration = newDuration;
    }

    /**
     * @dev Updates minimum bid increment (factory only)
     * @param newIncrementBps New increment in basis points
     */
    function setMinBidIncrementBps(uint256 newIncrementBps) external onlyFactory {
        minBidIncrementBps = newIncrementBps;
    }

    /**
     * @dev Updates auction extension window (factory only)
     * @param newWindow New window in seconds
     */
    function setAuctionExtensionWindow(uint256 newWindow) external onlyFactory {
        auctionExtensionWindow = newWindow;
    }

    /**
     * @dev Updates Dutch auction parameters (factory only)
     * @param stepDuration Time between price steps
     * @param decrementBps Price decrease per step in basis points
     */
    function setDutchAuctionParams(uint256 stepDuration, uint256 decrementBps) external onlyFactory {
        dutchAuctionStepDuration = stepDuration;
        dutchAuctionPriceDecrementBps = decrementBps;
    }
}
