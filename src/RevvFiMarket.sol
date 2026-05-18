// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "./RevvFiMarketBase.sol";
import "./interfaces/IRevvFiOfferBook.sol";

/**
 * @title RevvFiMarket
 * @notice Main market contract for borrowing and lending with collateral
 * @dev Integrates collateral escrow, offer book, position NFTs, and liquidation
 */
contract RevvFiMarket is RevvFiMarketBase {
    using SafeERC20 for IERC20;

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

    event Borrow(address indexed borrower, uint256 amount, uint256 weightedApr);
    event Repay(address indexed borrower, uint256 amount);
    event DrawdownExecuted(uint256 totalAmount, uint256 weightedApr, uint256[] positionIds);
    event MarketClosedEvent(address indexed borrower, uint256 timestamp);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator);

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

    constructor(
        address _factory,
        address _archController,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset
    ) RevvFiMarketBase(_factory, _archController, _borrower, _borrowAsset, _collateralAsset) {}

    // ========================================================================== //
    //                               Initialization                               //
    // ========================================================================== //

    function initialize(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator
    ) external onlyFactory {
        _setContracts(_collateralEscrow, _offerBook, _positionNFT, _liquidator);
    }

    // ========================================================================== //
    //                           Borrower Functions                                //
    // ========================================================================== //

    /**
     * @dev Deposit collateral to the market
     */
    function depositCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen {
        if (amount == 0) revert ZeroAmount();

        IERC20 collateral = IERC20(collateralAsset);
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateral.approve(address(collateralEscrow), amount);

        collateralEscrow.depositCollateral(borrower, amount);
    }

    /**
     * @dev Withdraw collateral (must maintain min ratio)
     */
    function withdrawCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen {
        if (amount == 0) revert ZeroAmount();

        uint256 currentCollateral = collateralEscrow.getCollateralBalance(borrower);
        if (currentCollateral < amount) revert InsufficientCollateral();

        uint256 newCollateral = currentCollateral - amount;
        uint256 newRatio = totalDebt == 0 ? type(uint256).max : (newCollateral * 10000) / totalDebt;
        if (newRatio < collateralEscrow.minCollateralRatio()) revert InsufficientCollateral();

        collateralEscrow.withdrawCollateral(borrower, amount);
    }

    /**
     * @dev Borrow funds using the best offers from offer book
     * @param amount Amount to borrow
     * @param useSeniorOnly If true, only use senior offers
     */
    function borrow(uint256 amount, bool useSeniorOnly) external onlyBorrower nonReentrant marketOpen {
        if (amount == 0) revert ZeroAmount();
        if (amount > getMaxBorrowable()) revert BorrowAmountTooHigh();

        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) = offerBook.executeDrawdown(
            amount,
            useSeniorOnly
        );

        uint256[] memory positionIds = new uint256[](filledOffers.length);
        for (uint256 i = 0; i < filledOffers.length; i++) {
            uint256 tokenId = positionNFT.mintPosition(
                filledOffers[i].lender,
                address(this),
                filledOffers[i].remainingAmount,
                filledOffers[i].apr,
                filledOffers[i].seniority
            );
            positionIds[i] = tokenId;
            lenderPositions[filledOffers[i].lender].push(tokenId);
        }

        totalDebt += amount;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(borrower, amount);

        emit Borrow(borrower, amount, weightedApr);
        emit DrawdownExecuted(amount, weightedApr, positionIds);
    }

    /**
     * @dev Repay borrowed funds
     */
    function repay(uint256 amount) external onlyBorrower nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalDebt) amount = totalDebt;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        totalDebt -= amount;

        emit Repay(borrower, amount);
    }

    /**
     * @dev Full repayment to close position (distributes to lenders)
     */
    function repayFull() external onlyBorrower nonReentrant {
        if (totalDebt == 0) revert ZeroAmount();

        uint256 repaymentAmount = totalDebt;
        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), repaymentAmount);

        totalDebt = 0;

        emit Repay(borrower, repaymentAmount);
    }

    /**
     * @dev Close market (no new borrowing, only repayments)
     */
    function closeMarket() external onlyBorrower nonReentrant {
        isClosed = true;
        emit MarketClosedEvent(borrower, block.timestamp);
    }

    // ========================================================================== //
    //                           Lender Functions                                  //
    // ========================================================================== //

    /**
     * @dev Submit a lending offer via the offer book
     */
    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration) external nonReentrant {
        if (isClosed) revert MarketClosed();  // This is an error from base contract
        offerBook.submitOffer(amount, apr, seniority, duration);
    }

    /**
     * @dev Cancel an offer
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        offerBook.cancelOffer(offerId);
    }

    /**
     * @dev Claim interest on a position
     */
    function claimInterest(uint256 positionId) external nonReentrant {
        positionNFT.claimInterest(positionId);
    }

    // ========================================================================== //
    //                           Liquidation Functions                             //
    // ========================================================================== //

    /**
     * @dev Liquidate an undercollateralized position
     */
    function liquidate() external nonReentrant {
        if (!isLiquidatable()) revert InsufficientCollateral();

        uint256 debt = totalDebt;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        uint256 auctionId = liquidator.createAuction(address(this), borrower, collateral, debt);

        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.approve(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        emit PositionLiquidated(auctionId, msg.sender);
    }

    // ========================================================================== //
    //                               Admin Functions                               //
    // ========================================================================== //

    /**
     * @dev Set minimum collateral ratio
     */
    function setMinCollateralRatio(uint256 newRatio) external onlyBorrower {
        collateralEscrow.setMinCollateralRatio(newRatio);
    }

    /**
     * @dev Set liquidation threshold
     */
    function setLiquidationThreshold(uint256 newThreshold) external onlyBorrower {
        collateralEscrow.setLiquidationThreshold(newThreshold);
    }
}