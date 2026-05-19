// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiOfferBook.sol";

contract RevvFiOfferBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error ZeroApr();
    error OfferNotFound();
    error OfferExpired();
    error OfferNotActive();
    error InsufficientOfferAmount();
    error UnauthorizedCaller();
    error InvalidSeniority();
    error InsufficientLiquidity();
    error MaxOffersExceeded();
    error NoActiveOffers();
    error MaxIterationsExceeded();

    event OfferSubmitted(
        uint256 indexed offerId,
        address indexed lender,
        uint256 amount,
        uint256 apr,
        uint8 seniority,
        uint256 expiry
    );
    event OfferCancelled(uint256 indexed offerId, address indexed lender);
    event OfferFilled(uint256 indexed offerId, address indexed lender, uint256 amountFilled);
    event DrawdownExecuted(address indexed borrower, uint256 totalAmount, uint256 weightedApr);

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
    uint256 public constant MIN_OFFER_AMOUNT = 100e6; // 100 USDC for 6 decimal tokens
    uint256 public constant MAX_ITERATIONS = 100;

    address public immutable factory;
    address public market;
    address public borrowAsset;

    mapping(uint256 => Offer) public offers;
    mapping(address => uint256[]) public lenderOfferIds;
    mapping(uint256 => bool) public isActiveOffer;
    
    uint256 public nextOfferId;
    uint256 public totalLiquidityAvailable;
    uint256 public activeOfferCount;

    // Circular buffer for active offers to avoid unbounded growth
    uint256[] private _activeOfferIds;
    mapping(uint256 => uint256) private _activeOfferIndex; // offerId -> index in _activeOfferIds

    bool public isInitialized;

    modifier onlyMarket() {
        if (msg.sender != market) revert UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        nextOfferId = 1;
        isInitialized = false;
        activeOfferCount = 0;
    }

    function initialize(address _market, address _borrowAsset) external onlyFactory {
        if (isInitialized) revert UnauthorizedCaller();
        if (_market == address(0)) revert ZeroAddress();
        if (_borrowAsset == address(0)) revert ZeroAddress();

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

    function submitOffer(
        uint256 amount,
        uint256 apr,
        uint8 seniority,
        uint256 duration
    ) external nonReentrant returns (uint256 offerId) {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_OFFER_AMOUNT) revert ZeroAmount();
        if (apr == 0) revert ZeroApr();
        if (seniority > 1) revert InvalidSeniority();
        if (duration == 0) revert ZeroAmount();
        if (activeOfferCount >= MAX_ACTIVE_OFFERS_GLOBAL) revert MaxOffersExceeded();
        if (lenderOfferIds[msg.sender].length >= MAX_OFFERS_PER_LENDER) revert MaxOffersExceeded();

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

        emit OfferSubmitted(offerId, msg.sender, amount, apr, seniority, block.timestamp + duration);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender) revert UnauthorizedCaller();
        if (!offer.active) revert OfferNotActive();

        offer.active = false;
        _removeFromActiveList(offerId);
        totalLiquidityAvailable -= offer.remainingAmount;

        if (offer.remainingAmount > 0) {
            IERC20 token = IERC20(borrowAsset);
            token.safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit OfferCancelled(offerId, msg.sender);
    }

    function _getActiveOffers() internal view returns (uint256[] memory) {
        return _activeOfferIds;
    }

    function getBestOffers(
        uint256 amount,
        bool useSeniorOnly
    ) public view returns (Offer[] memory bestOffers, uint256 totalAvailable, uint256 weightedApr) {
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

        if (validCount == 0) revert NoActiveOffers();

        // Simple selection sort (bounded by MAX_ACTIVE_OFFERS_GLOBAL=500)
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

    function executeDrawdown(
        uint256 amount,
        bool useSeniorOnly
    ) external onlyMarket nonReentrant returns (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) {
        (Offer[] memory offersToFill, uint256 totalAvailable, uint256 computedApr) = getBestOffers(amount, useSeniorOnly);

        if (totalAvailable < amount) revert InsufficientOfferAmount();

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

            emit OfferFilled(offer.id, offer.lender, amountToTake);
        }

        emit DrawdownExecuted(msg.sender, amount, weightedApr);

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