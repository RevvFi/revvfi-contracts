// SPDX-License-Identifier: MIT
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

/**
 * @title RevvFiMarket
 * @author Preet Singh
 * @notice Core lending market contract that manages borrowing, repayment, and lender claims
 * @dev Handles interest accrual, debt distribution, and coordinates with escrow and offer book
 */
contract RevvFiMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============================================================
    //                       Immutable Addresses
    // ============================================================

    /// @dev Factory that deployed this market
    address public immutable factory;

    /// @dev Arch controller for permission management
    address public immutable archController;

    /// @dev Borrower who controls this market
    address public immutable borrower;

    /// @dev Token being lent and borrowed (e.g., USDC)
    address public immutable borrowAsset;

    /// @dev Token used as collateral (e.g., WETH)
    address public immutable collateralAsset;

    // ============================================================
    //                         Constants
    // ============================================================

    /// @dev Maximum allowed APR in basis points (50%)
    uint256 public constant MAX_APR_BPS = 5000;

    /// @dev Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @dev Maximum number of active lending positions
    uint256 public constant MAX_ACTIVE_POSITIONS = 100;

    // ============================================================
    //                    External Contract References
    // ============================================================

    /// @dev Contract managing collateral deposits and withdrawals
    IRevvFiCollateralEscrow public collateralEscrow;

    /// @dev Contract handling lender offers and matching
    IRevvFiOfferBook public offerBook;

    /// @dev NFT representing lender positions
    IRevvFiPositionNFT public positionNFT;

    /// @dev Contract handling liquidation auctions
    IRevvFiLiquidator public liquidator;

    /// @dev Contract tracking borrower reputation
    IReputationRegistry public reputationRegistry;

    // ============================================================
    //                      Debt Accounting
    // ============================================================

    /// @dev Total outstanding principal across all positions
    uint256 public totalPrincipal;

    /// @dev Total accrued but unpaid interest
    uint256 public totalAccruedInterest;

    /// @dev Timestamp of last interest calculation
    uint256 public lastInterestAccrualTime;

    /// @dev Principal amount remaining for each position
    mapping(uint256 => uint256) public positionPrincipal;

    /// @dev Accrued interest for each position
    mapping(uint256 => uint256) public positionAccruedInterest;

    /// @dev APR for each position (in basis points)
    mapping(uint256 => uint256) public positionApr;

    /// @dev Seniority level of each position (0 = senior, 1 = junior)
    mapping(uint256 => uint8) public positionSeniority;

    /// @dev Whether a position is currently active
    mapping(uint256 => bool) public positionActive;

    /// @dev Whether a position has been fully settled
    mapping(uint256 => bool) public positionSettled;

    /// @dev Amount claimable by lender for each position
    mapping(uint256 => uint256) public positionClaimableAmount;

    /// @dev Last time interest was accrued for each position
    mapping(uint256 => uint256) public positionLastAccrualTime;

    // ============================================================
    //                   Active Position Tracking
    // ============================================================

    /// @dev List of all active position IDs
    uint256[] public activePositionIds;

    /// @dev Maps position ID to its index in activePositionIds
    mapping(uint256 => uint256) public activePositionIndex;

    // ============================================================
    //                      State Variables
    // ============================================================

    /// @dev Whether market is permanently closed
    bool public isClosed;

    /// @dev Whether market has been initialized with contracts
    bool public isInitialized;

    /// @dev Whether liquidation is currently in progress
    bool public isLiquidating;

    /// @dev ID of active liquidation auction
    uint256 public liquidationAuctionId;

    /// @dev Whether market operations are paused
    bool public isPaused;

    /// @dev Guardian address that can pause the market
    address public guardian;

    /// @dev Positions held by each lender (by position ID)
    mapping(address => uint256[]) public lenderPositions;

    // ============================================================
    //                      Bad Debt Tracking
    // ============================================================

    /// @dev Total bad debt accumulated
    uint256 public badDebt;

    /// @dev Total realized losses from defaults
    uint256 public totalRealizedLoss;

    // ============================================================
    //                         Modifiers
    // ============================================================

    /// @dev Restricts to the borrower who owns this market
    modifier onlyBorrower() {
        if (msg.sender != borrower) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts to the factory that deployed this market
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts to the guardian or factory
    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Ensures market is open for operations
    modifier marketOpen() {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        if (isPaused) revert RevvFiErrors.LiquidationInProgress();
        _;
    }

    /// @dev Ensures market has been initialized
    modifier initialized() {
        if (!isInitialized) revert RevvFiErrors.NotInitialized();
        _;
    }

    /// @dev Triggers interest accrual before executing function
    modifier accrueInterest() {
        _accrueInterest();
        _;
    }

    // ============================================================
    //                       Constructor
    // ============================================================

    /**
     * @dev Deploys a new lending market
     * @param _factory Address of the RevvFiFactory
     * @param _archController Address of the arch controller
     * @param _borrower Address that will control this market
     * @param _borrowAsset Token being borrowed (e.g., USDC)
     * @param _collateralAsset Token used as collateral (e.g., WETH)
     */
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

    // ============================================================
    //                   Interest Accrual Engine
    // ============================================================

    /**
     * @dev Calculates and adds interest to all active positions
     * @notice Called automatically before borrow, repay, and collateral operations
     */
    function _accrueInterest() internal {
        // Recalculate totalPrincipal from active positions to ensure consistency
        uint256 calculatedTotalPrincipal = 0;
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (positionActive[posId]) {
                calculatedTotalPrincipal += positionPrincipal[posId];
            }
        }

        // Sync totalPrincipal with calculated value
        if (calculatedTotalPrincipal != totalPrincipal) {
            totalPrincipal = calculatedTotalPrincipal;
        }

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

            // Interest = principal * APR (bps) * time / (seconds per year * 10000)
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

    /**
     * @dev Adds a position to the active tracking list
     * @param positionId ID of the position to add
     * @param principal Initial principal amount
     * @param apr APR for this position
     */
    function _addActivePosition(uint256 positionId, uint256 principal, uint256 apr) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;
        positionLastAccrualTime[positionId] = block.timestamp;
    }

    /**
     * @dev Removes a position from active tracking
     * @param positionId ID of the position to remove
     */
    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        // Swap with last element and pop for efficient removal
        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        positionActive[positionId] = false;
        delete activePositionIndex[positionId];
    }

    // ============================================================
    //                      Initialization
    // ============================================================

    /**
     * @dev Sets external contract references (factory only)
     * @param _collateralEscrow Address of collateral escrow
     * @param _offerBook Address of offer book
     * @param _positionNFT Address of position NFT contract
     * @param _liquidator Address of liquidator contract
     * @param _reputationRegistry Address of reputation registry
     */
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

    // ============================================================
    //                    Collateral Management
    // ============================================================

    /**
     * @dev Deposits collateral to secure borrowing
     * @param amount Amount of collateral to deposit
     */
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
        // Transfer from borrower to market
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        // Approve escrow to spend from market
        collateral.forceApprove(address(collateralEscrow), amount);

        // Escrow will transfer from market (msg.sender is market)
        collateralEscrow.depositCollateral(borrower, amount);
    }

    /**
     * @dev Withdraws collateral, ensuring position stays healthy
     * @param amount Amount of collateral to withdraw
     */
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

    // ============================================================
    //                         Borrowing
    // ============================================================

    /**
     * @dev Borrows funds by matching with lender offers
     * @param amount Amount to borrow
     * @param useSeniorOnly If true, only uses senior offers
     * @param maxApr Maximum weighted APR allowed
     */
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

    // ============================================================
    //                    Repayment Distribution
    // ============================================================

    /**
     * @dev Repays a portion of the debt
     * @param amount Amount to repay
     */
    function repay(uint256 amount) external onlyBorrower nonReentrant initialized accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalOwed = getTotalOwed();
        if (amount > totalOwed) amount = totalOwed;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepayment(amount);

        // Recalculate totals from active positions after distribution
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

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    /**
     * @dev Distributes repayment proportionally to active positions
     * @param repaymentAmount Total amount being repaid
     */
    function _distributeRepayment(uint256 repaymentAmount) internal {
        if (totalPrincipal == 0 && totalAccruedInterest == 0) return;

        uint256 remainingRepayment = repaymentAmount;

        // Store original totals for proportional calculation
        uint256 originalTotalInterest = totalAccruedInterest;
        uint256 originalTotalPrincipal = totalPrincipal;

        // First, distribute to accrued interest
        if (originalTotalInterest > 0 && remainingRepayment > 0) {
            uint256 totalInterestPayment =
                remainingRepayment < originalTotalInterest ? remainingRepayment : originalTotalInterest;

            for (uint256 i = 0; i < activePositionIds.length && totalInterestPayment > 0; i++) {
                uint256 posId = activePositionIds[i];
                if (!positionActive[posId]) continue;
                if (positionAccruedInterest[posId] == 0) continue;

                uint256 positionInterestShare =
                    (totalInterestPayment * positionAccruedInterest[posId]) / originalTotalInterest;
                if (positionInterestShare > positionAccruedInterest[posId]) {
                    positionInterestShare = positionAccruedInterest[posId];
                }
                if (positionInterestShare > 0) {
                    positionClaimableAmount[posId] += positionInterestShare;
                    positionAccruedInterest[posId] -= positionInterestShare;
                    totalInterestPayment -= positionInterestShare;
                    remainingRepayment -= positionInterestShare;
                }
            }
        }

        // Then, distribute to principal
        if (originalTotalPrincipal > 0 && remainingRepayment > 0) {
            uint256 totalPrincipalPayment =
                remainingRepayment < originalTotalPrincipal ? remainingRepayment : originalTotalPrincipal;

            for (uint256 i = 0; i < activePositionIds.length && totalPrincipalPayment > 0; i++) {
                uint256 posId = activePositionIds[i];
                if (!positionActive[posId]) continue;
                if (positionPrincipal[posId] == 0) continue;

                uint256 positionPrincipalShare =
                    (totalPrincipalPayment * positionPrincipal[posId]) / originalTotalPrincipal;
                if (positionPrincipalShare > positionPrincipal[posId]) {
                    positionPrincipalShare = positionPrincipal[posId];
                }
                if (positionPrincipalShare > 0) {
                    positionClaimableAmount[posId] += positionPrincipalShare;
                    positionPrincipal[posId] -= positionPrincipalShare;
                    totalPrincipalPayment -= positionPrincipalShare;
                    remainingRepayment -= positionPrincipalShare;
                }
            }
        }
    }

    /**
     * @dev Repays the entire outstanding debt
     */
    function repayFull() external onlyBorrower nonReentrant initialized accrueInterest {
        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);

        // Distribute full repayment - store positions in a separate array to avoid modification during iteration
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

        if (address(reputationRegistry) != address(0)) {
            reputationRegistry.recordSuccessfulRepayment(borrower, repaidAmount);
        }

        emit RevvFiEvents.Repay(borrower, repaidAmount, 0, repaidAmount);
    }

    // ============================================================
    //                       Lender Claims
    // ============================================================

    /**
     * @dev Lender claims available funds from a position
     * @param positionId ID of the position to claim from
     */
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

    /**
     * @dev Marks a position as settled and burns the NFT
     * @param positionId ID of the position to settle
     */
    function _settlePosition(uint256 positionId) internal {
        positionActive[positionId] = false;
        positionSettled[positionId] = true;
        _removeActivePosition(positionId);
        positionNFT.redeemPosition(positionId);
    }

    // ============================================================
    //                      Offer Management
    // ============================================================

    /**
     * @dev Submits a lending offer (anyone can call)
     * @param amount Amount to lend
     * @param apr Annual percentage rate in basis points
     * @param seniority 0 for senior, 1 for junior
     * @param duration Duration of the offer in seconds
     */
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

    /**
     * @dev Cancels an existing lending offer
     * @param offerId ID of the offer to cancel
     */
    function cancelOffer(uint256 offerId) external nonReentrant initialized {
        offerBook.cancelOffer(offerId);
    }

    // ============================================================
    //                       Liquidation
    // ============================================================

    /**
     * @dev Begins liquidation process for underwater position
     * @notice Anyone can trigger this when collateral ratio is too low
     */
    function startLiquidation() public initialized accrueInterest {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = totalPrincipal + totalAccruedInterest;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        // Start liquidation in escrow first
        collateralEscrow.startLiquidation();

        // Mark market as liquidating
        isLiquidating = true;

        // Approve liquidator to take collateral
        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.approve(address(liquidator), collateral);

        // Execute liquidation in escrow
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        // Create auction for the collateral
        liquidationAuctionId =
            liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);

        liquidator.receiveCollateral(liquidationAuctionId);

        emit RevvFiEvents.LiquidationStartedMarket(borrower);
    }

    /**
     * @dev Ends liquidation process (factory only)
     */
    function endLiquidation() external onlyFactory nonReentrant {
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        if (isLiquidatable()) {
            revert RevvFiErrors.InsufficientCollateral();
        }

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    /**
     * @dev Settles liquidation after auction completes
     * @param debtRepaid Amount of debt repaid from auction
     */
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

    /**
     * @dev External liquidation trigger
     */
    function liquidate() external initialized {
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        startLiquidation();
    }

    // ============================================================
    //                       Loss Handling
    // ============================================================

    /**
     * @dev Records a loss amount as bad debt
     * @param lossAmount Amount of loss to record
     */
    function _realizeLoss(uint256 lossAmount) internal {
        badDebt += lossAmount;
        totalRealizedLoss += lossAmount;
    }

    /**
     * @dev Distributes loss to lenders according to seniority
     * @param lossAmount Amount of loss to distribute
     */
    function _distributeLoss(uint256 lossAmount) internal {
        uint256 remainingLoss = lossAmount;

        // Junior positions first (higher risk, seniority == 1)
        for (uint256 i = 0; i < activePositionIds.length && remainingLoss > 0; i++) {
            uint256 posId = activePositionIds[i];
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
                _settlePosition(posId);
            }
        }

        // Senior positions (protected, seniority == 0)
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

    // ============================================================
    //                     Emergency Controls
    // ============================================================

    /**
     * @dev Pauses all market operations
     */
    function pause() external onlyGuardian {
        isPaused = true;
    }

    /**
     * @dev Unpauses market operations
     */
    function unpause() external onlyGuardian {
        isPaused = false;
    }

    /**
     * @dev Updates guardian address (factory only)
     * @param newGuardian New guardian address
     */
    function setGuardian(address newGuardian) external onlyFactory {
        if (newGuardian == address(0)) revert RevvFiErrors.ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit RevvFiEvents.GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @dev Permanently closes the market after all debt is repaid
     */
    function closeMarket() external onlyBorrower nonReentrant initialized accrueInterest {
        if (totalPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    // ============================================================
    //                       View Functions
    // ============================================================

    /**
     * @dev Returns total assets held by the market
     * @return Balance of borrow asset in the market
     */
    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    /**
     * @dev Manually triggers interest accrual
     */
    function triggerAccrueInterest() external {
        _accrueInterest();
    }

    /**
     * @dev Calculates total outstanding debt from active positions
     * @return Sum of principal and interest across all active positions
     */
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

    /**
     * @dev Returns current collateral ratio
     * @return Collateral ratio in basis points
     */
    function getCollateralRatio() public view returns (uint256) {
        return collateralEscrow.getCollateralRatio(borrower, getTotalOwed());
    }

    /**
     * @dev Checks if position meets minimum collateral requirement
     * @return True if collateral ratio >= minCollateralRatio
     */
    function isHealthy() public view returns (bool) {
        return collateralEscrow.isHealthy(borrower, getTotalOwed());
    }

    /**
     * @dev Checks if position can be liquidated
     * @return True if collateral ratio < liquidationThreshold
     */
    function isLiquidatable() public view returns (bool) {
        return collateralEscrow.isLiquidatable(borrower, getTotalOwed());
    }

    /**
     * @dev Calculates maximum additional borrowable amount
     * @return Additional amount that can be borrowed
     */
    function getMaxBorrowable() public view returns (uint256) {
        uint256 maxFromCollateral = collateralEscrow.getMaxBorrowable(borrower);
        if (maxFromCollateral <= getTotalOwed()) return 0;
        return maxFromCollateral - getTotalOwed();
    }

    /**
     * @dev Returns claimable amount for a position
     * @param positionId Position to query
     * @return Amount available for claiming
     */
    function getPositionClaimable(uint256 positionId) public view returns (uint256) {
        return positionClaimableAmount[positionId];
    }

    /**
     * @dev Returns total value (principal + interest) of a position
     * @param positionId Position to query
     * @return Total value of the position
     */
    function getPositionValue(uint256 positionId) public view returns (uint256) {
        if (!positionActive[positionId]) return 0;
        return positionPrincipal[positionId] + positionAccruedInterest[positionId];
    }

    /**
     * @dev Returns number of active positions
     * @return Count of active positions
     */
    function getActivePositionsCount() public view returns (uint256) {
        return activePositionIds.length;
    }

    /**
     * @dev Returns paginated list of active position IDs
     * @param start Starting index
     * @param limit Maximum number to return
     * @return result Array of position IDs
     */
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
