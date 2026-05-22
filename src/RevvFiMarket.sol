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
import "./interfaces/IReputationRegistry.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

uint256 constant SECONDS_PER_YEAR = 365 days;

contract RevvFiMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

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

    uint256 public constant MAX_APR_BPS = 5000;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_ACTIVE_POSITIONS = 100;

    // ========================================================================== //
    //                           External Contracts                                //
    // ========================================================================== //

    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;
    IReputationRegistry public reputationRegistry;

    // ========================================================================== //
    //                           Debt Accounting                                   //
    // ========================================================================== //

    uint256 public totalPrincipal;
    uint256 public totalAccruedInterest;
    uint256 public lastInterestAccrualTime;

    // Per-position accounting
    mapping(uint256 => uint256) public positionPrincipal;
    mapping(uint256 => uint256) public positionAccruedInterest;
    mapping(uint256 => uint256) public positionApr;
    mapping(uint256 => uint8) public positionSeniority;
    mapping(uint256 => bool) public positionActive;
    mapping(uint256 => bool) public positionSettled;
    mapping(uint256 => uint256) public positionClaimableAmount;
    mapping(uint256 => uint256) public positionLastAccrualTime;

    // ========================================================================== //
    //                           Active Positions Tracking                         //
    // ========================================================================== //

    uint256[] public activePositionIds;
    mapping(uint256 => uint256) public activePositionIndex;

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
        totalAccruedInterest = 0;
        badDebt = 0;
        totalRealizedLoss = 0;
        lastInterestAccrualTime = block.timestamp;
    }

    // ========================================================================== //
    //                           Interest Accrual Engine                           //
    // ========================================================================== //

    function _accrueInterest() internal {
        if (totalPrincipal == 0) {
            lastInterestAccrualTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastInterestAccrualTime;
        if (elapsed == 0) return;

        // Accrue interest for each active position individually
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (!positionActive[posId]) continue;

            uint256 interest =
                (positionPrincipal[posId] * positionApr[posId] * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);
            if (interest > 0) {
                positionAccruedInterest[posId] += interest;
                totalAccruedInterest += interest;
            }
            positionLastAccrualTime[posId] = block.timestamp;
        }

        lastInterestAccrualTime = block.timestamp;
        emit RevvFiEvents.InterestAccrued(borrower, totalAccruedInterest);
    }

    function _addActivePosition(uint256 positionId, uint256 principal, uint256 apr) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;
        positionLastAccrualTime[positionId] = block.timestamp;
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

    // ========================================================================== //
    //                           Initialization                                    //
    // ========================================================================== //

    function setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator,
        address _reputationRegistry
    ) external onlyFactory {
        if (isInitialized) revert RevvFiErrors.AlreadyInitialized();

        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);
        reputationRegistry = IReputationRegistry(_reputationRegistry);

        positionNFT.registerMarket(address(this));

        isInitialized = true;
        emit RevvFiEvents.ContractsSet();
    }

    // ========================================================================== //
    //                           Collateral Management                             //
    // ========================================================================== //

    function depositCollateral(uint256 amount)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initialized
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
        initialized
        accrueInterest
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        collateralEscrow.withdrawCollateral(borrower, amount, totalPrincipal + totalAccruedInterest);
    }

    // ========================================================================== //
    //                           Borrowing                                         //
    // ========================================================================== //

    function borrow(uint256 amount, bool useSeniorOnly, uint256 maxApr)
        external
        onlyBorrower
        nonReentrant
        marketOpen
        initialized
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
            positionActive[tokenId] = true;
            positionSettled[tokenId] = false;
            positionAccruedInterest[tokenId] = 0;
            positionClaimableAmount[tokenId] = 0;

            _addActivePosition(tokenId, filledOffers[i].remainingAmount, filledOffers[i].apr);
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

    // ========================================================================== //
    //                           Repayment Distribution                            //
    // ========================================================================== //

    function repay(uint256 amount) external onlyBorrower nonReentrant initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalOwed = totalPrincipal + totalAccruedInterest;
        if (amount > totalOwed) amount = totalOwed;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepayment(amount);

        // FIXED: Use standard subtraction with underflow protection (no satSub)
        if (amount >= totalAccruedInterest) {
            uint256 principalPortion = amount - totalAccruedInterest;
            if (totalPrincipal > principalPortion) {
                totalPrincipal -= principalPortion;
            } else {
                totalPrincipal = 0;
            }
            totalAccruedInterest = 0;
        } else {
            totalAccruedInterest -= amount;
        }

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    function _distributeRepayment(uint256 repaymentAmount) internal {
        if (totalPrincipal == 0 && totalAccruedInterest == 0) return;

        uint256 remainingRepayment = repaymentAmount;

        // First, distribute to accrued interest (proportional by position interest)
        if (totalAccruedInterest > 0 && remainingRepayment > 0) {
            uint256 interestPayment = remainingRepayment < totalAccruedInterest ? remainingRepayment : totalAccruedInterest;

            for (uint256 i = 0; i < activePositionIds.length && interestPayment > 0; i++) {
                uint256 posId = activePositionIds[i];
                if (!positionActive[posId]) continue;
                if (positionAccruedInterest[posId] == 0) continue;

                uint256 positionInterestShare =
                    (interestPayment * positionAccruedInterest[posId]) / totalAccruedInterest;
                if (positionInterestShare > 0) {
                    positionClaimableAmount[posId] += positionInterestShare;
                    positionAccruedInterest[posId] -= positionInterestShare;
                    remainingRepayment -= positionInterestShare;
                }
            }
        }

        // Then, distribute to principal (proportional by position principal)
        if (totalPrincipal > 0 && remainingRepayment > 0) {
            uint256 principalPayment = remainingRepayment < totalPrincipal ? remainingRepayment : totalPrincipal;

            for (uint256 i = 0; i < activePositionIds.length && principalPayment > 0; i++) {
                uint256 posId = activePositionIds[i];
                if (!positionActive[posId]) continue;
                if (positionPrincipal[posId] == 0) continue;

                uint256 positionPrincipalShare = (principalPayment * positionPrincipal[posId]) / totalPrincipal;
                if (positionPrincipalShare > 0) {
                    positionClaimableAmount[posId] += positionPrincipalShare;
                    positionPrincipal[posId] -= positionPrincipalShare;
                    remainingRepayment -= positionPrincipalShare;
                }
            }
        }
    }

    function repayFull() external onlyBorrower nonReentrant initialized accrueInterest {
        uint256 totalOwed = totalPrincipal + totalAccruedInterest;
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);

        // Distribute full repayment
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
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

        if (address(reputationRegistry) != address(0)) {
            reputationRegistry.recordSuccessfulRepayment(borrower, repaidAmount);
        }

        emit RevvFiEvents.Repay(borrower, repaidAmount, 0, repaidAmount);
    }

    // ========================================================================== //
    //                           Lender Claims                                     //
    // ========================================================================== //

    function claimFunds(uint256 positionId) external nonReentrant initialized {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert RevvFiErrors.UnauthorizedCaller();
        if (positionSettled[positionId]) revert RevvFiErrors.PositionAlreadyRedeemed();
        if (!positionActive[positionId]) revert RevvFiErrors.PositionNotFound();

        uint256 claimable = positionClaimableAmount[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        positionClaimableAmount[positionId] = 0;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(msg.sender, claimable);

        if (positionPrincipal[positionId] == 0 && positionAccruedInterest[positionId] == 0) {
            _settlePosition(positionId);
        }

        emit RevvFiEvents.PositionSettled(positionId, claimable, 0);
    }

    function _settlePosition(uint256 positionId) internal {
        positionActive[positionId] = false;
        positionSettled[positionId] = true;
        _removeActivePosition(positionId);
        positionNFT.redeemPosition(positionId);
    }

    // ========================================================================== //
    //                           Offer Management                                  //
    // ========================================================================== //

    function submitOffer(uint256 amount, uint256 apr, uint8 seniority, uint256 duration)
        external
        nonReentrant
        initialized
    {
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

        uint256 debt = totalPrincipal + totalAccruedInterest;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.approve(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        liquidationAuctionId =
            liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);

        liquidator.receiveCollateral(liquidationAuctionId);

        isLiquidating = true;
        collateralEscrow.startLiquidation();

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

        if (debtRepaid < (totalPrincipal + totalAccruedInterest)) {
            uint256 loss = (totalPrincipal + totalAccruedInterest) - debtRepaid;
            _realizeLoss(loss);
            _distributeLoss(loss);
        }

        if (debtRepaid > 0) {
            _distributeRepayment(debtRepaid);
            
            // FIXED: Standard subtraction without satSub
            if (debtRepaid >= totalAccruedInterest) {
                uint256 principalPortion = debtRepaid - totalAccruedInterest;
                if (totalPrincipal > principalPortion) {
                    totalPrincipal -= principalPortion;
                } else {
                    totalPrincipal = 0;
                }
                totalAccruedInterest = 0;
            } else {
                totalAccruedInterest -= debtRepaid;
            }
        }

        if (address(reputationRegistry) != address(0)) {
            reputationRegistry.recordDefault(borrower, totalPrincipal + totalAccruedInterest + debtRepaid, debtRepaid);
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

    function _distributeLoss(uint256 lossAmount) internal {
        uint256 remainingLoss = lossAmount;

        // Junior positions first (seniority == 1)
        for (uint256 i = 0; i < activePositionIds.length && remainingLoss > 0; i++) {
            uint256 posId = activePositionIds[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 1) continue;

            uint256 positionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            if (positionValue >= remainingLoss) {
                // Reduce position claimable by loss amount
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
                _settlePosition(posId);
            }
        }

        // Senior positions (seniority == 0)
        for (uint256 i = 0; i < activePositionIds.length && remainingLoss > 0; i++) {
            uint256 posId = activePositionIds[i];
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
                _settlePosition(posId);
            }
        }
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

    function setGuardian(address newGuardian) external onlyFactory {
        if (newGuardian == address(0)) revert RevvFiErrors.ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit RevvFiEvents.GuardianUpdated(oldGuardian, newGuardian);
    }

    function closeMarket() external onlyBorrower nonReentrant initialized accrueInterest {
        if (totalPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    // ========================================================================== //
    //                           View Functions                                    //
    // ========================================================================== //

    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    function getTotalOwed() public view returns (uint256) {
        return totalPrincipal + totalAccruedInterest;
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
}