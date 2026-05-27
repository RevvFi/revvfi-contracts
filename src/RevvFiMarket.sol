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
uint256 constant DUST_THRESHOLD = 1e6; // 1 USDC dust threshold

contract RevvFiMarket is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Storage variables (set in initialize)
    address public factory;
    address public archController;
    address public borrower;
    address public borrowAsset;
    address public collateralAsset;

    // Constants
    uint256 public constant MAX_APR_BPS = 5000;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_ACTIVE_POSITIONS = 100;

    // External contracts
    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;
    IReputationRegistry public reputationRegistry;

    // Debt accounting
    uint256 public totalPrincipal;
    uint256 public totalAccruedInterest;
    uint256 public lastInterestAccrualTime;

    mapping(uint256 => uint256) public positionPrincipal;
    mapping(uint256 => uint256) public positionAccruedInterest;
    mapping(uint256 => uint256) public positionApr;
    mapping(uint256 => uint8) public positionSeniority;
    mapping(uint256 => bool) public positionActive;
    mapping(uint256 => bool) public positionSettled;
    mapping(uint256 => uint256) public positionClaimableAmount;
    // FIXED: Store original lender for settled positions
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
        if (_factory == address(0) || _archController == address(0) || _borrower == address(0) ||
            _borrowAsset == address(0) || _collateralAsset == address(0)) {
            revert RevvFiErrors.ZeroAddress();
        }

        factory = _factory;
        archController = _archController;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        guardian = _factory;
        lastInterestAccrualTime = block.timestamp;
        isInitialized = true;
    }

    function setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator,
        address _reputationRegistry
    ) external onlyFactory {
        if (_collateralEscrow == address(0) || _offerBook == address(0) || _positionNFT == address(0) ||
            _liquidator == address(0) || _reputationRegistry == address(0)) {
            revert RevvFiErrors.ZeroAddress();
        }

        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);
        reputationRegistry = IReputationRegistry(_reputationRegistry);

        emit RevvFiEvents.ContractsSet();
    }

    function _accrueInterest() internal {
        uint256 calculatedTotalPrincipal = 0;
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId]) {
                calculatedTotalPrincipal += positionPrincipal[posId];
            }
        }

        if (calculatedTotalPrincipal != totalPrincipal) {
            totalPrincipal = calculatedTotalPrincipal;
        }

        if (totalPrincipal == 0) {
            lastInterestAccrualTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastInterestAccrualTime;
        if (elapsed == 0) return;

        uint256 totalInterestAccrued = 0;

        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (!positionActive[posId]) continue;

            uint256 interest = (positionPrincipal[posId] * positionApr[posId] * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);
            if (interest > 0) {
                positionAccruedInterest[posId] += interest;
                totalInterestAccrued += interest;
            }
        }

        totalAccruedInterest += totalInterestAccrued;
        lastInterestAccrualTime = block.timestamp;

        emit RevvFiEvents.InterestAccrued(borrower, totalAccruedInterest);
    }

    function _addActivePosition(uint256 positionId) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;
    }

    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        positionActive[positionId] = false;
        delete activePositionIndex[positionId];
    }

    function _recalculateTotals() internal {
        uint256 newTotalPrincipal = 0;
        uint256 newTotalAccruedInterest = 0;

        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId]) {
                newTotalPrincipal += positionPrincipal[posId];
                newTotalAccruedInterest += positionAccruedInterest[posId];
            }
        }

        totalPrincipal = newTotalPrincipal;
        totalAccruedInterest = newTotalAccruedInterest;
    }

    function sweepDustPositions() public onlyBorrower {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId] && positionPrincipal[posId] < DUST_THRESHOLD && positionPrincipal[posId] > 0) {
                // Store owner before settling
                if (settledPositionOwner[posId] == address(0)) {
                    settledPositionOwner[posId] = positionNFT.ownerOf(posId);
                }
                positionClaimableAmount[posId] += positionPrincipal[posId];
                positionPrincipal[posId] = 0;
                _settlePosition(posId);
            }
        }
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
        collateralEscrow.withdrawCollateral(borrower, amount, totalPrincipal + totalAccruedInterest);
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

        sweepDustPositions();

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

            positionPrincipal[tokenId] = filledOffers[i].remainingAmount;
            positionApr[tokenId] = filledOffers[i].apr;
            positionSeniority[tokenId] = filledOffers[i].seniority;
            positionSettled[tokenId] = false;
            positionAccruedInterest[tokenId] = 0;
            positionClaimableAmount[tokenId] = 0;

            _addActivePosition(tokenId);
        }

        totalPrincipal += amount;

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

        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();
        if (amount > totalOwed) amount = totalOwed;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepayment(amount);
        _recalculateTotals();

        bool hasRemainingDebt = false;
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId] && (positionPrincipal[posId] > DUST_THRESHOLD || positionAccruedInterest[posId] > 0)) {
                hasRemainingDebt = true;
                break;
            }
        }

        if (!hasRemainingDebt && address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    function _distributeRepayment(uint256 repaymentAmount) internal {
        if (totalPrincipal == 0 && totalAccruedInterest == 0) return;

        uint256 remainingRepayment = repaymentAmount;
        uint256 originalTotalInterest = totalAccruedInterest;
        uint256 originalTotalPrincipal = totalPrincipal;
        uint256[] memory positions = activePositionIds;

        // Distribute interest first
        if (originalTotalInterest > 0 && remainingRepayment > 0) {
            uint256 interestPayment = remainingRepayment < originalTotalInterest ? remainingRepayment : originalTotalInterest;

            for (uint256 i = 0; i < positions.length; i++) {
                uint256 posId = positions[i];
                if (!positionActive[posId]) continue;

                uint256 positionInterest = positionAccruedInterest[posId];
                if (positionInterest == 0) continue;

                uint256 share = (interestPayment * positionInterest) / originalTotalInterest;
                if (share > positionInterest) share = positionInterest;
                if (share == 0) continue;

                positionClaimableAmount[posId] += share;
                positionAccruedInterest[posId] -= share;
                remainingRepayment -= share;
            }
        }

        // Distribute principal second
        if (originalTotalPrincipal > 0 && remainingRepayment > 0) {
            uint256 principalPayment = remainingRepayment < originalTotalPrincipal ? remainingRepayment : originalTotalPrincipal;

            for (uint256 i = 0; i < positions.length; i++) {
                uint256 posId = positions[i];
                if (!positionActive[posId]) continue;

                uint256 principal = positionPrincipal[posId];
                if (principal == 0) continue;

                uint256 share = (principalPayment * principal) / originalTotalPrincipal;
                if (share > principal) share = principal;
                if (share == 0) continue;

                positionClaimableAmount[posId] += share;
                positionPrincipal[posId] -= share;
                remainingRepayment -= share;
            }
        }

        // Clean up dust positions
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            if (positionPrincipal[posId] < DUST_THRESHOLD && positionPrincipal[posId] > 0) {
                // Store owner before settling if not already stored
                if (settledPositionOwner[posId] == address(0)) {
                    settledPositionOwner[posId] = positionNFT.ownerOf(posId);
                }
                positionClaimableAmount[posId] += positionPrincipal[posId];
                positionPrincipal[posId] = 0;
            }
            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }
    }

    function repayFull() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);

        uint256[] memory positionsToSettle = activePositionIds;

        for (uint256 i = 0; i < positionsToSettle.length; i++) {
            uint256 posId = positionsToSettle[i];
            if (!positionActive[posId]) continue;

            uint256 totalPositionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            positionClaimableAmount[posId] += totalPositionValue;
            positionPrincipal[posId] = 0;
            positionAccruedInterest[posId] = 0;
            _settlePosition(posId);
        }

        uint256 repaidAmount = totalOwed;
        totalPrincipal = 0;
        totalAccruedInterest = 0;

        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, repaidAmount, 0, repaidAmount);
    }

    // FIXED: Claim funds even after position is settled (NFT burned)
    function claimFunds(uint256 positionId) external nonReentrant initializedCheck {
        uint256 claimable = positionClaimableAmount[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        address claimant;
        if (positionSettled[positionId]) {
            // Use stored owner for settled positions
            claimant = settledPositionOwner[positionId];
            // Fallback to getLenderByTokenId if not stored (should not happen)
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

    // FIXED: Store owner before settling and burning NFT
    function _settlePosition(uint256 positionId) internal {
        if (!positionActive[positionId]) return;
        if (positionSettled[positionId]) return;

        // Store the original owner before settling if not already stored
        if (settledPositionOwner[positionId] == address(0)) {
            settledPositionOwner[positionId] = positionNFT.ownerOf(positionId);
        }
        
        positionActive[positionId] = false;
        positionSettled[positionId] = true;
        _removeActivePosition(positionId);
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

        uint256 debt = totalPrincipal + totalAccruedInterest;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        collateralEscrow.startLiquidation();
        isLiquidating = true;

        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.forceApprove(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        liquidationAuctionId = liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);
        liquidator.receiveCollateral(liquidationAuctionId);

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

    function settleLiquidation(uint256 debtRepaid, uint256) external {
        if (msg.sender != address(liquidator)) revert RevvFiErrors.UnauthorizedCaller();
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        uint256 originalDebt = totalPrincipal + totalAccruedInterest;

        if (debtRepaid < originalDebt) {
            uint256 loss = originalDebt - debtRepaid;
            badDebt += loss;
            totalRealizedLoss += loss;
            _distributeLoss(loss);
        }

        if (debtRepaid > 0) {
            _distributeRepayment(debtRepaid);
        }

        _recalculateTotals();

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

        // Junior positions first (seniority == 1)
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 1) continue;

            uint256 positionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            if (positionValue >= remainingLoss) {
                uint256 reduction = remainingLoss;
                if (positionAccruedInterest[posId] >= reduction) {
                    positionAccruedInterest[posId] -= reduction;
                } else {
                    reduction -= positionAccruedInterest[posId];
                    positionAccruedInterest[posId] = 0;
                    if (positionPrincipal[posId] > reduction) {
                        positionPrincipal[posId] -= reduction;
                    } else {
                        positionPrincipal[posId] = 0;
                    }
                }
                remainingLoss = 0;
            } else {
                remainingLoss -= positionValue;
                positionPrincipal[posId] = 0;
                positionAccruedInterest[posId] = 0;
            }

            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }

        // Senior positions (seniority == 0)
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 0) continue;

            uint256 positionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            if (positionValue >= remainingLoss) {
                uint256 reduction = remainingLoss;
                if (positionAccruedInterest[posId] >= reduction) {
                    positionAccruedInterest[posId] -= reduction;
                } else {
                    reduction -= positionAccruedInterest[posId];
                    positionAccruedInterest[posId] = 0;
                    if (positionPrincipal[posId] > reduction) {
                        positionPrincipal[posId] -= reduction;
                    } else {
                        positionPrincipal[posId] = 0;
                    }
                }
                remainingLoss = 0;
            } else {
                remainingLoss -= positionValue;
                positionPrincipal[posId] = 0;
                positionAccruedInterest[posId] = 0;
            }

            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }
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
        if (totalPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    function getTotalOwed() public view returns (uint256) {
        uint256 calculatedTotal = 0;
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId]) {
                calculatedTotal += positionPrincipal[posId] + positionAccruedInterest[posId];
            }
        }
        return calculatedTotal;
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
        if (maxFromCollateral <= getTotalOwed()) return 0;
        return maxFromCollateral - getTotalOwed();
    }

    function getPositionClaimable(uint256 positionId) public view returns (uint256) {
        return positionClaimableAmount[positionId];
    }

    function getPositionValue(uint256 positionId) public view returns (uint256) {
        if (!positionActive[positionId]) return 0;
        return positionPrincipal[positionId] + positionAccruedInterest[positionId];
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
        return getTotalOwed();
    }
}