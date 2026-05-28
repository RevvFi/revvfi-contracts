// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/IRevvFiArchController.sol";
import "./interfaces/IRevvFiCollateralEscrow.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./interfaces/IRevvFiLiquidator.sol";
import "./interfaces/IReputationRegistry.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant DUST_THRESHOLD = 1e6;
uint256 constant SCALE = 1e18;
uint256 constant FORCED_CLEANUP_THRESHOLD = 1e3;

contract RevvFiMarket is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public factory;
    address public archController;
    address public borrower;
    address public borrowAsset;
    address public collateralAsset;

    uint256 public constant MAX_APR_BPS = 5000;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_ACTIVE_POSITIONS = 100;

    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;
    IReputationRegistry public reputationRegistry;

    // Index-based debt accounting
    uint256 public totalScaledPrincipal;
    uint256 public lastInterestAccrualTime;
    uint256 public borrowIndex;

    // O(1) APR tracking using scaled values
    uint256 public weightedAprNumeratorScaled;
    uint256 public weightedAverageAPR;

    mapping(uint256 => uint256) public positionScaledPrincipal;
    mapping(uint256 => uint256) public positionApr;
    mapping(uint256 => uint8) public positionSeniority;
    mapping(uint256 => bool) public positionActive;
    mapping(uint256 => bool) public positionSettled;
    mapping(uint256 => uint256) public positionClaimableAmount;
    mapping(uint256 => address) public settledPositionOwner;

    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public activePositionIndex;

    bool public isClosed;
    bool public isInitialized;
    bool public isLiquidating;
    uint256 public liquidationAuctionId;
    bool public isPaused;
    address public guardian;

    mapping(address => uint256[]) public lenderPositions;

    uint256 public badDebt;
    uint256 public totalRealizedLoss;
    uint256 public currentCycleBorrowedAmount;

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
        if (isPaused) revert RevvFiErrors.MarketPaused();
        _;
    }

    modifier initializedCheck() {
        if (!isInitialized) revert RevvFiErrors.NotInitialized();
        _;
    }

    modifier accrueInterest() {
        _accrueInterest();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _factory,
        address _archController,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset
    ) external initializer {
        if (
            _factory == address(0) || _archController == address(0) || _borrower == address(0)
                || _borrowAsset == address(0) || _collateralAsset == address(0)
        ) {
            revert RevvFiErrors.ZeroAddress();
        }

        factory = _factory;
        archController = _archController;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        guardian = _factory;
        lastInterestAccrualTime = block.timestamp;
        borrowIndex = SCALE;
        isInitialized = true;
    }

    function setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator,
        address _reputationRegistry
    ) external onlyFactory {
        if (
            _collateralEscrow == address(0) || _offerBook == address(0) || _positionNFT == address(0)
                || _liquidator == address(0) || _reputationRegistry == address(0)
        ) {
            revert RevvFiErrors.ZeroAddress();
        }

        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);
        reputationRegistry = IReputationRegistry(_reputationRegistry);

        emit RevvFiEvents.ContractsSet();
    }

    // O(1) interest accrual
    function _accrueInterest() internal {
        if (totalScaledPrincipal == 0) {
            lastInterestAccrualTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastInterestAccrualTime;
        if (elapsed == 0) return;

        uint256 currentPrincipal = (totalScaledPrincipal * borrowIndex) / SCALE;
        uint256 totalInterestAccrued =
            (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);

        if (totalInterestAccrued > 0) {
            uint256 indexIncrease = (borrowIndex * totalInterestAccrued) / currentPrincipal;
            borrowIndex += indexIncrease;
        }

        lastInterestAccrualTime = block.timestamp;
        emit RevvFiEvents.InterestAccrued(borrower, (totalScaledPrincipal * borrowIndex) / SCALE);
    }

    function _getUpdatedBorrowIndex() internal view returns (uint256) {
        if (totalScaledPrincipal == 0) return borrowIndex;

        uint256 elapsed = block.timestamp - lastInterestAccrualTime;
        if (elapsed == 0) return borrowIndex;

        uint256 currentPrincipal = (totalScaledPrincipal * borrowIndex) / SCALE;
        uint256 totalInterestAccrued =
            (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);
        uint256 indexIncrease = (borrowIndex * totalInterestAccrued) / currentPrincipal;

        return borrowIndex + indexIncrease;
    }

    function _getPositionDebt(uint256 positionId) internal view returns (uint256) {
        if (!positionActive[positionId] || positionScaledPrincipal[positionId] == 0) return 0;
        uint256 currentIndex = _getUpdatedBorrowIndex();
        return (positionScaledPrincipal[positionId] * currentIndex) / SCALE;
    }

    function getTotalOwed() public view returns (uint256) {
        uint256 currentIndex = _getUpdatedBorrowIndex();
        return (totalScaledPrincipal * currentIndex) / SCALE;
    }

    function getCurrentPrincipal() public view returns (uint256) {
        return (totalScaledPrincipal * borrowIndex) / SCALE;
    }

    // ============================================================
    // APR TRACKING - O(1) INCREMENTAL UPDATES
    // ============================================================

    function _updateAPROnAdd(uint256 scaledPrincipal, uint256 apr) internal {
        weightedAprNumeratorScaled += scaledPrincipal * apr;
        _updateWeightedAverageAPR();
    }

    function _updateAPROnRemove(uint256 scaledPrincipal, uint256 apr) internal {
        uint256 reduction = scaledPrincipal * apr;
        if (reduction <= weightedAprNumeratorScaled) {
            weightedAprNumeratorScaled -= reduction;
        } else {
            weightedAprNumeratorScaled = 0;
        }
        _updateWeightedAverageAPR();
    }

    function _updateAPROnPrincipalChange(uint256 oldScaledPrincipal, uint256 newScaledPrincipal, uint256 apr) internal {
        if (oldScaledPrincipal == newScaledPrincipal) return;

        uint256 oldContribution = oldScaledPrincipal * apr;
        uint256 newContribution = newScaledPrincipal * apr;

        if (newContribution >= oldContribution) {
            weightedAprNumeratorScaled += newContribution - oldContribution;
        } else {
            uint256 reduction = oldContribution - newContribution;
            if (reduction <= weightedAprNumeratorScaled) {
                weightedAprNumeratorScaled -= reduction;
            } else {
                weightedAprNumeratorScaled = 0;
            }
        }
        _updateWeightedAverageAPR();
    }

    function _updateWeightedAverageAPR() internal {
        if (totalScaledPrincipal == 0) {
            weightedAverageAPR = 0;
            return;
        }
        weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal;
    }

    // ============================================================
    // POSITION MANAGEMENT - SEPARATED CONCERNS
    // ============================================================

    function _addActivePosition(uint256 positionId) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;

        _updateAPROnAdd(positionScaledPrincipal[positionId], positionApr[positionId]);
    }

    // _removeActivePosition ONLY manages array - NO APR logic
    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        delete activePositionIndex[positionId];
        positionActive[positionId] = false;
    }

    // FIXED: Safer pattern - read once, zero first, then subtract and update APR
    function _removePositionWithAPR(uint256 positionId) internal {
        uint256 remainingScaled = positionScaledPrincipal[positionId];

        // Zero first to prevent any reentrancy-like state confusion
        positionScaledPrincipal[positionId] = 0;

        if (remainingScaled > 0) {
            totalScaledPrincipal -= remainingScaled;
            _updateAPROnRemove(remainingScaled, positionApr[positionId]);
        }

        _removeActivePosition(positionId);
    }

    function depositCollateral(uint256 amount)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initializedCheck
        accrueInterest
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 collateral = IERC20(collateralAsset);
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateral.forceApprove(address(collateralEscrow), amount);

        collateralEscrow.depositCollateral(borrower, amount);
    }

    function withdrawCollateral(uint256 amount)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initializedCheck
        accrueInterest
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        collateralEscrow.withdrawCollateral(borrower, amount, getTotalOwed());
    }

    function borrow(uint256 amount, bool useSeniorOnly, uint256 maxApr)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initializedCheck
        accrueInterest
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();

        uint256 maxBorrowable = getMaxBorrowable();
        if (amount > maxBorrowable) revert RevvFiErrors.BorrowAmountTooHigh();

        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) =
            offerBook.executeDrawdown(amount, useSeniorOnly);

        if (weightedApr > maxApr) revert RevvFiErrors.MaxAprExceeded();
        if (weightedApr > MAX_APR_BPS) revert RevvFiErrors.MaxAprExceeded();
        if (filledOffers.length == 0) revert RevvFiErrors.NoOffersAvailable();

        if (activePositionIds.length + filledOffers.length > MAX_ACTIVE_POSITIONS) {
            revert RevvFiErrors.TooManyActivePositions();
        }

        currentCycleBorrowedAmount += amount;

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

            uint256 scaledPrincipal = (filledOffers[i].remainingAmount * SCALE) / borrowIndex;
            positionScaledPrincipal[tokenId] = scaledPrincipal;
            positionApr[tokenId] = filledOffers[i].apr;
            positionSeniority[tokenId] = filledOffers[i].seniority;
            positionSettled[tokenId] = false;
            positionClaimableAmount[tokenId] = 0;

            totalScaledPrincipal += scaledPrincipal;
            _addActivePosition(tokenId);
        }

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(borrower, amount);

        if (address(reputationRegistry) != address(0)) {
            reputationRegistry.recordBorrowActivity(borrower, amount);
        }

        emit RevvFiEvents.Borrow(borrower, amount, weightedApr);
        emit RevvFiEvents.DrawdownExecuted(amount, weightedApr, positionIds);
    }

    function repay(uint256 amount) external onlyBorrower nonReentrant initializedCheck accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalDebt = getTotalOwed();
        if (totalDebt == 0) revert RevvFiErrors.ZeroAmount();
        if (amount > totalDebt) amount = totalDebt;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepayment(amount);

        if (totalScaledPrincipal == 0) {
            if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
                reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
                currentCycleBorrowedAmount = 0;
            }
        }

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    function _distributeRepayment(uint256 repaymentAmount) internal {
        if (totalScaledPrincipal == 0) return;

        uint256 remainingRepayment = repaymentAmount;
        uint256 totalDebtBefore = getTotalOwed();
        uint256[] memory positions = activePositionIds;
        uint256 currentIndex = _getUpdatedBorrowIndex();

        for (uint256 i = 0; i < positions.length && remainingRepayment > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId] || positionScaledPrincipal[posId] == 0) continue;

            uint256 positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE;
            if (positionDebt == 0) continue;

            uint256 share = (repaymentAmount * positionDebt) / totalDebtBefore;
            if (share > remainingRepayment) share = remainingRepayment;
            if (share == 0) continue;

            positionClaimableAmount[posId] += share;

            uint256 oldScaledPrincipal = positionScaledPrincipal[posId];
            uint256 scaledReduction = (share * SCALE) / currentIndex;
            totalScaledPrincipal -= scaledReduction;
            positionScaledPrincipal[posId] -= scaledReduction;

            _updateAPROnPrincipalChange(oldScaledPrincipal, positionScaledPrincipal[posId], positionApr[posId]);

            remainingRepayment -= share;
        }

        // Clean up dust positions
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            uint256 positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE;

            if (positionScaledPrincipal[posId] > 0 && positionDebt < DUST_THRESHOLD) {
                if (settledPositionOwner[posId] == address(0)) {
                    settledPositionOwner[posId] = positionNFT.ownerOf(posId);
                }
                positionClaimableAmount[posId] += positionDebt;
                _removePositionWithAPR(posId);
                _settlePosition(posId);
            } else if (positionScaledPrincipal[posId] == 0) {
                _removePositionWithAPR(posId);
                _settlePosition(posId);
            }
        }
    }

    function repayFull() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        uint256 totalDebt = getTotalOwed();
        if (totalDebt == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalDebt);

        uint256[] memory positionsToSettle = activePositionIds;
        uint256 currentIndex = _getUpdatedBorrowIndex();

        for (uint256 i = 0; i < positionsToSettle.length; i++) {
            uint256 posId = positionsToSettle[i];
            if (!positionActive[posId]) continue;

            uint256 positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE;
            positionClaimableAmount[posId] += positionDebt;
            _removePositionWithAPR(posId);
            _settlePosition(posId);
        }

        totalScaledPrincipal = 0;
        weightedAprNumeratorScaled = 0;
        weightedAverageAPR = 0;

        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, totalDebt, 0, totalDebt);
    }

    function claimFunds(uint256 positionId) external nonReentrant initializedCheck {
        uint256 claimable = positionClaimableAmount[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        uint256 contractBalance = IERC20(borrowAsset).balanceOf(address(this));
        if (claimable > contractBalance) revert RevvFiErrors.InsufficientCollateral();

        address claimant;
        if (positionSettled[positionId]) {
            claimant = settledPositionOwner[positionId];
            if (claimant == address(0)) {
                claimant = positionNFT.getLenderByTokenId(positionId);
            }
        } else {
            claimant = positionNFT.ownerOf(positionId);
        }

        if (claimant != msg.sender) revert RevvFiErrors.UnauthorizedCaller();

        positionClaimableAmount[positionId] = 0;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        emit RevvFiEvents.PositionSettled(positionId, claimable, 0);
    }

    // FIXED: _settlePosition - NO early return on positionActive
    function _settlePosition(uint256 positionId) internal {
        // Only check if already settled, not if active
        if (positionSettled[positionId]) return;

        if (settledPositionOwner[positionId] == address(0)) {
            settledPositionOwner[positionId] = positionNFT.ownerOf(positionId);
        }

        positionSettled[positionId] = true;
        positionNFT.redeemPosition(positionId);
    }

    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration)
        external
        nonReentrant
        initializedCheck
    {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        if (apr > MAX_APR_BPS) revert RevvFiErrors.MaxAprExceeded();
        offerBook.submitOffer(amount, apr, seniority, duration);
    }

    function cancelOffer(uint256 offerId) external nonReentrant initializedCheck {
        offerBook.cancelOffer(offerId);
    }

    function startLiquidation() public initializedCheck accrueInterest {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = getTotalOwed();
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        collateralEscrow.startLiquidation();
        isLiquidating = true;

        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.forceApprove(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        liquidationAuctionId =
            liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);
        liquidator.receiveCollateral(liquidationAuctionId);

        emit RevvFiEvents.LiquidationStartedMarket(borrower);
    }

    function endLiquidation() external onlyFactory nonReentrant {
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();
        if (isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    function settleLiquidation(uint256 debtRepaid, uint256) external {
        if (msg.sender != address(liquidator)) revert RevvFiErrors.UnauthorizedCaller();
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        uint256 originalDebt = getTotalOwed();

        if (debtRepaid < originalDebt) {
            uint256 loss = originalDebt - debtRepaid;
            badDebt += loss;
            totalRealizedLoss += loss;
            _distributeLoss(loss);
        }

        if (debtRepaid > 0) {
            _distributeRepayment(debtRepaid);
        }

        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordDefault(borrower, currentCycleBorrowedAmount, debtRepaid);
            currentCycleBorrowedAmount = 0;
        }

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    function liquidate() external initializedCheck {
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        startLiquidation();
    }

    function _distributeLoss(uint256 lossAmount) internal {
        uint256 remainingLoss = lossAmount;
        uint256[] memory positions = activePositionIds;
        uint256 currentIndex = _getUpdatedBorrowIndex();

        // Junior positions first (seniority == 1)
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 1) continue;

            uint256 positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE;
            if (positionDebt == 0) continue;

            if (positionDebt >= remainingLoss) {
                uint256 oldScaledPrincipal = positionScaledPrincipal[posId];
                uint256 scaledReduction = (remainingLoss * SCALE) / currentIndex;
                totalScaledPrincipal -= scaledReduction;
                positionScaledPrincipal[posId] -= scaledReduction;

                _updateAPROnPrincipalChange(oldScaledPrincipal, positionScaledPrincipal[posId], positionApr[posId]);

                remainingLoss = 0;
            } else {
                remainingLoss -= positionDebt;
                _removePositionWithAPR(posId);
                _settlePosition(posId);
            }
        }

        // Senior positions (seniority == 0)
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 0) continue;

            uint256 positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE;
            if (positionDebt == 0) continue;

            if (positionDebt >= remainingLoss) {
                uint256 oldScaledPrincipal = positionScaledPrincipal[posId];
                uint256 scaledReduction = (remainingLoss * SCALE) / currentIndex;
                totalScaledPrincipal -= scaledReduction;
                positionScaledPrincipal[posId] -= scaledReduction;

                _updateAPROnPrincipalChange(oldScaledPrincipal, positionScaledPrincipal[posId], positionApr[posId]);

                remainingLoss = 0;
            } else {
                remainingLoss -= positionDebt;
                _removePositionWithAPR(posId);
                _settlePosition(posId);
            }
        }
    }

    function forceCloseMarket() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        require(
            totalScaledPrincipal == 0 || (totalScaledPrincipal * borrowIndex) / SCALE < FORCED_CLEANUP_THRESHOLD,
            "Debt too high to force close"
        );

        uint256[] memory positions = activePositionIds;
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            if (positionActive[posId] && positionScaledPrincipal[posId] > 0) {
                uint256 positionDebt = (positionScaledPrincipal[posId] * borrowIndex) / SCALE;
                if (positionDebt < FORCED_CLEANUP_THRESHOLD) {
                    positionClaimableAmount[posId] += positionDebt;
                    _removePositionWithAPR(posId);
                    _settlePosition(posId);
                }
            }
        }

        if (totalScaledPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    function pause() external onlyGuardian {
        isPaused = true;
    }

    function unpause() external onlyGuardian {
        isPaused = false;
    }

    function setGuardian(address newGuardian) external onlyFactory {
        if (newGuardian == address(0)) revert RevvFiErrors.ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit RevvFiEvents.GuardianUpdated(oldGuardian, newGuardian);
    }

    function closeMarket() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        if (totalScaledPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

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
        uint256 totalDebt = getTotalOwed();
        if (maxFromCollateral <= totalDebt) return 0;
        return maxFromCollateral - totalDebt;
    }

    function getPositionClaimable(uint256 positionId) public view returns (uint256) {
        return positionClaimableAmount[positionId];
    }

    function getPositionValue(uint256 positionId) public view returns (uint256) {
        if (!positionActive[positionId]) return 0;
        return (positionScaledPrincipal[positionId] * _getUpdatedBorrowIndex()) / SCALE;
    }

    function getActivePositionsCount() public view returns (uint256) {
        return activePositionIds.length;
    }

    function getActivePositionsPaginated(uint256 start, uint256 limit) external view returns (uint256[] memory result) {
        if (start >= activePositionIds.length) return new uint256[](0);
        uint256 end = start + limit;
        if (end > activePositionIds.length) end = activePositionIds.length;
        result = new uint256[](end - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = activePositionIds[start + i];
        }
    }

    function totalDebt() external view returns (uint256) {
        return getTotalOwed();
    }

    function getCurrentDebtIndex() external view returns (uint256) {
        return borrowIndex;
    }
}
