// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiOfferBook.sol";

/**
 * @title RevvFiOfferBook
 * @notice Manages lender offers with competitive APRs for borrowing
 */
contract RevvFiOfferBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

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

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

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

    // ========================================================================== //
    //                                   Structs                                   //
    // ========================================================================== //

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

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    address public immutable factory;
    address public market;
    address public borrowAsset;

    mapping(uint256 => Offer) public offers;
    mapping(address => uint256[]) public lenderOfferIds;
    uint256 public nextOfferId;
    uint256 public totalLiquidityAvailable;

    bool public isInitialized;

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyMarket() {
        if (msg.sender != market) revert UnauthorizedCaller();
        _;
    }

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
        nextOfferId = 1;
        isInitialized = false;
    }

    // ========================================================================== //
    //                               Initialization                               //
    // ========================================================================== //

    function initialize(address _market, address _borrowAsset) external onlyFactory {
        if (isInitialized) revert UnauthorizedCaller();
        if (_market == address(0)) revert ZeroAddress();
        if (_borrowAsset == address(0)) revert ZeroAddress();

        market = _market;
        borrowAsset = _borrowAsset;
        isInitialized = true;
    }

    // ========================================================================== //
    //                              Lender Functions                               //
    // ========================================================================== //

    function submitOffer(
        uint256 amount,
        uint256 apr,
        uint8 seniority,
        uint256 duration
    ) external nonReentrant returns (uint256 offerId) {
        if (amount == 0) revert ZeroAmount();
        if (apr == 0) revert ZeroApr();
        if (seniority > 1) revert InvalidSeniority();
        if (duration == 0) revert ZeroAmount();

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
        totalLiquidityAvailable += amount;

        emit OfferSubmitted(offerId, msg.sender, amount, apr, seniority, block.timestamp + duration);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender != msg.sender) revert UnauthorizedCaller();
        if (!offer.active) revert OfferNotActive();
        if (offer.expiry < block.timestamp) revert OfferExpired();

        offer.active = false;
        totalLiquidityAvailable -= offer.remainingAmount;

        if (offer.remainingAmount > 0) {
            IERC20 token = IERC20(borrowAsset);
            token.safeTransfer(msg.sender, offer.remainingAmount);
            offer.remainingAmount = 0;
        }

        emit OfferCancelled(offerId, msg.sender);
    }

    // ========================================================================== //
    //                           Borrowing Functions                               //
    // ========================================================================== //

    function getBestOffers(
        uint256 amount,
        bool useSeniorOnly
    ) public view returns (Offer[] memory bestOffers, uint256 totalAvailable, uint256 weightedApr) {
        // First, collect all active offers
        Offer[] memory tempOffers = new Offer[](nextOfferId);
        uint256 activeCount = 0;

        for (uint256 i = 1; i < nextOfferId; i++) {
            Offer storage offer = offers[i];
            if (offer.active && offer.remainingAmount > 0 && offer.expiry > block.timestamp) {
                if (!useSeniorOnly || offer.isSenior) {
                    tempOffers[activeCount] = offer;
                    activeCount++;
                }
            }
        }

        if (activeCount == 0) {
            bestOffers = new Offer[](0);
            totalAvailable = 0;
            weightedApr = 0;
            return (bestOffers, totalAvailable, weightedApr);
        }

        // Copy to properly sized array
        Offer[] memory activeOffers = new Offer[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            activeOffers[i] = tempOffers[i];
        }

        // Sort by APR (lowest first) - simple bubble sort
        for (uint256 i = 0; i < activeCount - 1; i++) {
            for (uint256 j = 0; j < activeCount - i - 1; j++) {
                if (activeOffers[j].apr > activeOffers[j + 1].apr) {
                    Offer memory temp = activeOffers[j];
                    activeOffers[j] = activeOffers[j + 1];
                    activeOffers[j + 1] = temp;
                }
            }
        }

        // Select best offers until amount is filled
        uint256 remaining = amount;
        uint256 totalAprWeight = 0;
        totalAvailable = 0;
        uint256 selectedCount = 0;

        for (uint256 i = 0; i < activeCount && remaining > 0; i++) {
            uint256 take = activeOffers[i].remainingAmount < remaining
                ? activeOffers[i].remainingAmount
                : remaining;
            remaining -= take;
            totalAvailable += take;
            totalAprWeight += take * activeOffers[i].apr;
            selectedCount++;
        }

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

        for (uint256 i = 0; i < activeCount && remaining > 0; i++) {
            uint256 take = activeOffers[i].remainingAmount < remaining
                ? activeOffers[i].remainingAmount
                : remaining;
            remaining -= take;

            bestOffers[idx] = activeOffers[i];
            bestOffers[idx].remainingAmount = take;
            idx++;
        }

        return (bestOffers, amount, weightedApr);
    }

    function executeDrawdown(
        uint256 amount,
        bool useSeniorOnly
    ) external onlyMarket nonReentrant returns (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) {
        (Offer[] memory offersToFill, uint256 totalAvailable, uint256 computedApr) = getBestOffers(
            amount,
            useSeniorOnly
        );

        if (totalAvailable < amount) revert InsufficientOfferAmount();

        weightedApr = computedApr;
        
        // Convert to interface type
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
            }

            emit OfferFilled(offer.id, offer.lender, amountToTake);
        }

        emit DrawdownExecuted(msg.sender, amount, weightedApr);

        return (result, weightedApr);
    }

    // ========================================================================== //
    //                               View Functions                                //
    // ========================================================================== //

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    function getLenderOffers(address lender) external view returns (Offer[] memory) {
        uint256[] storage ids = lenderOfferIds[lender];
        Offer[] memory lenderOffers = new Offer[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            lenderOffers[i] = offers[ids[i]];
        }
        return lenderOffers;
    }

    function getTotalLiquidityAvailable() external view returns (uint256) {
        return totalLiquidityAvailable;
    }
}