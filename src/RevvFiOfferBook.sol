// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiOfferBook is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

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
    struct APRBucket {
        uint256 apr;
        uint256 totalLiquidity;
        uint256[] offerIds;
    }

    uint256 public constant MAX_OFFERS_PER_LENDER = 20;
    uint256 public constant MAX_ACTIVE_OFFERS = 500;
    uint256 private constant MIN_OFFER = 100e6;
    uint256 private constant MAX_OFFERS_TO_MATCH = 50; // Limit matching to prevent gas explosion

    address public factory;
    address public market;
    address public borrowAsset;

    mapping(uint256 => Offer) public offers;
    mapping(address => uint256[]) public lenderOfferIds;
    mapping(uint256 => bool) public isActiveOffer;

    uint256 public nextOfferId;
    uint256 public totalLiquidity;
    uint256 public activeOfferCount;

    uint256[] private _activeIds;
    mapping(uint256 => uint256) private _activeIndex;
    
    // FIXED: APR buckets for efficient matching
    mapping(uint256 => APRBucket) public aprBuckets;
    uint256[] public aprValues;
    mapping(uint256 => uint256) public aprToIndex;
    uint256 public constant APR_STEP = 100; // 1% steps

    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _factory, address _market, address _borrowAsset) external initializer {
        if (_factory == address(0) || _market == address(0) || _borrowAsset == address(0)) {
            revert RevvFiErrors.ZeroAddress();
        }

        factory = _factory;
        market = _market;
        borrowAsset = _borrowAsset;
        nextOfferId = 1;
    }

    function _getBucketId(uint256 apr) internal pure returns (uint256) {
        return apr / APR_STEP;
    }

    function _addToBucket(uint256 apr, uint256 offerId) internal {
        uint256 bucketId = _getBucketId(apr);
        if (aprBuckets[bucketId].apr == 0) {
            aprBuckets[bucketId].apr = apr;
            aprToIndex[bucketId] = aprValues.length;
            aprValues.push(bucketId);
        }
        aprBuckets[bucketId].offerIds.push(offerId);
        aprBuckets[bucketId].totalLiquidity += offers[offerId].remainingAmount;
    }

    function _removeFromBucket(uint256 apr, uint256 offerId, uint256 amountRemoved) internal {
        uint256 bucketId = _getBucketId(apr);
        APRBucket storage bucket = aprBuckets[bucketId];
        bucket.totalLiquidity -= amountRemoved;
        
        // Remove offer from bucket if fully filled
        if (offers[offerId].remainingAmount == 0) {
            // Find and remove from array (inefficient but happens less frequently)
            for (uint256 i = 0; i < bucket.offerIds.length; i++) {
                if (bucket.offerIds[i] == offerId) {
                    bucket.offerIds[i] = bucket.offerIds[bucket.offerIds.length - 1];
                    bucket.offerIds.pop();
                    break;
                }
            }
        }
    }

    function _addActive(uint256 offerId) internal {
        isActiveOffer[offerId] = true;
        _activeIndex[offerId] = _activeIds.length;
        _activeIds.push(offerId);
        activeOfferCount++;
        
        Offer storage offer = offers[offerId];
        _addToBucket(offer.apr, offerId);
    }

    function _removeActive(uint256 offerId) internal {
        if (!isActiveOffer[offerId]) return;

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

        IERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), amount);

        offerId = nextOfferId++;
        offers[offerId] = Offer(offerId, msg.sender, amount, amount, apr, seniority, block.timestamp + duration, true);

        lenderOfferIds[msg.sender].push(offerId);
        _addActive(offerId);
        totalLiquidity += amount;

        emit RevvFiEvents.OfferSubmitted(offerId, msg.sender, amount, apr, seniority, block.timestamp + duration);
        return offerId;
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender || !offer.active) revert RevvFiErrors.UnauthorizedCaller();

        offer.active = false;
        _removeActive(offerId);
        totalLiquidity -= offer.remainingAmount;

        if (offer.remainingAmount > 0) {
            IERC20(borrowAsset).safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit RevvFiEvents.OfferCancelled(offerId, msg.sender);
    }

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

        // Remove from old bucket
        _removeFromBucket(offer.apr, offerId, offer.remainingAmount);
        
        uint256 newRemaining = newAmount - filledAmount;
        IERC20 token = IERC20(borrowAsset);

        if (newRemaining > offer.remainingAmount) {
            uint256 delta = newRemaining - offer.remainingAmount;
            token.safeTransferFrom(msg.sender, address(this), delta);
            totalLiquidity += delta;
        } else if (newRemaining < offer.remainingAmount) {
            uint256 delta = offer.remainingAmount - newRemaining;
            token.safeTransfer(msg.sender, delta);
            totalLiquidity -= delta;
        }

        offer.amount = newAmount;
        offer.remainingAmount = newRemaining;
        offer.apr = newApr;
        offer.expiry = block.timestamp + newDuration;
        
        // Add to new bucket
        _addToBucket(newApr, offerId);

        emit RevvFiEvents.OfferModified(offerId, newAmount, newApr, newDuration);
    }

    // ADDED: cleanupExpiredOffers function
    function cleanupExpiredOffers(uint256 maxCleanup) external nonReentrant {
        uint256 cleaned = 0;
        uint256 i = 0;

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

    // FIXED: Efficient offer matching using APR buckets
    function getBestOffers(uint256 amount, bool useSeniorOnly)
        public
        view
        returns (IRevvFiOfferBook.Offer[] memory bestOffers, uint256 totalAvail, uint256 weightedApr)
    {
        if (_activeIds.length == 0) revert RevvFiErrors.NoActiveOffers();

        // Sort APR values
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
        
        for (uint256 b = 0; b < sortedAprs.length && remaining > 0 && offerIndex < MAX_OFFERS_TO_MATCH; b++) {
            uint256 bucketId = sortedAprs[b];
            APRBucket storage bucket = aprBuckets[bucketId];
            
            for (uint256 i = 0; i < bucket.offerIds.length && remaining > 0 && offerIndex < MAX_OFFERS_TO_MATCH; i++) {
                uint256 offerId = bucket.offerIds[i];
                Offer storage offer = offers[offerId];
                
                if (!offer.active || offer.remainingAmount == 0 || offer.expiry <= block.timestamp) continue;
                if (useSeniorOnly && offer.seniority != 0) continue;
                
                uint256 take = offer.remainingAmount < remaining ? offer.remainingAmount : remaining;
                remaining -= take;
                totalAvail += take;
                totalAprWeight += take * offer.apr;
                
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

    function executeDrawdown(uint256 amount, bool useSeniorOnly)
        external
        onlyMarket
        nonReentrant
        returns (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr)
    {
        (IRevvFiOfferBook.Offer[] memory offersToFill, uint256 totalAvail, uint256 computedApr) =
            getBestOffers(amount, useSeniorOnly);
        if (totalAvail < amount) revert RevvFiErrors.InsufficientOfferAmount();

        weightedApr = computedApr;
        filledOffers = new IRevvFiOfferBook.Offer[](offersToFill.length);

        for (uint256 i = 0; i < offersToFill.length; i++) {
            Offer storage offer = offers[offersToFill[i].id];
            uint256 take = offersToFill[i].remainingAmount;

            offer.remainingAmount -= take;
            totalLiquidity -= take;
            
            // Update bucket
            _removeFromBucket(offer.apr, offer.id, take);

            filledOffers[i] = offersToFill[i];
            filledOffers[i].remainingAmount = take;

            IERC20(borrowAsset).safeTransfer(market, take);

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

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

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

    function getTotalLiquidityAvailable() external view returns (uint256) {
        return totalLiquidity;
    }

    function getActiveOfferCount() external view returns (uint256) {
        return activeOfferCount;
    }
}