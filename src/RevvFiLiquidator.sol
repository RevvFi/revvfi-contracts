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
 * @notice Handles liquidation auctions for underwater positions using a Dutch auction mechanism
 * @dev This contract is a singleton that manages liquidation auctions across all lending markets.
 *      When a borrower's position becomes undercollateralized, the market creates an auction
 *      to sell the seized collateral to the highest bidder.
 *      
 *      Dutch Auction Mechanism:
 *      - Auction starts with a price equal to the debt amount
 *      - Price decreases by 5% (500 bps) every hour
 *      - Bids can be placed at or above the current price
 *      - Reserve price is 80% of the debt amount (minimum acceptable bid)
 *      - Late bids extend the auction by 15 minutes
 *      - Auctions without bids are automatically retried
 *      
 *      Features:
 *      - Market authorization for creating auctions
 *      - Configurable auction parameters (duration, bid increments, extension window)
 *      - Automatic auction retry on no bids
 *      - Factory-only configuration updates
 */
contract RevvFiLiquidator is ReentrancyGuard, IRevvFiLiquidator {
    using SafeERC20 for IERC20;

    // ============================================================
    //                    Immutable References
    // ============================================================
    
    /// @dev Factory contract that deployed this liquidator (immutable for security)
    address public immutable factory;

    // ============================================================
    //                    Auction State
    // ============================================================
    
    /// @dev Mapping from auction ID to auction details
    mapping(uint256 => Auction) public auctions;
    
    /// @dev Markets authorized to create auctions (set by factory)
    mapping(address => bool) public approvedMarkets;
    
    /// @dev Next available auction ID (auto-increments)
    uint256 public nextAuctionId;

    // ============================================================
    //                    Auction Parameters
    // ============================================================
    
    /// @dev Duration of each auction in seconds (default: 3 days)
    uint256 public auctionDuration = 3 days;
    
    /// @dev Minimum bid increment in basis points (default: 1% = 100 bps)
    uint256 public minBidIncrementBps = 100;
    
    /// @dev Time added to auction when a late bid is placed (default: 15 minutes)
    uint256 public auctionExtensionWindow = 15 minutes;
    
    /// @dev Time between price decreases in Dutch auction (default: 1 hour)
    uint256 public dutchAuctionStepDuration = 1 hours;
    
    /// @dev Price decrease per step in basis points (default: 5% = 500 bps)
    uint256 public dutchAuctionPriceDecrementBps = 500;

    // ============================================================
    //                    Modifiers
    // ============================================================
    
    /// @dev Restricts function calls to the factory contract only
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts function calls to approved markets (or factory during initialization)
    modifier onlyApprovedMarket() {
        if (msg.sender != factory && !approvedMarkets[msg.sender]) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
        _;
    }

    /**
     * @dev Initializes the liquidator with the factory address
     * @param _factory Address of the RevvFiFactory that will manage this liquidator
     * @notice Sets starting auction ID to 1 (0 is reserved for null)
     */
    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        nextAuctionId = 1;
    }

    /**
     * @dev Authorizes a market to create auctions
     * @param market Address of the lending market to approve
     * @notice Only callable by the factory contract
     */
    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        approvedMarkets[market] = true;
    }

    /**
     * @dev Creates a new auction for liquidated collateral
     * @param market Address of the lending market
     * @param borrower Address of the defaulted borrower
     * @param borrowAsset Token being borrowed (bids are placed in this token)
     * @param collateralAsset Token being sold in the auction
     * @param collateralAmount Amount of collateral for auction
     * @param debtAmount Amount of debt to cover (starting price)
     * @return auctionId Unique identifier for the auction
     * @notice Only callable by approved markets
     * @dev Reserve price is set to 80% of debt amount to ensure minimum recovery
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
        
        // Set reserve price at 80% to ensure minimum recovery
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
     * @dev Price decreases by dutchAuctionPriceDecrementBps every dutchAuctionStepDuration
     *      Cannot go below reservePrice (80% of original debt)
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
     * @notice Only callable by approved markets
     * @dev Called by the market after transferring collateral to this contract
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
     * @notice Bids must meet minimum requirements:
     *        - No existing bid: bid >= current price
     *        - Existing bid: bid >= highest bid + increment
     *        - Cannot exceed original debt amount
     * @dev Refunds previous highest bidder automatically
     *      Extends auction if bid placed near end
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

        // Extend auction if bid placed near end (prevents sniping)
        if (auction.endTime - block.timestamp < auctionExtensionWindow) {
            auction.endTime = block.timestamp + auctionExtensionWindow;
        }

        emit RevvFiEvents.BidPlaced(auctionId, msg.sender, bidAmount, auction.collateralAmount);
    }

    /**
     * @dev Settles auction, transferring funds and collateral to winner
     * @param auctionId ID of the auction
     * @notice Can only be called after auction end time
     * @dev If no bids received, automatically retries the auction
     *      Otherwise, transfers funds to market and collateral to winner
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
     * @notice New auction uses the same parameters but a new ID
     * @dev Collateral is already in this contract, no transfer needed
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
        
        // Mark old auction as inactive
        oldAuction.active = false;
        
        emit RevvFiEvents.AuctionCancelled(oldAuctionId);
    }

    /**
     * @dev Cancels an auction and refunds highest bidder
     * @param auctionId ID of the auction
     * @notice Only callable by the factory contract
     * @dev Used for emergency stops or auction cleanup
     */
    function cancelAuction(uint256 auctionId) external onlyFactory {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert RevvFiErrors.AuctionNotFound();

        // Refund highest bidder if any
        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            IERC20 token = IERC20(auction.borrowAsset);
            token.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        auction.active = false;
        emit RevvFiEvents.AuctionCancelled(auctionId);
    }

    // ============================================================
    //                    View Functions
    // ============================================================
    
    /**
     * @dev Returns complete auction details
     * @param auctionId ID of the auction
     * @return Auction struct with all fields
     */
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    /**
     * @dev Returns winning bid details for an auction
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

    // ============================================================
    //                    Configuration Functions
    // ============================================================
    
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
     * @param stepDuration Time between price steps in seconds
     * @param decrementBps Price decrease per step in basis points
     */
    function setDutchAuctionParams(uint256 stepDuration, uint256 decrementBps) external onlyFactory {
        dutchAuctionStepDuration = stepDuration;
        dutchAuctionPriceDecrementBps = decrementBps;
    }
}