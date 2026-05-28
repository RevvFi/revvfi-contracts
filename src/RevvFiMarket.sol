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

// Protocol constants
uint256 constant SECONDS_PER_YEAR = 365 days; // Seconds in a year for APR calculations
uint256 constant DUST_THRESHOLD = 1e6; // Minimum debt threshold for cleanup (1 USDC dust)

/**
 * @title RevvFiMarket
 * @author Preet Singh
 * @notice Core lending market contract managing borrowing, lending, and position tracking
 * @dev Handles borrow/repay operations, interest accrual using Compound-style index, and liquidation coordination
 */
contract RevvFiMarket is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Storage variables (set in initialize)
    address public factory; // Factory contract that created this market
    address public archController; // Architecture controller for protocol permissions
    address public borrower; // Address authorized to borrow from this market
    address public borrowAsset; // Asset token that is borrowed (e.g., USDC)
    address public collateralAsset; // Asset token used as collateral

    // Constants
    uint256 public constant MAX_APR_BPS = 5000; // Maximum APR in basis points (50%)
    uint256 public constant BASIS_POINTS = 10000; // Basis points denominator (100%)
    uint256 public constant MAX_ACTIVE_POSITIONS = 100; // Maximum active positions per drawdown

    // External contracts
    IRevvFiCollateralEscrow public collateralEscrow; // Manages collateral deposits/withdrawals
    IRevvFiOfferBook public offerBook; // Manages lender offers for borrowing
    IRevvFiPositionNFT public positionNFT; // NFT representing lender positions
    IRevvFiLiquidator public liquidator; // Handles liquidation auctions
    IReputationRegistry public reputationRegistry; // Tracks borrower reputation

    // Debt accounting
    uint256 public totalPrincipal; // Total outstanding principal across all positions
    uint256 public totalAccruedInterest; // Total accrued but unpaid interest
    uint256 public lastInterestAccrualTime; // Timestamp of last interest calculation
    // OPTIMIZED: Cumulative interest index for true O(1) accrual
    // Uses Compound/Aave style index: borrowIndex = borrowIndex * (1 + interestRate)
    uint256 public borrowIndex = 1e18; // Starts at 1.0 (scaled 1e18)
    uint256 public weightedAverageAPR; // Current weighted average APR across all positions

    // Position-specific state
    mapping(uint256 => uint256) public positionPrincipal; // Position ID => Principal amount
    mapping(uint256 => uint256) public positionAccruedInterest; // Position ID => Accrued interest
    mapping(uint256 => uint256) public positionApr; // Position ID => APR in basis points
    mapping(uint256 => uint8) public positionSeniority; // Position ID => Seniority (0=senior, 1=junior)
    mapping(uint256 => bool) public positionActive; // Position ID => Active status
    mapping(uint256 => bool) public positionSettled; // Position ID => Settled status
    mapping(uint256 => uint256) public positionClaimableAmount; // Position ID => Claimable amount
    // OPTIMIZED: Store snapshot of borrowIndex when position was created
    mapping(uint256 => uint256) public positionBorrowIndex; // Position ID => Borrow index at creation
    // FIXED: Store original lender for settled positions
    mapping(uint256 => address) public settledPositionOwner; // Position ID => Original owner after settlement

    // Active positions array with index mapping for O(1) removal
    uint256[] public activePositionIds; // List of active position IDs
    mapping(uint256 => uint256) public activePositionIndex; // Position ID => Index in activePositionIds

    // Market state flags
    bool public isClosed; // Whether market is permanently closed
    bool public isInitialized; // Whether contract is initialized
    bool public isLiquidating; // Whether liquidation is in progress
    uint256 public liquidationAuctionId; // ID of current liquidation auction
    bool public isPaused; // Whether operations are paused
    address public guardian; // Address with pause/unpause authority

    // Lender and accounting data
    mapping(address => uint256[]) public lenderPositions; // Lender address => Position IDs owned

    // Loss and borrowing tracking
    uint256 public badDebt; // Total unrealized bad debt
    uint256 public totalRealizedLoss; // Total realized losses from liquidations
    uint256 public currentCycleBorrowedAmount; // Amount borrowed in current repayment cycle

    /**
     * @dev Modifier to restrict access to borrower only
     */
    modifier onlyBorrower() {
        if (msg.sender != borrower) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to factory only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to guardian or factory
     */
    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to ensure market is open for operations
     */
    modifier marketOpen() {
        if (isClosed) revert RevvFiErrors.MarketClosed();
        if (isLiquidating) revert RevvFiErrors.LiquidationInProgress();
        if (isPaused) revert RevvFiErrors.MarketPaused();
        _;
    }

    /**
     * @dev Modifier to ensure contract is initialized
     */
    modifier initializedCheck() {
        if (!isInitialized) revert RevvFiErrors.NotInitialized();
        _;
    }

    /**
     * @dev Modifier to accrue interest before state-changing operations
     */
    modifier accrueInterest() {
        _accrueInterest();
        _;
    }

    /**
     * @dev Constructor that disables initializers for implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the market contract (replaces constructor for upgradeable pattern)
     * @param _factory Address of the factory contract
     * @param _archController Address of the architecture controller
     * @param _borrower Address authorized to borrow from this market
     * @param _borrowAsset Address of the borrow asset token
     * @param _collateralAsset Address of the collateral asset token
     */
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
        isInitialized = true;
    }

    /**
     * @dev Sets external contract addresses after initialization
     * @param _collateralEscrow Address of collateral escrow contract
     * @param _offerBook Address of offer book contract
     * @param _positionNFT Address of position NFT contract
     * @param _liquidator Address of liquidator contract
     * @param _reputationRegistry Address of reputation registry contract
     */
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

    /**
     * @dev Recalculates weighted average APR across all active positions
     * @notice Called when positions are added or removed (O(N) operation)
     */
    function _recalculateWeightedAPR() internal {
        if (totalPrincipal == 0) {
            weightedAverageAPR = 0;
            return;
        }

        uint256 totalAprWeight = 0;
        uint256[] memory positions = activePositionIds;

        // O(N) recalculation only happens when positions are added/removed (not on every transaction)
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            if (positionActive[posId] && positionPrincipal[posId] > 0) {
                totalAprWeight += positionPrincipal[posId] * positionApr[posId];
            }
        }

        weightedAverageAPR = totalAprWeight / totalPrincipal;
    }

    /**
     * @dev Accrues interest based on elapsed time and current APR
     * @notice Uses Compound Finance index pattern for O(1) interest accrual
     */
    function _accrueInterest() internal {
        // OPTIMIZED: TRUE O(1) IMPLEMENTATION using cumulative interest index
        // Based on Compound Finance index pattern:
        // borrowIndex_new = borrowIndex_old * (1 + interestAccrued/totalPrincipal)
        // Per-position interest = principal * (borrowIndex_new / borrowIndex_old - 1)

        if (totalPrincipal == 0) {
            lastInterestAccrualTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastInterestAccrualTime;
        if (elapsed == 0) return;

        // Calculate total interest accrued (using weighted average APR)
        uint256 totalInterestAccrued =
            (totalPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);

        if (totalInterestAccrued > 0) {
            // Update cumulative index: new_index = old_index * (1 + interest/principal)
            // Expanded: new_index = old_index + old_index * interest / principal
            uint256 indexIncrease = (borrowIndex * totalInterestAccrued) / totalPrincipal;
            borrowIndex += indexIncrease;

            // Update total accrued interest
            totalAccruedInterest += totalInterestAccrued;
        }

        lastInterestAccrualTime = block.timestamp;

        emit RevvFiEvents.InterestAccrued(borrower, totalAccruedInterest);
    }

    /**
     * @dev Adds a position to the active positions array
     * @param positionId ID of the position to add
     */
    function _addActivePosition(uint256 positionId) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;
        // FIXED: Recalculate weighted APR when position is added
        _recalculateWeightedAPR();
    }

    /**
     * @dev Removes a position from active array
     * @param positionId ID of the position to remove
     */
    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        // Swap with last element and pop for O(1) removal
        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        positionActive[positionId] = false;
        delete activePositionIndex[positionId];
        // FIXED: Recalculate weighted APR when position is removed
        _recalculateWeightedAPR();
    }

    /**
     * @dev Cleans up dust positions with principal below dust threshold
     * @notice Only callable by borrower to maintain market health
     */
    function sweepDustPositions() public onlyBorrower {
        // FIXED: Use while loop to safely handle array mutations
        // Don't increment when removing to avoid skipping elements
        uint256 i = 0;
        while (i < activePositionIds.length) {
            uint256 posId = activePositionIds[i];

            if (positionActive[posId] && positionPrincipal[posId] < DUST_THRESHOLD && positionPrincipal[posId] > 0) {
                // Store owner before settling
                if (settledPositionOwner[posId] == address(0)) {
                    settledPositionOwner[posId] = positionNFT.ownerOf(posId);
                }
                positionClaimableAmount[posId] += positionPrincipal[posId];
                positionPrincipal[posId] = 0;
                _settlePosition(posId);
                // Don't increment i here - we skip it because array was modified
                continue;
            }

            i++;
        }
    }

    /**
     * @dev Deposits collateral into the escrow contract
     * @param amount Amount of collateral to deposit
     */
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

    /**
     * @dev Withdraws collateral from escrow if sufficient health factor
     * @param amount Amount of collateral to withdraw
     */
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

    /**
     * @dev Executes a borrow operation by accepting lender offers
     * @param amount Amount to borrow
     * @param useSeniorOnly Whether to only use senior offers
     * @param maxApr Maximum APR acceptable for this borrow
     */
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

        // Fetch offers from offer book and calculate weighted APR
        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) =
            offerBook.executeDrawdown(amount, useSeniorOnly);

        if (weightedApr > maxApr) revert RevvFiErrors.MaxAprExceeded();
        if (weightedApr > MAX_APR_BPS) revert RevvFiErrors.MaxAprExceeded();
        if (filledOffers.length == 0) revert RevvFiErrors.NoOffersAvailable();

        // Clean up dust positions before adding new ones
        sweepDustPositions();

        // Validate position count limit
        if (activePositionIds.length + filledOffers.length > MAX_ACTIVE_POSITIONS) {
            revert RevvFiErrors.TooManyActivePositions();
        }

        currentCycleBorrowedAmount += amount;

        uint256[] memory positionIds = new uint256[](filledOffers.length);

        // Create positions for each offer
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

        // Transfer borrowed funds to borrower
        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransfer(borrower, amount);

        // Update reputation if registry is set
        if (address(reputationRegistry) != address(0)) {
            reputationRegistry.recordBorrowActivity(borrower, amount);
        }

        emit RevvFiEvents.Borrow(borrower, amount, weightedApr);
        emit RevvFiEvents.DrawdownExecuted(amount, weightedApr, positionIds);
    }

    /**
     * @dev Repays a portion of the outstanding debt
     * @param amount Amount to repay (will cap at total debt)
     */
    function repay(uint256 amount) external onlyBorrower nonReentrant initializedCheck accrueInterest {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();
        if (amount > totalOwed) amount = totalOwed;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        _distributeRepayment(amount);

        // Check if any remaining debt exists
        bool hasRemainingDebt = false;
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            if (
                positionActive[posId]
                    && (positionPrincipal[posId] > DUST_THRESHOLD || positionAccruedInterest[posId] > 0)
            ) {
                hasRemainingDebt = true;
                break;
            }
        }

        // Track successful repayment cycle for reputation if no debt remains
        if (!hasRemainingDebt && address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, amount, 0, amount);
    }

    /**
     * @dev Distributes repayment amounts to positions (interest first, then principal)
     * @param repaymentAmount Total amount being repaid
     */
    function _distributeRepayment(uint256 repaymentAmount) internal {
        if (totalPrincipal == 0 && totalAccruedInterest == 0) return;

        uint256 remainingRepayment = repaymentAmount;
        uint256 originalTotalInterest = totalAccruedInterest;
        uint256 originalTotalPrincipal = totalPrincipal;
        uint256[] memory positions = activePositionIds;
        uint256 interestPaid = 0;
        uint256 principalPaid = 0;

        // Distribute interest first
        if (originalTotalInterest > 0 && remainingRepayment > 0) {
            uint256 interestPayment =
                remainingRepayment < originalTotalInterest ? remainingRepayment : originalTotalInterest;
            uint256 lastPositionWithInterest = 0;
            uint256 positionsWithInterestCount = 0;

            // Count positions with interest for proper rounding
            for (uint256 i = 0; i < positions.length; i++) {
                if (positionActive[positions[i]] && positionAccruedInterest[positions[i]] > 0) {
                    lastPositionWithInterest = positions[i];
                    positionsWithInterestCount++;
                }
            }

            uint256 interestDistributed = 0;
            uint256 positionCounter = 0;

            for (uint256 i = 0; i < positions.length; i++) {
                uint256 posId = positions[i];
                if (!positionActive[posId]) continue;

                uint256 positionInterest = positionAccruedInterest[posId];
                if (positionInterest == 0) continue;

                uint256 share;
                positionCounter++;

                // FIXED: Last position receives remainder to handle rounding
                if (positionCounter == positionsWithInterestCount) {
                    share = interestPayment - interestDistributed;
                } else {
                    share = (interestPayment * positionInterest) / originalTotalInterest;
                    if (share > positionInterest) share = positionInterest;
                    if (share == 0) continue;
                }

                positionClaimableAmount[posId] += share;
                positionAccruedInterest[posId] -= share;
                interestPaid += share;
                interestDistributed += share;
                remainingRepayment -= share;
            }
        }

        // Distribute principal second
        if (originalTotalPrincipal > 0 && remainingRepayment > 0) {
            uint256 principalPayment =
                remainingRepayment < originalTotalPrincipal ? remainingRepayment : originalTotalPrincipal;
            uint256 lastPositionWithPrincipal = 0;
            uint256 positionsWithPrincipalCount = 0;

            // Count positions with principal for proper rounding
            for (uint256 i = 0; i < positions.length; i++) {
                if (positionActive[positions[i]] && positionPrincipal[positions[i]] > 0) {
                    lastPositionWithPrincipal = positions[i];
                    positionsWithPrincipalCount++;
                }
            }

            uint256 principalDistributed = 0;
            uint256 positionCounter = 0;

            for (uint256 i = 0; i < positions.length; i++) {
                uint256 posId = positions[i];
                if (!positionActive[posId]) continue;

                uint256 principal = positionPrincipal[posId];
                if (principal == 0) continue;

                uint256 share;
                positionCounter++;

                // FIXED: Last position receives remainder to handle rounding
                if (positionCounter == positionsWithPrincipalCount) {
                    share = principalPayment - principalDistributed;
                } else {
                    share = (principalPayment * principal) / originalTotalPrincipal;
                    if (share > principal) share = principal;
                    if (share == 0) continue;
                }

                positionClaimableAmount[posId] += share;
                positionPrincipal[posId] -= share;
                principalPaid += share;
                principalDistributed += share;
                remainingRepayment -= share;
            }
        }

        // FIXED: Update totals incrementally
        totalAccruedInterest -= interestPaid;
        totalPrincipal -= principalPaid;

        // OPTIMIZED: Only recalculate weighted APR if principal changed
        // This is still O(N) but happens less frequently than accrueInterest
        if (principalPaid > 0) {
            _recalculateWeightedAPR();
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
                totalPrincipal -= positionPrincipal[posId];
                positionPrincipal[posId] = 0;
            }
            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }
    }

    /**
     * @dev Repays entire outstanding debt and settles all positions
     */
    function repayFull() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        uint256 totalOwed = getTotalOwed();
        if (totalOwed == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalOwed);

        uint256[] memory positionsToSettle = activePositionIds;

        // Settle all active positions
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

        // Update reputation for successful full repayment
        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, repaidAmount, 0, repaidAmount);
    }

    /**
     * @dev Claims claimable funds from a position (works even after position is settled)
     * @param positionId ID of the position to claim from
     */
    function claimFunds(uint256 positionId) external nonReentrant initializedCheck {
        uint256 claimable = positionClaimableAmount[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        // Determine claimant (original owner for settled positions)
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

    /**
     * @dev Internal function to mark a position as settled and burn NFT
     * @param positionId ID of the position to settle
     */
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

    /**
     * @dev Submits a lending offer to the offer book
     * @param amount Amount to lend
     * @param apr APR in basis points
     * @param seniority Seniority level (0=senior, 1=junior)
     * @param duration Duration of the offer in seconds
     */
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

    /**
     * @dev Cancels an existing lending offer
     * @param offerId ID of the offer to cancel
     */
    function cancelOffer(uint256 offerId) external nonReentrant initializedCheck {
        offerBook.cancelOffer(offerId);
    }

    /**
     * @dev Starts liquidation process if market is liquidatable
     */
    function startLiquidation() public initializedCheck accrueInterest {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = totalPrincipal + totalAccruedInterest;
        uint256 collateral = collateralEscrow.getCollateralBalance(borrower);

        collateralEscrow.startLiquidation();
        isLiquidating = true;

        // Approve and transfer collateral to liquidator
        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.forceApprove(address(liquidator), collateral);
        collateralEscrow.liquidate(borrower, collateral, debt, address(liquidator));

        // Create auction in liquidator contract
        liquidationAuctionId =
            liquidator.createAuction(address(this), borrower, borrowAsset, collateralAsset, collateral, debt);
        liquidator.receiveCollateral(liquidationAuctionId);

        emit RevvFiEvents.LiquidationStartedMarket(borrower);
    }

    /**
     * @dev Ends liquidation process (called by factory after auction completes)
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
     * @dev Settles liquidation after auction, distributing repaid debt and losses
     * @param debtRepaid Amount of debt repaid from auction
     * @param lossAmount Total loss amount to distribute
     */
    function settleLiquidation(uint256 debtRepaid, uint256 lossAmount) external {
        if (msg.sender != address(liquidator)) revert RevvFiErrors.UnauthorizedCaller();
        if (!isLiquidating) revert RevvFiErrors.NotLiquidatingMarket();

        uint256 originalDebt = totalPrincipal + totalAccruedInterest;

        // Record loss if debt was not fully repaid
        if (debtRepaid < originalDebt) {
            uint256 loss = originalDebt - debtRepaid;
            badDebt += loss;
            totalRealizedLoss += loss;
            _distributeLoss(loss);
        }

        // Distribute any repaid amount
        if (debtRepaid > 0) {
            _distributeRepayment(debtRepaid);
        }

        // Update reputation for default
        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordDefault(borrower, currentCycleBorrowedAmount, debtRepaid);
            currentCycleBorrowedAmount = 0;
        }

        isLiquidating = false;
        collateralEscrow.endLiquidation();

        emit RevvFiEvents.LiquidationEndedMarket(borrower);
    }

    /**
     * @dev External function to trigger liquidation if market is liquidatable
     */
    function liquidate() external initializedCheck {
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        startLiquidation();
    }

    /**
     * @dev Distributes losses proportionally to positions (junior first, then senior)
     * @param lossAmount Total loss amount to distribute
     */
    function _distributeLoss(uint256 lossAmount) internal {
        uint256 remainingLoss = lossAmount;
        uint256[] memory positions = activePositionIds;
        uint256 totalInterestLoss = 0;
        uint256 totalPrincipalLoss = 0;

        // Junior positions first (seniority == 1) - they absorb losses first
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 1) continue;

            uint256 positionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            if (positionValue >= remainingLoss) {
                uint256 reduction = remainingLoss;

                // Apply loss to interest first, then principal
                if (positionAccruedInterest[posId] >= reduction) {
                    positionAccruedInterest[posId] -= reduction;
                    totalInterestLoss += reduction;
                } else {
                    totalInterestLoss += positionAccruedInterest[posId];
                    reduction -= positionAccruedInterest[posId];
                    positionAccruedInterest[posId] = 0;
                    if (positionPrincipal[posId] > reduction) {
                        positionPrincipal[posId] -= reduction;
                        totalPrincipalLoss += reduction;
                    } else {
                        totalPrincipalLoss += positionPrincipal[posId];
                        positionPrincipal[posId] = 0;
                    }
                }
                remainingLoss = 0;
            } else {
                remainingLoss -= positionValue;
                totalInterestLoss += positionAccruedInterest[posId];
                totalPrincipalLoss += positionPrincipal[posId];
                positionPrincipal[posId] = 0;
                positionAccruedInterest[posId] = 0;
            }

            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }

        // Senior positions (seniority == 0) - absorb remaining losses
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 0) continue;

            uint256 positionValue = positionPrincipal[posId] + positionAccruedInterest[posId];
            if (positionValue >= remainingLoss) {
                uint256 reduction = remainingLoss;

                // Apply loss to interest first, then principal
                if (positionAccruedInterest[posId] >= reduction) {
                    positionAccruedInterest[posId] -= reduction;
                    totalInterestLoss += reduction;
                } else {
                    totalInterestLoss += positionAccruedInterest[posId];
                    reduction -= positionAccruedInterest[posId];
                    positionAccruedInterest[posId] = 0;
                    if (positionPrincipal[posId] > reduction) {
                        positionPrincipal[posId] -= reduction;
                        totalPrincipalLoss += reduction;
                    } else {
                        totalPrincipalLoss += positionPrincipal[posId];
                        positionPrincipal[posId] = 0;
                    }
                }
                remainingLoss = 0;
            } else {
                remainingLoss -= positionValue;
                totalInterestLoss += positionAccruedInterest[posId];
                totalPrincipalLoss += positionPrincipal[posId];
                positionPrincipal[posId] = 0;
                positionAccruedInterest[posId] = 0;
            }

            if (positionPrincipal[posId] == 0 && positionAccruedInterest[posId] == 0) {
                _settlePosition(posId);
            }
        }

        // FIXED: Update totals accurately based on actual interest and principal losses
        totalAccruedInterest -= totalInterestLoss;
        totalPrincipal -= totalPrincipalLoss;

        // Recalculate weighted APR if principal changed
        if (totalPrincipalLoss > 0) {
            _recalculateWeightedAPR();
        }
    }

    /**
     * @dev Pauses market operations
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
     * @dev Sets a new guardian address
     * @param newGuardian New guardian address
     */
    function setGuardian(address newGuardian) external onlyFactory {
        if (newGuardian == address(0)) revert RevvFiErrors.ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit RevvFiEvents.GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @dev Closes market if no outstanding debt
     */
    function closeMarket() external onlyBorrower nonReentrant initializedCheck accrueInterest {
        if (totalPrincipal > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
    }

    /**
     * @dev Returns total assets held by this contract
     * @return Balance of borrow asset
     */
    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    /**
     * @dev Returns total outstanding debt (principal + accrued interest)
     * @return Total debt amount
     */
    function getTotalOwed() public view returns (uint256) {
        // OPTIMIZED: TRUE O(1) IMPLEMENTATION
        // No longer loops through positions - simply returns maintained totals
        // We maintain totalPrincipal and totalAccruedInterest incrementally
        // This eliminates redundant calculations and consistency risks
        return totalPrincipal + totalAccruedInterest;
    }

    /**
     * @dev Returns current collateral ratio
     * @return Collateral ratio in basis points
     */
    function getCollateralRatio() public view returns (uint256) {
        return collateralEscrow.getCollateralRatio(borrower, getTotalOwed());
    }

    /**
     * @dev Checks if market is healthy (above liquidation threshold)
     * @return True if position is healthy
     */
    function isHealthy() public view returns (bool) {
        return collateralEscrow.isHealthy(borrower, getTotalOwed());
    }

    /**
     * @dev Checks if market is liquidatable (below threshold)
     * @return True if market can be liquidated
     */
    function isLiquidatable() public view returns (bool) {
        return collateralEscrow.isLiquidatable(borrower, getTotalOwed());
    }

    /**
     * @dev Returns maximum additional borrowable amount
     * @return Additional amount that can be borrowed
     */
    function getMaxBorrowable() public view returns (uint256) {
        uint256 maxFromCollateral = collateralEscrow.getMaxBorrowable(borrower);
        if (maxFromCollateral <= getTotalOwed()) return 0;
        return maxFromCollateral - getTotalOwed();
    }

    /**
     * @dev Returns claimable amount for a position
     * @param positionId ID of the position
     * @return Claimable amount
     */
    function getPositionClaimable(uint256 positionId) public view returns (uint256) {
        return positionClaimableAmount[positionId];
    }

    /**
     * @dev Returns current value of a position (principal + accrued interest)
     * @param positionId ID of the position
     * @return Current value of the position
     */
    function getPositionValue(uint256 positionId) public view returns (uint256) {
        if (!positionActive[positionId]) return 0;
        return positionPrincipal[positionId] + positionAccruedInterest[positionId];
    }

    /**
     * @dev Returns count of active positions
     * @return Number of active positions
     */
    function getActivePositionsCount() public view returns (uint256) {
        return activePositionIds.length;
    }

    /**
     * @dev Returns paginated list of active position IDs
     * @param start Starting index
     * @param limit Maximum number of results
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

    /**
     * @dev Returns total outstanding debt (alias for getTotalOwed)
     * @return Total debt amount
     */
    function totalDebt() external view returns (uint256) {
        return getTotalOwed();
    }

    /**
     * @dev Returns current debt index (alias for getTotalOwed for compatibility)
     * @return Total debt amount
     */
    function getCurrentDebtIndex() external view returns (uint256) {
        return getTotalOwed();
    }
}
