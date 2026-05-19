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
import "./libraries/RevvFiDebtAccounting.sol";

contract RevvFiMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using RevvFiDebtAccounting for *;

    // ========================================================================== //
    //                               Immutables                                    //
    // ========================================================================== //

    address public immutable factory;
    address public immutable archController;
    address public immutable borrower;
    address public immutable borrowAsset;
    address public immutable collateralAsset;

    // ========================================================================== //
    //                              Constants                                      //
    // ========================================================================== //

    uint256 public constant MAX_APR_BPS = 5000; // 50% max APR
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant BASIS_POINTS = 10000;

    // ========================================================================== //
    //                           External Contracts                                //
    // ========================================================================== //

    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;

    // ========================================================================== //
    //                           Debt Index Accounting                             //
    // ========================================================================== //

    RevvFiDebtAccounting.DebtIndex public debtIndex;
    uint256 public totalDebtShares;
    uint256 public totalPrincipal;

    // ========================================================================== //
    //                           Active Positions Tracking                         //
    // ========================================================================== //

    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public activePositionIndex;
    uint256 public totalActivePrincipal;
    uint256 public totalWeightedApr;

    // ========================================================================== //
    //                           Per-Position Accounting                           //
    // ========================================================================== //

    mapping(uint256 => uint256) public positionDebtShares;
    mapping(uint256 => uint256) public positionPrincipal;
    mapping(uint256 => uint256) public positionApr;
    mapping(uint256 => uint8) public positionSeniority;
    mapping(uint256 => bool) public positionActive;
    mapping(uint256 => bool) public positionSettled;

    // ========================================================================== //
    //                           Claimable Amounts                                 //
    // ========================================================================== //

    mapping(uint256 => uint256) public positionClaimablePrincipal;
    mapping(uint256 => uint256) public positionClaimableInterest;

    // ========================================================================== //
    //                           State Variables                                   //
    // ========================================================================== //

    bool public isClosed;
    bool public isInitialized;
    bool public isLiquidating;
    uint256 public liquidationAuctionId;
    bool public isPaused;
    address public guardian;

    mapping(address => uint256[]) public lenderPositions;

    // ========================================================================== //
    //                           Bad Debt Tracking                                 //
    // ========================================================================== //

    uint256 public badDebt;
    uint256 public totalRealizedLoss;

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyBorrower() {
        if (msg.sender != borrower) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier marketOpen() {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        if (isPaused) revert RevvFiErrors.LiquidationInProgress();
        _;
    }

    modifier notPaused() {
        if (isPaused) revert RevvFiErrors.LiquidationInProgress();
        _;
    }

    modifier initialized() {
        if (!isInitialized) revert RevvFiErrors.NotInitialized();
        _;
    }

    modifier accrueInterest() {
        _accrueInterest();
        _;
    }

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

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
        guardian = _factory;

        isClosed = false;
        isInitialized = false;
        isLiquidating = false;
        isPaused = false;
        totalPrincipal = 0;
        totalDebtShares = 0;
        totalActivePrincipal = 0;
        totalWeightedApr = 0;
        badDebt = 0;
        totalRealizedLoss = 0;

        debtIndex.cumulativeIndex = RAY;
        debtIndex.lastUpdateTime = block.timestamp;
    }

    // ========================================================================== //
    //                           Interest Accrual Engine                           //
    // ========================================================================== //

    function _accrueInterest() internal {
        if (totalDebtShares == 0) {
            debtIndex.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - debtIndex.lastUpdateTime;
        if (elapsed == 0) return;

        // Calculate weighted average APR from maintained totals
        uint256 weightedApr = totalActivePrincipal == 0 ? 0 : totalWeightedApr / totalActivePrincipal;

        if (weightedApr > 0) {
            debtIndex.cumulativeIndex = RevvFiDebtAccounting.updateIndex(
                debtIndex.cumulativeIndex,
                weightedApr,
                elapsed
            );
        }

        debtIndex.lastUpdateTime = block.timestamp;
    }

    function _updatePositionApr(uint256 positionId, uint256 newApr) internal {
        if (!positionActive[positionId]) return;

        uint256 oldApr = positionApr[positionId];
        uint256 principal = positionPrincipal[positionId];

        totalWeightedApr = totalWeightedApr - (principal * oldApr) + (principal * newApr);
        positionApr[positionId] = newApr;
    }

    function _addActivePosition(uint256 positionId, uint256 principal, uint256 apr) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        totalActivePrincipal += principal;
        totalWeightedApr += principal * apr;
    }

    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        totalActivePrincipal -= positionPrincipal[positionId];
        totalWeightedApr -= positionPrincipal[positionId] * positionApr[positionId];

        delete activePositionIndex[positionId];
    }

    function getTotalPrincipalValue() public view returns (uint256) {
        return RevvFiDebtAccounting.sharesToPrincipal(totalDebtShares, debtIndex.cumulativeIndex);
    }

    function getTotalOwed() public view returns (uint256) {
        return getTotalPrincipalValue();
    }

    function getPositionValue(uint256 positionId) public view returns (uint256) {
        if (!positionActive[positionId]) return 0;
        return RevvFiDebtAccounting.sharesToPrincipal(positionDebtShares[positionId], debtIndex.cumulativeIndex);
    }

    // ========================================================================== //
    //                           Initialization                                    //
    // ========================================================================== //

    function setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator
    ) external onlyFactory {
        if (isInitialized) revert RevvFiErrors.AlreadyInitialized();

        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);

        positionNFT.registerMarket(address(this));

        isInitialized = true;
        emit RevvFiEvents.ContractsSet();
    }

    // ========================================================================== //
    //                           Collateral Management                             //
    // ========================================================================== //

    function depositCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 collateral = IERC20(collateralAsset);
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateral.forceApprove(address(collateralEscrow), amount);

        collateralEscrow.depositCollateral(borrower, amount);
    }

    function withdrawCollateral(uint256 amount) external onlyBorrower nonReentrant marketOpen initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 currentDebt = getTotalOwed();
        collateralEscrow.withdrawCollateral(borrower, amount, currentDebt);
    }

    // ========================================================================== //
    //                           Borrowing                                         //
    // ========================================================================== //

    function borrow(
        uint256 amount,
        bool useSeniorOnly,
        uint256 maxApr
    ) external onlyBorrower nonReentrant marketOpen initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();

        uint256 maxBorrowable = getMaxBorrowable();
        if (amount > maxBorrowable) revert RevvFiErrors.BorrowAmountTooHigh();

        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) = offerBook.executeDrawdown(
            amount,
            useSeniorOnly
        );

        if (weightedApr > maxApr) revert RevvFiErrors.MaxAprExceeded();
        if (weightedApr > MAX_APR_BPS) revert RevvFiErrors.MaxAprExceeded();
        if (filledOffers.length == 0) revert RevvFiErrors.NoOffersAvailable();

        uint256[] memory positionIds = new uint256[](filledOffers.length);
        uint256 totalSharesAdded = 0;
        uint256 totalPrincipalAdded = 0;

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

            uint256 debtShares = RevvFiDebtAccounting.principalToShares(
                filledOffers[i].remainingAmount,
                debtIndex.cumulativeIndex
            );

            positionDebtShares[tokenId] = debtShares;
            positionPrincipal[tokenId] = filledOffers[i].remainingAmount;
            positionApr[tokenId] = filledOffers[i].apr;
            positionSeniority[tokenId] = filledOffers[i].seniority;
            positionActive[tokenId] = true;
            positionSettled[tokenId] = false;

            _addActivePosition(tokenId, filledOffers[i].remainingAmount, filledOffers[i].apr);

            totalSharesAdded += debtShares;
            totalPrincipalAdded += filledOffers[i].remainingAmount;
        }

        totalDebtShares += totalSharesAdded;
        totalPrincipal += totalPrincipalAdded;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(borrower, amount);

        emit RevvFiEvents.Borrow(borrower, amount, weightedApr);
        emit RevvFiEvents.DrawdownExecuted(amount, weightedApr, positionIds);
    }

    // ========================================================================== //
    //                           Repayment Distribution                            //
    // ========================================================================== //

    function repay(uint256 amount) external onlyBorrower nonReentrant initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalOwed = getTotalOwed();
        if (amount > totalOwed) amount = totalOwed;
        if (amount == 0) revert RevvFiErrors.InsufficientRepayment();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepaymentProportionally(amount);

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    function _distributeRepaymentProportionally(uint256 repaymentAmount) internal {
        if (totalDebtShares == 0) return;

        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 positionId = activePositionIds[i];
            if (!positionActive[positionId]) continue;

            uint256 lenderRepayment = RevvFiDebtAccounting.distributeRepayment(
                totalDebtShares,
                positionDebtShares[positionId],
                repaymentAmount
            );

            if (lenderRepayment > 0) {
                positionClaimablePrincipal[positionId] += lenderRepayment;
            }
        }
    }

    function repayFull() external onlyBorrower nonReentrant initialized accrueInterest {
        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);

        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 positionId = activePositionIds[i];
            if (!positionActive[positionId]) continue;

            uint256 positionValue = getPositionValue(positionId);
            positionClaimablePrincipal[positionId] += positionValue;
        }

        totalDebtShares = 0;
        totalPrincipal = 0;

        emit RevvFiEvents.Repay(borrower, totalOwed, 0, totalOwed);
    }

    // ========================================================================== //
    //                           Lender Claims                                     //
    // ========================================================================== //

    function claimPrincipal(uint256 positionId) external nonReentrant initialized {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (positionSettled[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (!positionActive[positionId]) revert RevvFiErrors.PositionNotFound();

        uint256 claimable = positionClaimablePrincipal[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        positionClaimablePrincipal[positionId] = 0;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        if (positionClaimableInterest[positionId] == 0) {
            _settlePosition(positionId);
        }

        emit RevvFiEvents.PositionSettled(positionId, claimable, 0);
    }

    function claimInterest(uint256 positionId) external nonReentrant initialized accrueInterest {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (positionSettled[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (!positionActive[positionId]) revert RevvFiErrors.PositionNotFound();

        // Calculate accrued interest for this position
        uint256 currentValue = getPositionValue(positionId);
        uint256 originalPrincipal = positionPrincipal[positionId];
        uint256 accruedInterest = currentValue > originalPrincipal ? currentValue - originalPrincipal : 0;

        if (accruedInterest == 0 && positionClaimableInterest[positionId] == 0) {
            revert RevvFiErrors.NoInterestToClaim();
        }

        uint256 claimable = positionClaimableInterest[positionId] + accruedInterest;
        positionClaimableInterest[positionId] = 0;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        if (positionClaimablePrincipal[positionId] == 0) {
            _settlePosition(positionId);
        }

        emit RevvFiEvents.PositionSettled(positionId, 0, claimable);
    }

    function _settlePosition(uint256 positionId) internal {
        positionActive[positionId] = false;
        positionSettled[positionId] = true;
        _removeActivePosition(positionId);
        positionNFT.redeemPosition(positionId, positionClaimablePrincipal[positionId], positionClaimableInterest[positionId]);
    }

    // ========================================================================== //
    //                           Offer Management                                  //
    // ========================================================================== //

    function submitOffer(
        uint256 amount,
        uint256 apr,
        uint8 seniority,
        uint256 duration
    ) external nonReentrant initialized notPaused {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        if (apr > MAX_APR_BPS) revert RevvFiErrors.MaxAprExceeded();
        offerBook.submitOffer(amount, apr, seniority, duration);
    }

    function cancelOffer(uint256 offerId) external nonReentrant initialized {
        offerBook.cancelOffer(offerId);
    }

    // ========================================================================== //
    //                           Liquidation                                       //
    // ========================================================================== //

    function startLiquidation() public nonReentrant initialized accrueInterest {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = getTotalOwed();
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.approve(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        liquidationAuctionId = liquidator.createAuction(
            address(this),
            borrower,
            borrowAsset,
            collateralAsset,
            collateral,
            debt
        );

        liquidator.receiveCollateral(liquidationAuctionId);

        isLiquidating = true;
        collateralEscrow.startLiquidation(borrower);

        emit RevvFiEvents.LiquidationStartedMarket(borrower);
    }

    function endLiquidation() external onlyFactory nonReentrant {
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        if (isLiquidatable()) {
            revert RevvFiErrors.InsufficientCollateral();
        }

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    function settleLiquidation(uint256 auctionId, uint256 debtRepaid) external {
        if (msg.sender != address(liquidator)) revert RevvFiErrors.UnauthorizedCaller();
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        uint256 totalOwed = getTotalOwed();
        if (debtRepaid < totalOwed) {
            _realizeLoss(totalOwed - debtRepaid);
        }

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    function liquidate() external nonReentrant initialized {
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        startLiquidation();
    }

    // ========================================================================== //
    //                           Loss Handling                                     //
    // ========================================================================== //

    function _realizeLoss(uint256 lossAmount) internal {
        badDebt += lossAmount;
        totalRealizedLoss += lossAmount;
    }

    // ========================================================================== //
    //                           Emergency Controls                                //
    // ========================================================================== //

    function pause() external onlyGuardian {
        isPaused = true;
    }

    function unpause() external onlyGuardian {
        isPaused = false;
    }

    function closeMarket() external onlyBorrower nonReentrant initialized accrueInterest {
        if (totalDebtShares > 0) revert RevvFiErrors.InsufficientRepayment();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    // ========================================================================== //
    //                           View Functions                                    //
    // ========================================================================== //

    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    function getCollateralRatio() public view returns (uint256) {
        return collateralEscrow.getCollateralRatio(borrower, getTotalOwed());
    }

    function isHealthy() public view returns (bool) {
        return collateralEscrow.isHealthy(borrower, getTotalOwed());
    }

    function isLiquidatable() public view returns (bool) {
        return collateralEscrow.isLiquidatable(borrower, getTotalOwed());
    }

    function getMaxBorrowable() public view returns (uint256) {
        uint256 maxFromCollateral = collateralEscrow.getMaxBorrowable(borrower);
        uint256 totalOwed = getTotalOwed();
        if (maxFromCollateral <= totalOwed) return 0;
        return maxFromCollateral - totalOwed;
    }

    function isLiquidationActive() public view returns (bool) {
        return isLiquidating;
    }

    function getCurrentDebtIndex() public view returns (uint256) {
        return debtIndex.cumulativeIndex;
    }

    function getPositionDebtShares(uint256 positionId) public view returns (uint256) {
        return positionDebtShares[positionId];
    }

    function getPositionClaimablePrincipal(uint256 positionId) public view returns (uint256) {
        return positionClaimablePrincipal[positionId];
    }

    function getPositionClaimableInterest(uint256 positionId) public view returns (uint256) {
        return positionClaimableInterest[positionId];
    }

    function getActivePositionsCount() public view returns (uint256) {
        return activePositionIds.length;
    }
}