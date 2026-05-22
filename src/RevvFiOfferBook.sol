// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiOfferBook is ReentrancyGuard {
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
        bool isSenior;
    }

    uint256 public constant MAX_OFFERS_PER_LENDER = 20;
    uint256 public constant MAX_ACTIVE_OFFERS_GLOBAL = 500;
    uint256 public constant MIN_OFFER_AMOUNT = 100e6;
    uint256 public constant MAX_ITERATIONS = 100;
    uint256 public constant EXPIRY_CLEANUP_BATCH_SIZE = 50;

    address public immutable factory;
    address public market;
    address public borrowAsset;

    mapping(uint256 => Offer) public offers;
    mapping(address => uint256[]) public lenderOfferIds;
    mapping(uint256 => bool) public isActiveOffer;

    uint256 public nextOfferId;
    uint256 public totalLiquidityAvailable;
    uint256 public activeOfferCount;

    uint256[] private _activeOfferIds;
    mapping(uint256 => uint256) private _activeOfferIndex;

    bool public isInitialized;

    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        nextOfferId = 1;
        isInitialized = false;
        activeOfferCount = 0;
    }

    function initialize(address _market, address _borrowAsset) external onlyFactory {
        if (isInitialized) revert RevvFiErrors.UnauthorizedCaller();
        if (_market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrowAsset == address(0)) revert RevvFiErrors.ZeroAddress();

        market = _market;
        borrowAsset = _borrowAsset;
        isInitialized = true;
    }

    function _addToActiveList(uint256 offerId) internal {
        isActiveOffer[offerId] = true;
        _activeOfferIndex[offerId] = _activeOfferIds.length;
        _activeOfferIds.push(offerId);
        activeOfferCount++;
    }

    function _removeFromActiveList(uint256 offerId) internal {
        if (!isActiveOffer[offerId]) return;

        uint256 index = _activeOfferIndex[offerId];
        uint256 lastId = _activeOfferIds[_activeOfferIds.length - 1];

        _activeOfferIds[index] = lastId;
        _activeOfferIndex[lastId] = index;
        _activeOfferIds.pop();

        delete _activeOfferIndex[offerId];
        isActiveOffer[offerId] = false;
        activeOfferCount--;
    }

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

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (!offer.active) revert RevvFiErrors.OfferNotActive();

        offer.active = false;
        _removeFromActiveList(offerId);
        totalLiquidityAvailable -= offer.remainingAmount;

        if (offer.remainingAmount > 0) {
            IERC20 token = IERC20(borrowAsset);
            token.safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit RevvFiEvents.OfferCancelled(offerId, msg.sender);
    }

    /**
     * @dev Modify an existing offer's amount, APR, or duration
     * FIXED: Preserves filled amount correctly
     */
    // Add this modifier to modifyOffer function
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

        // Calculate filled amount (amount that has been borrowed)
        uint256 filledAmount = offer.amount - offer.remainingAmount;

        // FIXED: Check that newAmount is not less than filledAmount
        if (newAmount < filledAmount) revert RevvFiErrors.InsufficientOfferAmount();

        uint256 newRemaining = newAmount - filledAmount;
        IERC20 token = IERC20(borrowAsset);

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
     * @dev Clean up expired offers to prevent activeOfferCount saturation
     */
    function cleanupExpiredOffers(uint256 maxCleanup) external nonReentrant {
        uint256 cleaned = 0;
        uint256 i = 0;

        while (i < _activeOfferIds.length && cleaned < maxCleanup) {
            uint256 offerId = _activeOfferIds[i];
            Offer storage offer = offers[offerId];

            if (offer.expiry <= block.timestamp) {
                // FIXED: Refund remaining amount to lender
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

    function _getActiveOffers() internal view returns (uint256[] memory) {
        return _activeOfferIds;
    }

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

        if (remaining > 0) {
            bestOffers = new Offer[](0);
            totalAvailable = 0;
            weightedApr = 0;
            return (bestOffers, totalAvailable, weightedApr);
        }

        weightedApr = totalAprWeight / amount;

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

            if (offer.remainingAmount == 0) {
                offer.active = false;
                _removeFromActiveList(offer.id);
            }

            emit RevvFiEvents.OfferFilled(offer.id, offer.lender, amountToTake);
        }

        emit RevvFiEvents.DrawdownExecutedOffer(msg.sender, amount, weightedApr);

        return (result, weightedApr);
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    function getLenderOffers(address lender) external view returns (Offer[] memory) {
        uint256[] storage ids = lenderOfferIds[lender];
        uint256 maxReturn = ids.length > 50 ? 50 : ids.length;
        Offer[] memory lenderOffers = new Offer[](maxReturn);
        for (uint256 i = 0; i < maxReturn; i++) {
            lenderOffers[i] = offers[ids[i]];
        }
        return lenderOffers;
    }

    function getTotalLiquidityAvailable() external view returns (uint256) {
        return totalLiquidityAvailable;
    }

    function getActiveOfferCount() external view returns (uint256) {
        return activeOfferCount;
    }
}
