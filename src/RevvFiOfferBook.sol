// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiOfferBook
 * @author Preet Singh
 * @notice Manages lending offers and matches them with borrowing requests
 * @dev Uses a priority system to fill borrow requests with the lowest APR offers first
 */
contract RevvFiOfferBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @dev Represents a single lending offer
     * @param id Unique offer identifier
     * @param lender Address of the lender
     * @param amount Original offer amount
     * @param remainingAmount Amount still available for borrowing
     * @param apr Annual percentage rate in basis points
     * @param seniority 0 for senior, 1 for junior
     * @param expiry Timestamp when offer expires
     * @param active Whether the offer is active
     * @param isSenior True if senior offer
     */
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

    /// @dev Maximum offers per lender to prevent spam
    uint256 public constant MAX_OFFERS_PER_LENDER = 20;

    /// @dev Maximum active offers globally
    uint256 public constant MAX_ACTIVE_OFFERS_GLOBAL = 500;

    /// @dev Minimum offer amount (100 USDC equivalent)
    uint256 public constant MIN_OFFER_AMOUNT = 100e6;

    /// @dev Maximum iterations for offer selection to prevent gas bombs
    uint256 public constant MAX_ITERATIONS = 100;

    /// @dev Batch size for cleaning up expired offers
    uint256 public constant EXPIRY_CLEANUP_BATCH_SIZE = 50;

    /// @dev Factory that deployed this offer book
    address public immutable factory;

    /// @dev Associated market contract
    address public market;

    /// @dev Token being borrowed/lent
    address public borrowAsset;

    /// @dev Mapping from offer ID to offer details
    mapping(uint256 => Offer) public offers;

    /// @dev Offers created by each lender
    mapping(address => uint256[]) public lenderOfferIds;

    /// @dev Quick lookup for active offers
    mapping(uint256 => bool) public isActiveOffer;

    /// @dev Next available offer ID
    uint256 public nextOfferId;

    /// @dev Total liquidity available from all active offers
    uint256 public totalLiquidityAvailable;

    /// @dev Number of active offers
    uint256 public activeOfferCount;

    /// @dev List of active offer IDs for efficient iteration
    uint256[] private _activeOfferIds;

    /// @dev Maps active offer ID to its index in the list
    mapping(uint256 => uint256) private _activeOfferIndex;

    /// @dev Whether contract has been initialized
    bool public isInitialized;

    /// @dev Restricts to the associated market
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts to the factory contract
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Sets up offer book with factory address
     * @param _factory Address of the RevvFiFactory
     */
    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        nextOfferId = 1;
        isInitialized = false;
        activeOfferCount = 0;
    }

    /**
     * @dev Initializes offer book with market and borrow asset (factory only)
     * @param _market Address of the associated market
     * @param _borrowAsset Token being borrowed/lent
     */
    function initialize(address _market, address _borrowAsset) external onlyFactory {
        if (isInitialized) revert RevvFiErrors.UnauthorizedCaller();
        if (_market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrowAsset == address(0)) revert RevvFiErrors.ZeroAddress();

        market = _market;
        borrowAsset = _borrowAsset;
        isInitialized = true;
    }

    /**
     * @dev Adds offer to active tracking list
     * @param offerId ID of offer to add
     */
    function _addToActiveList(uint256 offerId) internal {
        isActiveOffer[offerId] = true;
        _activeOfferIndex[offerId] = _activeOfferIds.length;
        _activeOfferIds.push(offerId);
        activeOfferCount++;
    }

    /**
     * @dev Removes offer from active tracking list
     * @param offerId ID of offer to remove
     */
    function _removeFromActiveList(uint256 offerId) internal {
        if (!isActiveOffer[offerId]) return;

        uint256 index = _activeOfferIndex[offerId];
        uint256 lastId = _activeOfferIds[_activeOfferIds.length - 1];

        // Swap with last element and pop for efficiency
        _activeOfferIds[index] = lastId;
        _activeOfferIndex[lastId] = index;
        _activeOfferIds.pop();

        delete _activeOfferIndex[offerId];
        isActiveOffer[offerId] = false;
        activeOfferCount--;
    }

    /**
     * @dev Creates a new lending offer
     * @param amount Amount to lend
     * @param apr Annual percentage rate in basis points
     * @param seniority 0 for senior, 1 for junior
     * @param duration Offer duration in seconds
     * @return offerId Unique identifier for the offer
     */
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (amount < MIN_OFFER_AMOUNT) revert RevvFiErrors.ZeroAmount();
        if (apr == 0) revert RevvFiErrors.ZeroApr();
        if (seniority > 1) revert RevvFiErrors.InvalidSeniority();
        if (duration == 0) revert RevvFiErrors.ZeroAmount();
        if (activeOfferCount >= MAX_ACTIVE_OFFERS_GLOBAL) revert RevvFiErrors.MaxOffersExceeded();
        if (lenderOfferIds[msg.sender].length >= MAX_OFFERS_PER_LENDER) revert RevvFiErrors.MaxOffersExceeded();

        IERC20 token = IERC20(borrowAsset);
        token.safeTransferFrom(msg.sender, address(this), amount);

        offerId = nextOfferId++;

        offers[offerId] = Offer({
            id: offerId,
            lender: msg.sender,
            amount: amount,
            remainingAmount: amount,
            apr: apr,
            seniority: seniority,
            expiry: block.timestamp + duration,
            active: true,
            isSenior: seniority == 0
        });

        lenderOfferIds[msg.sender].push(offerId);
        _addToActiveList(offerId);
        totalLiquidityAvailable += amount;

        emit RevvFiEvents.OfferSubmitted(offerId, msg.sender, amount, apr, seniority, block.timestamp + duration);
    }

    /**
     * @dev Cancels an existing offer
     * @param offerId ID of offer to cancel
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!offer.active) revert RevvFiErrors.OfferNotActive();

        offer.active = false;
        _removeFromActiveList(offerId);
        totalLiquidityAvailable -= offer.remainingAmount;

        // Refund remaining funds to lender
        if (offer.remainingAmount > 0) {
            IERC20 token = IERC20(borrowAsset);
            token.safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit RevvFiEvents.OfferCancelled(offerId, msg.sender);
    }

    /**
     * @dev Modifies an existing offer's terms
     * @param offerId ID of offer to modify
     * @param newAmount New total amount
     * @param newApr New APR in basis points
     * @param newDuration New duration in seconds
     */
    function modifyOffer(uint256 offerId, uint256 newAmount, uint256 newApr, uint256 newDuration)
        external
        nonReentrant
    {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!offer.active) revert RevvFiErrors.OfferNotActive();
        if (newAmount == 0 || newAmount < MIN_OFFER_AMOUNT) revert RevvFiErrors.ZeroAmount();
        if (newApr == 0) revert RevvFiErrors.ZeroApr();
        if (newDuration == 0) revert RevvFiErrors.ZeroAmount();

        // Calculate filled amount (already borrowed)
        uint256 filledAmount = offer.amount - offer.remainingAmount;

        // New amount must be at least the filled amount
        if (newAmount < filledAmount) revert RevvFiErrors.InsufficientOfferAmount();

        uint256 newRemaining = newAmount - filledAmount;
        IERC20 token = IERC20(borrowAsset);

        // Adjust funds if remaining amount changed
        if (newRemaining > offer.remainingAmount) {
            uint256 delta = newRemaining - offer.remainingAmount;
            token.safeTransferFrom(msg.sender, address(this), delta);
            totalLiquidityAvailable += delta;
        } else if (newRemaining < offer.remainingAmount) {
            uint256 delta = offer.remainingAmount - newRemaining;
            token.safeTransfer(msg.sender, delta);
            totalLiquidityAvailable -= delta;
        }

        offer.amount = newAmount;
        offer.remainingAmount = newRemaining;
        offer.apr = newApr;
        offer.expiry = block.timestamp + newDuration;

        emit RevvFiEvents.OfferModified(offerId, newAmount, newApr, newDuration);
    }

    /**
     * @dev Removes expired offers to keep active list manageable
     * @param maxCleanup Maximum number of offers to clean up
     */
    function cleanupExpiredOffers(uint256 maxCleanup) external nonReentrant {
        uint256 cleaned = 0;
        uint256 i = 0;

        while (i < _activeOfferIds.length && cleaned < maxCleanup) {
            uint256 offerId = _activeOfferIds[i];
            Offer storage offer = offers[offerId];

            if (offer.expiry <= block.timestamp) {
                // Refund remaining amount to lender
                if (offer.remainingAmount > 0) {
                    IERC20 token = IERC20(borrowAsset);
                    token.safeTransfer(offer.lender, offer.remainingAmount);
                    totalLiquidityAvailable -= offer.remainingAmount;
                    offer.remainingAmount = 0;
                }

                offer.active = false;
                _removeFromActiveList(offerId);
                cleaned++;
            } else {
                i++;
            }
        }
    }

    /**
     * @dev Returns list of active offer IDs
     * @return Array of active offer IDs
     */
    function _getActiveOffers() internal view returns (uint256[] memory) {
        return _activeOfferIds;
    }

    /**
     * @dev Finds the best offers to fulfill a borrow request
     * @param amount Amount to borrow
     * @param useSeniorOnly If true, only consider senior offers
     * @return bestOffers Array of offers to use (with remaining amounts adjusted)
     * @return totalAvailable Total amount available from selected offers
     * @return weightedApr Weighted average APR of selected offers
     */
    function getBestOffers(uint256 amount, bool useSeniorOnly)
        public
        view
        returns (Offer[] memory bestOffers, uint256 totalAvailable, uint256 weightedApr)
    {
        uint256[] memory activeIds = _getActiveOffers();

        if (activeIds.length == 0) {
            bestOffers = new Offer[](0);
            totalAvailable = 0;
            weightedApr = 0;
            return (bestOffers, totalAvailable, weightedApr);
        }

        // Collect valid offers
        Offer[] memory tempOffers = new Offer[](activeIds.length);
        uint256 validCount = 0;

        uint256 iterations = 0;
        for (uint256 i = 0; i < activeIds.length && iterations < MAX_ITERATIONS; i++) {
            iterations++;
            Offer storage offer = offers[activeIds[i]];
            if (offer.active && offer.remainingAmount > 0 && offer.expiry > block.timestamp) {
                if (!useSeniorOnly || offer.isSenior) {
                    tempOffers[validCount] = offer;
                    validCount++;
                }
            }
        }

        if (validCount == 0) revert RevvFiErrors.NoActiveOffers();

        // Sort by APR (lowest first) using simple selection sort
        for (uint256 i = 0; i < validCount; i++) {
            uint256 minIdx = i;
            for (uint256 j = i + 1; j < validCount; j++) {
                if (tempOffers[j].apr < tempOffers[minIdx].apr) {
                    minIdx = j;
                }
            }
            if (minIdx != i) {
                Offer memory temp = tempOffers[i];
                tempOffers[i] = tempOffers[minIdx];
                tempOffers[minIdx] = temp;
            }
        }

        // Select offers until amount is filled
        uint256 remaining = amount;
        uint256 totalAprWeight = 0;
        totalAvailable = 0;
        uint256 selectedCount = 0;

        for (uint256 i = 0; i < validCount && remaining > 0; i++) {
            uint256 take = tempOffers[i].remainingAmount < remaining ? tempOffers[i].remainingAmount : remaining;
            remaining -= take;
            totalAvailable += take;
            totalAprWeight += take * tempOffers[i].apr;
            selectedCount++;
        }

        // Not enough liquidity available
        if (remaining > 0) {
            bestOffers = new Offer[](0);
            totalAvailable = 0;
            weightedApr = 0;
            return (bestOffers, totalAvailable, weightedApr);
        }

        weightedApr = totalAprWeight / amount;

        // Build result array
        bestOffers = new Offer[](selectedCount);
        uint256 idx = 0;
        remaining = amount;

        for (uint256 i = 0; i < validCount && remaining > 0; i++) {
            uint256 take = tempOffers[i].remainingAmount < remaining ? tempOffers[i].remainingAmount : remaining;
            remaining -= take;

            bestOffers[idx] = tempOffers[i];
            bestOffers[idx].remainingAmount = take;
            idx++;
        }

        return (bestOffers, amount, weightedApr);
    }

    /**
     * @dev Executes a drawdown by filling the best offers
     * @param amount Amount to borrow
     * @param useSeniorOnly If true, only use senior offers
     * @return filledOffers Offers that were filled
     * @return weightedApr Weighted average APR of filled offers
     */
    function executeDrawdown(uint256 amount, bool useSeniorOnly)
        external
        onlyMarket
        nonReentrant
        returns (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr)
    {
        (Offer[] memory offersToFill, uint256 totalAvailable, uint256 computedApr) =
            getBestOffers(amount, useSeniorOnly);

        if (totalAvailable < amount) revert RevvFiErrors.InsufficientOfferAmount();

        weightedApr = computedApr;

        IRevvFiOfferBook.Offer[] memory result = new IRevvFiOfferBook.Offer[](offersToFill.length);

        for (uint256 i = 0; i < offersToFill.length; i++) {
            Offer storage offer = offers[offersToFill[i].id];
            uint256 amountToTake = offersToFill[i].remainingAmount;

            offer.remainingAmount -= amountToTake;
            totalLiquidityAvailable -= amountToTake;

            result[i] = IRevvFiOfferBook.Offer({
                id: offer.id,
                lender: offer.lender,
                amount: offer.amount,
                remainingAmount: amountToTake,
                apr: offer.apr,
                seniority: offer.seniority,
                expiry: offer.expiry,
                active: offer.active,
                isSenior: offer.isSenior
            });

            IERC20 token = IERC20(borrowAsset);
            token.safeTransfer(market, amountToTake);

            // Fully filled offer gets deactivated
            if (offer.remainingAmount == 0) {
                offer.active = false;
                _removeFromActiveList(offer.id);
            }

            emit RevvFiEvents.OfferFilled(offer.id, offer.lender, amountToTake);
        }

        emit RevvFiEvents.DrawdownExecutedOffer(msg.sender, amount, weightedApr);

        return (result, weightedApr);
    }

    /**
     * @dev Returns offer details
     * @param offerId ID of offer to query
     * @return Offer struct
     */
    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    /**
     * @dev Returns offers created by a specific lender
     * @param lender Address of the lender
     * @return Array of offers (limited to 50 for gas efficiency)
     */
    function getLenderOffers(address lender) external view returns (Offer[] memory) {
        uint256[] storage ids = lenderOfferIds[lender];
        uint256 maxReturn = ids.length > 50 ? 50 : ids.length;
        Offer[] memory lenderOffers = new Offer[](maxReturn);
        for (uint256 i = 0; i < maxReturn; i++) {
            lenderOffers[i] = offers[ids[i]];
        }
        return lenderOffers;
    }

    /**
     * @dev Returns total liquidity available across all offers
     * @return Total amount available for borrowing
     */
    function getTotalLiquidityAvailable() external view returns (uint256) {
        return totalLiquidityAvailable;
    }

    /**
     * @dev Returns number of active offers
     * @return Active offer count
     */
    function getActiveOfferCount() external view returns (uint256) {
        return activeOfferCount;
    }
}
