// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiOfferBook
 * @author Preet Singh
 * @notice Manages lending offers for the RevvFi protocol
 * @dev Handles offer submission, cancellation, modification, and efficient matching using APR buckets
 */
contract RevvFiOfferBook is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    /**
     * @dev Structure representing a lending offer
     * @param id Unique identifier for the offer
     * @param lender Address of the lender providing funds
     * @param amount Original amount offered
     * @param remainingAmount Amount still available for borrowing
     * @param apr Annual Percentage Rate in basis points
     * @param seniority Seniority level (0=senior, 1=junior)
     * @param expiry Timestamp when offer expires
     * @param active Whether offer is currently active
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
    }

    // FIXED: Use APR buckets for efficient matching
    /**
     * @dev Structure representing a bucket of offers with similar APR
     * @param apr APR value for this bucket (rounded to APR_STEP)
     * @param totalLiquidity Total available liquidity in this bucket
     * @param offerIds Array of offer IDs in this bucket
     */
    struct APRBucket {
        uint256 apr;
        uint256 totalLiquidity;
        uint256[] offerIds;
    }

    // Protocol constants
    uint256 public constant MAX_OFFERS_PER_LENDER = 20;      // Maximum active offers per lender
    uint256 public constant MAX_ACTIVE_OFFERS = 500;        // Global maximum active offers
    uint256 private constant MIN_OFFER = 100e6;             // Minimum offer amount (100 USDC with 6 decimals)
    uint256 private constant MAX_OFFERS_TO_MATCH = 50;      // Limit matching to prevent gas explosion

    // Core addresses
    address public factory;         // Factory contract that created this offer book
    address public market;          // Associated market contract
    address public borrowAsset;     // Asset token being lent/borrowed

    // Offer storage
    mapping(uint256 => Offer) public offers;                // Offer ID => Offer details
    mapping(address => uint256[]) public lenderOfferIds;    // Lender address => Array of offer IDs
    mapping(uint256 => bool) public isActiveOffer;          // Offer ID => Active status

    // Offer ID management
    uint256 public nextOfferId;         // Next available offer ID
    uint256 public totalLiquidity;      // Total available liquidity across all active offers
    uint256 public activeOfferCount;    // Number of active offers

    // Active offers array with index mapping for O(1) removal
    uint256[] private _activeIds;                       // List of active offer IDs
    mapping(uint256 => uint256) private _activeIndex;   // Offer ID => Index in _activeIds

    // FIXED: APR buckets for efficient matching
    mapping(uint256 => APRBucket) public aprBuckets;    // Bucket ID => Bucket details
    uint256[] public aprValues;                         // List of bucket IDs with active offers
    mapping(uint256 => uint256) public aprToIndex;      // Bucket ID => Index in aprValues array
    uint256 public constant APR_STEP = 100;             // APR step size (1% = 100 basis points)
    
    // FIXED: Track which offers are in which buckets to prevent duplication
    mapping(uint256 => uint256) public offerInBucketId; // Offer ID => Bucket ID (0 means not in any bucket)

    /**
     * @dev Modifier to restrict access to market contract only
     */
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to factory contract only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Constructor that disables initializers for implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the offer book contract
     * @param _factory Address of the factory contract
     * @param _market Address of the associated market contract
     * @param _borrowAsset Address of the borrow asset token
     */
    function initialize(address _factory, address _market, address _borrowAsset) external initializer {
        if (_factory == address(0) || _market == address(0) || _borrowAsset == address(0)) {
            revert RevvFiErrors.ZeroAddress();
        }

        factory = _factory;
        market = _market;
        borrowAsset = _borrowAsset;
        nextOfferId = 1;
    }

    /**
     * @dev Calculates bucket ID for a given APR value
     * @param apr APR in basis points
     * @return Bucket ID (rounded down to nearest APR_STEP)
     */
    function _getBucketId(uint256 apr) internal pure returns (uint256) {
        return apr / APR_STEP;
    }

    /**
     * @dev Adds an offer to the appropriate APR bucket
     * @param apr APR of the offer
     * @param offerId ID of the offer to add
     */
    function _addToBucket(uint256 apr, uint256 offerId) internal {
        uint256 bucketId = _getBucketId(apr);

        // FIXED: Prevent duplication - only add if not already in this bucket
        if (offerInBucketId[offerId] == bucketId) {
            return; // Already in this bucket
        }

        // If offer is in a different bucket, remove it first
        if (offerInBucketId[offerId] != 0) {
            uint256 oldBucketId = offerInBucketId[offerId];
            APRBucket storage oldBucket = aprBuckets[oldBucketId];
            // Find and remove from old bucket
            for (uint256 i = 0; i < oldBucket.offerIds.length; i++) {
                if (oldBucket.offerIds[i] == offerId) {
                    oldBucket.offerIds[i] = oldBucket.offerIds[oldBucket.offerIds.length - 1];
                    oldBucket.offerIds.pop();
                    break;
                }
            }
        }

        // Initialize bucket if it doesn't exist
        if (aprBuckets[bucketId].apr == 0) {
            aprBuckets[bucketId].apr = apr;
            aprToIndex[bucketId] = aprValues.length;
            aprValues.push(bucketId);
        }
        
        // Add offer to bucket
        aprBuckets[bucketId].offerIds.push(offerId);
        aprBuckets[bucketId].totalLiquidity += offers[offerId].remainingAmount;
        offerInBucketId[offerId] = bucketId;
    }

    /**
     * @dev Removes an offer from its APR bucket (partially or fully)
     * @param apr APR of the offer
     * @param offerId ID of the offer to remove
     * @param amountRemoved Amount being removed from the offer
     */
    function _removeFromBucket(uint256 apr, uint256 offerId, uint256 amountRemoved) internal {
        uint256 bucketId = _getBucketId(apr);
        APRBucket storage bucket = aprBuckets[bucketId];
        bucket.totalLiquidity -= amountRemoved;

        // Only clear bucket tracking when offer is fully removed
        // If offer still has remaining amount, it stays in the bucket
        if (offers[offerId].remainingAmount == 0) {
            // Fully removed - clear tracking and remove from array
            offerInBucketId[offerId] = 0;
            for (uint256 i = 0; i < bucket.offerIds.length; i++) {
                if (bucket.offerIds[i] == offerId) {
                    bucket.offerIds[i] = bucket.offerIds[bucket.offerIds.length - 1];
                    bucket.offerIds.pop();
                    break;
                }
            }
        }
        // If offer still has remaining amount, it stays in the bucket with the same offerInBucketId
        // This prevents the duplication bug on re-add
    }

    /**
     * @dev Adds an offer to the active offers list and appropriate bucket
     * @param offerId ID of the offer to add
     */
    function _addActive(uint256 offerId) internal {
        isActiveOffer[offerId] = true;
        _activeIndex[offerId] = _activeIds.length;
        _activeIds.push(offerId);
        activeOfferCount++;

        Offer storage offer = offers[offerId];
        _addToBucket(offer.apr, offerId);
    }

    /**
     * @dev Removes an offer from the active offers list and its bucket
     * @param offerId ID of the offer to remove
     */
    function _removeActive(uint256 offerId) internal {
        if (!isActiveOffer[offerId]) return;

        // Swap with last element and pop for O(1) removal from array
        uint256 index = _activeIndex[offerId];
        uint256 lastId = _activeIds[_activeIds.length - 1];

        _activeIds[index] = lastId;
        _activeIndex[lastId] = index;
        _activeIds.pop();

        delete _activeIndex[offerId];
        isActiveOffer[offerId] = false;
        activeOfferCount--;

        Offer storage offer = offers[offerId];
        _removeFromBucket(offer.apr, offerId, offer.remainingAmount);
    }

    /**
     * @dev Submits a new lending offer
     * @param amount Amount to lend
     * @param apr APR in basis points
     * @param seniority Seniority level (0=senior, 1=junior)
     * @param duration Duration of the offer in seconds
     * @return offerId Unique identifier for the created offer
     */
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (amount < MIN_OFFER) revert RevvFiErrors.ZeroAmount();
        if (apr == 0) revert RevvFiErrors.ZeroApr();
        if (seniority > 1) revert RevvFiErrors.InvalidSeniority();
        if (duration == 0) revert RevvFiErrors.ZeroAmount();
        if (activeOfferCount >= MAX_ACTIVE_OFFERS) revert RevvFiErrors.MaxOffersExceeded();
        if (lenderOfferIds[msg.sender].length >= MAX_OFFERS_PER_LENDER) revert RevvFiErrors.MaxOffersExceeded();

        // Transfer funds from lender to this contract
        IERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), amount);

        // Create new offer
        offerId = nextOfferId++;
        offers[offerId] = Offer(offerId, msg.sender, amount, amount, apr, seniority, block.timestamp + duration, true);

        lenderOfferIds[msg.sender].push(offerId);
        _addActive(offerId);
        totalLiquidity += amount;

        emit RevvFiEvents.OfferSubmitted(offerId, msg.sender, amount, apr, seniority, block.timestamp + duration);
        return offerId;
    }

    /**
     * @dev Cancels an existing offer and refunds remaining funds
     * @param offerId ID of the offer to cancel
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender || !offer.active) revert RevvFiErrors.UnauthorizedCaller();

        offer.active = false;
        _removeActive(offerId);
        totalLiquidity -= offer.remainingAmount;

        // Refund remaining amount to lender
        if (offer.remainingAmount > 0) {
            IERC20(borrowAsset).safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit RevvFiEvents.OfferCancelled(offerId, msg.sender);
    }

    /**
     * @dev Modifies an existing offer (amount, APR, or duration)
     * @param offerId ID of the offer to modify
     * @param newAmount New total amount (including already filled portion)
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
        if (newAmount == 0 || newAmount < MIN_OFFER) revert RevvFiErrors.ZeroAmount();
        if (newApr == 0) revert RevvFiErrors.ZeroApr();
        if (newDuration == 0) revert RevvFiErrors.ZeroAmount();

        uint256 filledAmount = offer.amount - offer.remainingAmount;
        if (newAmount < filledAmount) revert RevvFiErrors.InsufficientOfferAmount();

        // Remove from old bucket before modifying
        _removeFromBucket(offer.apr, offerId, offer.remainingAmount);

        uint256 newRemaining = newAmount - filledAmount;
        IERC20 token = IERC20(borrowAsset);

        // Handle fund transfers based on amount change
        if (newRemaining > offer.remainingAmount) {
            uint256 delta = newRemaining - offer.remainingAmount;
            token.safeTransferFrom(msg.sender, address(this), delta);
            totalLiquidity += delta;
        } else if (newRemaining < offer.remainingAmount) {
            uint256 delta = offer.remainingAmount - newRemaining;
            token.safeTransfer(msg.sender, delta);
            totalLiquidity -= delta;
        }

        // Update offer parameters
        offer.amount = newAmount;
        offer.remainingAmount = newRemaining;
        offer.apr = newApr;
        offer.expiry = block.timestamp + newDuration;

        // Add to new bucket
        _addToBucket(newApr, offerId);

        emit RevvFiEvents.OfferModified(offerId, newAmount, newApr, newDuration);
    }

    /**
     * @dev Cleans up expired offers and refunds lenders
     * @param maxCleanup Maximum number of offers to clean up in this call
     */
    function cleanupExpiredOffers(uint256 maxCleanup) external nonReentrant {
        uint256 cleaned = 0;
        uint256 i = 0;

        // Iterate through active offers and remove expired ones
        while (i < _activeIds.length && cleaned < maxCleanup) {
            uint256 offerId = _activeIds[i];
            Offer storage offer = offers[offerId];

            if (offer.expiry <= block.timestamp) {
                // Refund remaining amount to lender
                if (offer.remainingAmount > 0) {
                    IERC20 token = IERC20(borrowAsset);
                    token.safeTransfer(offer.lender, offer.remainingAmount);
                    totalLiquidity -= offer.remainingAmount;
                    offer.remainingAmount = 0;
                }

                offer.active = false;
                _removeActive(offerId);
                cleaned++;
            } else {
                i++;
            }
        }
    }

    /**
     * @dev Returns the best available offers for a given amount
     * @param amount Amount to borrow
     * @param useSeniorOnly Whether to only consider senior offers
     * @return bestOffers Array of best offers sorted by APR
     * @return totalAvail Total available amount from best offers
     * @return weightedApr Weighted average APR of selected offers
     */
    function getBestOffers(uint256 amount, bool useSeniorOnly)
        public
        view
        returns (IRevvFiOfferBook.Offer[] memory bestOffers, uint256 totalAvail, uint256 weightedApr)
    {
        if (_activeIds.length == 0) revert RevvFiErrors.NoActiveOffers();

        // Sort APR values (bubble sort on small number of APR buckets)
        uint256[] memory sortedAprs = new uint256[](aprValues.length);
        for (uint256 i = 0; i < aprValues.length; i++) {
            sortedAprs[i] = aprValues[i];
        }

        // Simple sort for APRs (small number of APR buckets)
        for (uint256 i = 0; i < sortedAprs.length; i++) {
            for (uint256 j = i + 1; j < sortedAprs.length; j++) {
                if (aprBuckets[sortedAprs[j]].apr < aprBuckets[sortedAprs[i]].apr) {
                    uint256 temp = sortedAprs[i];
                    sortedAprs[i] = sortedAprs[j];
                    sortedAprs[j] = temp;
                }
            }
        }

        uint256 remaining = amount;
        uint256 totalAprWeight = 0;
        uint256 selectedCount = 0;
        IRevvFiOfferBook.Offer[] memory tempBest = new IRevvFiOfferBook.Offer[](MAX_OFFERS_TO_MATCH);

        uint256 offerIndex = 0;

        // Iterate through APR buckets from lowest to highest
        for (uint256 b = 0; b < sortedAprs.length && remaining > 0 && offerIndex < MAX_OFFERS_TO_MATCH; b++) {
            uint256 bucketId = sortedAprs[b];
            APRBucket storage bucket = aprBuckets[bucketId];

            // Iterate through offers in this bucket
            for (uint256 i = 0; i < bucket.offerIds.length && remaining > 0 && offerIndex < MAX_OFFERS_TO_MATCH; i++) {
                uint256 offerId = bucket.offerIds[i];
                Offer storage offer = offers[offerId];

                if (!offer.active || offer.remainingAmount == 0 || offer.expiry <= block.timestamp) continue;
                if (useSeniorOnly && offer.seniority != 0) continue;

                // Take as much as needed from this offer
                uint256 take = offer.remainingAmount < remaining ? offer.remainingAmount : remaining;
                remaining -= take;
                totalAvail += take;
                totalAprWeight += take * offer.apr;

                // Create copy of offer with taken amount
                tempBest[offerIndex] = IRevvFiOfferBook.Offer({
                    id: offer.id,
                    lender: offer.lender,
                    amount: offer.amount,
                    remainingAmount: take,
                    apr: offer.apr,
                    seniority: offer.seniority,
                    expiry: offer.expiry,
                    active: offer.active,
                    isSenior: offer.seniority == 0
                });
                offerIndex++;
            }
        }

        // Check if we found enough liquidity
        if (remaining > 0) {
            return (new IRevvFiOfferBook.Offer[](0), 0, 0);
        }

        weightedApr = totalAprWeight / amount;
        bestOffers = new IRevvFiOfferBook.Offer[](offerIndex);
        for (uint256 i = 0; i < offerIndex; i++) {
            bestOffers[i] = tempBest[i];
        }

        return (bestOffers, amount, weightedApr);
    }

    /**
     * @dev Executes a drawdown by matching offers with requested amount
     * @param amount Amount to draw down
     * @param useSeniorOnly Whether to only use senior offers
     * @return filledOffers Array of offers used to fulfill the drawdown
     * @return weightedApr Weighted average APR of filled offers
     */
    function executeDrawdown(uint256 amount, bool useSeniorOnly)
        external
        onlyMarket
        nonReentrant
        returns (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr)
    {
        // Get best offers for the requested amount
        (IRevvFiOfferBook.Offer[] memory offersToFill, uint256 totalAvail, uint256 computedApr) =
            getBestOffers(amount, useSeniorOnly);
        if (totalAvail < amount) revert RevvFiErrors.InsufficientOfferAmount();

        weightedApr = computedApr;
        filledOffers = new IRevvFiOfferBook.Offer[](offersToFill.length);

        // Process each offer
        for (uint256 i = 0; i < offersToFill.length; i++) {
            Offer storage offer = offers[offersToFill[i].id];
            uint256 take = offersToFill[i].remainingAmount;

            // Update offer state
            offer.remainingAmount -= take;
            totalLiquidity -= take;

            // Update bucket tracking
            _removeFromBucket(offer.apr, offer.id, take);

            filledOffers[i] = offersToFill[i];
            filledOffers[i].remainingAmount = take;

            // Transfer funds to market
            IERC20(borrowAsset).safeTransfer(market, take);

            // Deactivate or update offer if partially filled
            if (offer.remainingAmount == 0) {
                offer.active = false;
                _removeActive(offer.id);
            } else {
                _addToBucket(offer.apr, offer.id);
            }

            emit RevvFiEvents.OfferFilled(offer.id, offer.lender, take);
        }

        emit RevvFiEvents.DrawdownExecutedOffer(msg.sender, amount, weightedApr);
        return (filledOffers, weightedApr);
    }

    /**
     * @dev Returns details of a specific offer
     * @param offerId ID of the offer to query
     * @return Offer structure containing offer details
     */
    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    /**
     * @dev Returns offers for a specific lender (limited to first 50)
     * @param lender Address of the lender
     * @return Array of offers belonging to the lender
     */
    function getLenderOffers(address lender) external view returns (IRevvFiOfferBook.Offer[] memory) {
        uint256[] storage ids = lenderOfferIds[lender];
        uint256 len = ids.length > 50 ? 50 : ids.length;
        IRevvFiOfferBook.Offer[] memory result = new IRevvFiOfferBook.Offer[](len);
        for (uint256 i = 0; i < len; i++) {
            Offer storage o = offers[ids[i]];
            result[i] = IRevvFiOfferBook.Offer({
                id: o.id,
                lender: o.lender,
                amount: o.amount,
                remainingAmount: o.remainingAmount,
                apr: o.apr,
                seniority: o.seniority,
                expiry: o.expiry,
                active: o.active,
                isSenior: o.seniority == 0
            });
        }
        return result;
    }

    /**
     * @dev Returns total available liquidity across all active offers
     * @return Total liquidity amount
     */
    function getTotalLiquidityAvailable() external view returns (uint256) {
        return totalLiquidity;
    }

    /**
     * @dev Returns count of active offers
     * @return Number of active offers
     */
    function getActiveOfferCount() external view returns (uint256) {
        return activeOfferCount;
    }
}