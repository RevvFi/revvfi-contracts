// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IRevvFiArchController.sol";
import "./interfaces/IRevvFiCollateralEscrow.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./interfaces/IRevvFiLiquidator.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public immutable factory;
    address public immutable archController;
    address public immutable borrower;
    address public immutable borrowAsset;
    address public immutable collateralAsset;

    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;

    uint256 public totalPrincipal;
    uint256 public totalAccruedInterest;
    uint256 public totalAvailableLiquidity;
    uint256 public lastInterestAccrualTime;

    mapping(uint256 => uint256) public positionPrincipal;
    mapping(uint256 => uint256) public positionRemainingPrincipal;
    mapping(uint256 => uint256) public positionClaimablePrincipal;
    mapping(uint256 => uint256) public positionAccruedInterest;
    mapping(uint256 => uint256) public positionClaimableInterest;
    mapping(uint256 => uint256) public positionApr;
    mapping(uint256 => bool) public positionSettled;

    bool public isClosed;
    bool public isInitialized;
    bool public isLiquidating;
    uint256 public liquidationAuctionId;

    mapping(address => uint256[]) public lenderPositions;

    uint256 public totalRepaidPrincipal;
    uint256 public totalRepaidInterest;

    modifier onlyBorrower() {
        if (msg.sender != borrower) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier marketOpen() {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        _;
    }

    modifier initialized() {
        if (!isInitialized) revert RevvFiErrors.NotInitialized();
        _;
    }

    constructor(
        address _factory,
        address _archController,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset
    ) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_archController == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrower == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrowAsset == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_collateralAsset == address(0)) revert RevvFiErrors.ZeroAddress();

        factory = _factory;
        archController = _archController;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;

        isClosed = false;
        isInitialized = false;
        isLiquidating = false;
        totalPrincipal = 0;
        totalAccruedInterest = 0;
        totalAvailableLiquidity = 0;
        totalRepaidPrincipal = 0;
        totalRepaidInterest = 0;
        lastInterestAccrualTime = block.timestamp;
    }

    function setContracts(address _collateralEscrow, address _offerBook, address _positionNFT, address _liquidator)
        external
        onlyFactory
    {
        if (isInitialized) revert RevvFiErrors.AlreadyInitialized();

        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);

        positionNFT.registerMarket(address(this));

        isInitialized = true;
        emit RevvFiEvents.ContractsSet();
    }

    function _updateAvailableLiquidity() internal {
        totalAvailableLiquidity = IERC20(borrowAsset).balanceOf(address(this));
    }

    function depositCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen initialized {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 collateral = IERC20(collateralAsset);
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateral.forceApprove(address(collateralEscrow), amount);

        collateralEscrow.depositCollateral(borrower, amount);
    }

    function withdrawCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen initialized {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 currentDebt = totalPrincipal + totalAccruedInterest;
        collateralEscrow.withdrawCollateral(borrower, amount, currentDebt);
    }

    function _distributeRepayment(uint256 principalAmount, uint256 interestAmount) internal {
        totalRepaidPrincipal += principalAmount;
        totalRepaidInterest += interestAmount;
    }

    function borrow(uint256 amount, bool useSeniorOnly, uint256 maxApr)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initialized
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();

        uint256 maxBorrowable = getMaxBorrowable();
        if (amount > maxBorrowable) revert RevvFiErrors.BorrowAmountTooHigh();

        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) =
            offerBook.executeDrawdown(amount, useSeniorOnly);

        if (weightedApr > maxApr) revert RevvFiErrors.MaxAprExceeded();
        if (filledOffers.length == 0) revert RevvFiErrors.NoOffersAvailable();

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

            positionPrincipal[tokenId] = filledOffers[i].remainingAmount;
            positionRemainingPrincipal[tokenId] = filledOffers[i].remainingAmount;
            positionClaimablePrincipal[tokenId] = 0;
            positionApr[tokenId] = filledOffers[i].apr;
            positionAccruedInterest[tokenId] = 0;
            positionClaimableInterest[tokenId] = 0;
            positionSettled[tokenId] = false;
        }

        totalPrincipal += amount;
        _updateAvailableLiquidity();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(borrower, amount);

        emit RevvFiEvents.Borrow(borrower, amount, weightedApr);
        emit RevvFiEvents.DrawdownExecuted(amount, weightedApr, positionIds);
    }

    function repay(uint256 amount) external onlyBorrower nonReentrant initialized {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalOwed = totalPrincipal + totalAccruedInterest;
        if (amount > totalOwed) amount = totalOwed;
        if (amount == 0) revert RevvFiErrors.InsufficientRepayment();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);
        _updateAvailableLiquidity();

        uint256 interestPortion = amount.min(totalAccruedInterest);
        uint256 principalPortion = amount - interestPortion;

        if (interestPortion > 0) {
            totalAccruedInterest -= interestPortion;
            _distributeRepayment(0, interestPortion);
        }

        if (principalPortion > 0) {
            totalPrincipal -= principalPortion;
            _distributeRepayment(principalPortion, 0);
        }

        emit RevvFiEvents.Repay(borrower, amount, interestPortion, principalPortion);
    }

    function repayFull() external onlyBorrower nonReentrant initialized {
        uint256 totalOwed = totalPrincipal + totalAccruedInterest;
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);
        _updateAvailableLiquidity();

        _distributeRepayment(totalPrincipal, totalAccruedInterest);

        totalPrincipal = 0;
        totalAccruedInterest = 0;

        emit RevvFiEvents.Repay(borrower, totalOwed, totalAccruedInterest, totalPrincipal);
    }

    function claimPrincipal(uint256 positionId) external nonReentrant initialized {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (positionSettled[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();

        uint256 claimable = positionClaimablePrincipal[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        positionClaimablePrincipal[positionId] = 0;
        positionRemainingPrincipal[positionId] -= claimable;
        _updateAvailableLiquidity();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        if (positionRemainingPrincipal[positionId] == 0 && positionClaimableInterest[positionId] == 0) {
            positionSettled[positionId] = true;
            positionNFT.redeemPosition(positionId, claimable, positionClaimableInterest[positionId]);
        }

        emit RevvFiEvents.PositionSettled(positionId, claimable, 0);
    }

    function claimInterest(uint256 positionId) external nonReentrant initialized {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (positionSettled[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();

        uint256 claimable = positionClaimableInterest[positionId];
        if (claimable == 0) revert RevvFiErrors.NoInterestToClaim();

        positionClaimableInterest[positionId] = 0;
        _updateAvailableLiquidity();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        if (positionRemainingPrincipal[positionId] == 0 && positionClaimablePrincipal[positionId] == 0) {
            positionSettled[positionId] = true;
            positionNFT.redeemPosition(positionId, positionClaimablePrincipal[positionId], claimable);
        }

        emit RevvFiEvents.PositionSettled(positionId, 0, claimable);
    }

    function closeMarket() external onlyBorrower nonReentrant initialized {
        if (totalPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration)
        external
        nonReentrant
        initialized
    {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        offerBook.submitOffer(amount, apr, seniority, duration);
    }

    function cancelOffer(uint256 offerId) external nonReentrant initialized {
        offerBook.cancelOffer(offerId);
    }

    function startLiquidation() public nonReentrant initialized {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = totalPrincipal + totalAccruedInterest;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        liquidationAuctionId =
            liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);

        isLiquidating = true;
        collateralEscrow.startLiquidation(borrower);

        emit RevvFiEvents.LiquidationStartedMarket(borrower);
    }

    function endLiquidation() external onlyBorrower nonReentrant {
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    function liquidate() external nonReentrant initialized {
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();

        startLiquidation();
    }

    // View functions
    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    function getCollateralRatio() public view returns (uint256) {
        return collateralEscrow.getCollateralRatio(borrower, totalPrincipal + totalAccruedInterest);
    }

    function isHealthy() public view returns (bool) {
        return collateralEscrow.isHealthy(borrower, totalPrincipal + totalAccruedInterest);
    }

    function isLiquidatable() public view returns (bool) {
        return collateralEscrow.isLiquidatable(borrower, totalPrincipal + totalAccruedInterest);
    }

    function getMaxBorrowable() public view returns (uint256) {
        uint256 maxFromCollateral = collateralEscrow.getMaxBorrowable(borrower);
        uint256 totalOwed = totalPrincipal + totalAccruedInterest;
        if (maxFromCollateral <= totalOwed) return 0;
        return maxFromCollateral - totalOwed;
    }

    function getTotalOwed() public view returns (uint256) {
        return totalPrincipal + totalAccruedInterest;
    }

    function getPositionClaimablePrincipal(uint256 positionId) public view returns (uint256) {
        return positionClaimablePrincipal[positionId];
    }

    function getPositionClaimableInterest(uint256 positionId) public view returns (uint256) {
        return positionClaimableInterest[positionId];
    }

    function isLiquidationActive() public view returns (bool) {
        return isLiquidating;
    }
}
