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
import "./libraries/RevvFiDebtAccounting.sol";

// Protocol-wide constants
uint256 constant SECONDS_PER_YEAR = 365 days; // Seconds in a year for interest calculations
uint256 constant DUST_THRESHOLD = 1e6; // Minimum debt threshold for cleanup (1e6 wei)
uint256 constant FORCED_CLEANUP_THRESHOLD = 1e3; // Threshold for forced market closure (1e3 wei)

/**
 * @title RevvFiMarket
 * @author Preet Singh
 * @notice Core lending market contract managing borrowing, lending, and position tracking
 * @dev Handles borrow/repay operations, interest accrual, APR tracking, and liquidation coordination
 */
contract RevvFiMarket is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Core market addresses
    address public factory; // Factory contract that created this market
    address public archController; // Architecture controller for protocol permissions
    address public borrower; // Address authorized to borrow from this market
    address public borrowAsset; // Asset token that is borrowed (e.g., USDC)
    address public collateralAsset; // Asset token used as collateral

    // Protocol constants
    uint256 public constant MAX_APR_BPS = 5000; // Maximum APR in basis points (50%)
    uint256 public constant BASIS_POINTS = 10000; // Basis points denominator (100%)
    uint256 public constant MAX_ACTIVE_POSITIONS = 100; // Maximum active positions per drawdown

    // External contract references
    IRevvFiCollateralEscrow public collateralEscrow; // Manages collateral deposits/withdrawals
    IRevvFiOfferBook public offerBook; // Manages lender offers for borrowing
    IRevvFiPositionNFT public positionNFT; // NFT representing lender positions
    IRevvFiLiquidator public liquidator; // Handles liquidation auctions
    IReputationRegistry public reputationRegistry; // Tracks borrower reputation

    // Position-specific state
    mapping(uint256 => uint256) public positionPrincipal; // Position ID => actual owed principal
    mapping(uint256 => uint256) public positionLastAccrualTime; // Position ID => last time interest was rolled into principal
    mapping(uint256 => uint256) public positionApr; // Position ID => APR in basis points
    mapping(uint256 => uint8) public positionSeniority; // Position ID => Seniority (0=senior, 1=junior)
    mapping(uint256 => bool) public positionActive; // Position ID => Active status
    mapping(uint256 => bool) public positionSettled; // Position ID => Settled status
    mapping(uint256 => uint256) public positionClaimableAmount; // Position ID => Claimable amount
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
     * @dev Calculates a position's current debt (principal + interest accrued
     *      at ITS OWN apr since its last accrual checkpoint). No shared index -
     *      each position is fully independent of every other position in the market.
     * @param positionId ID of the position to query
     * @return Current debt amount including accrued interest
     */
    function _getPositionDebt(uint256 positionId) internal view returns (uint256) {
        if (!positionActive[positionId] || positionPrincipal[positionId] == 0) return 0;
        uint256 principal = positionPrincipal[positionId];
        uint256 elapsed = block.timestamp - positionLastAccrualTime[positionId];
        return principal + RevvFiDebtAccounting.calculateInterest(principal, positionApr[positionId], elapsed);
    }

    /**
     * @dev Returns total outstanding debt including accrued interest, summed
     *      across all active positions (each accruing at its own apr).
     *      Bounded by MAX_ACTIVE_POSITIONS, same O(n) pattern already used by
     *      _distributeRepayment/_distributeLoss.
     * @return Total debt across all active positions
     */
    function getTotalOwed() public view returns (uint256) {
        uint256 total = 0;
        uint256 len = activePositionIds.length;
        for (uint256 i = 0; i < len; i++) {
            total += _getPositionDebt(activePositionIds[i]);
        }
        return total;
    }

    /**
     * @dev Returns current principal without interest, summed across all active positions
     * @return Current principal amount
     */
    function getCurrentPrincipal() public view returns (uint256) {
        uint256 total = 0;
        uint256 len = activePositionIds.length;
        for (uint256 i = 0; i < len; i++) {
            total += positionPrincipal[activePositionIds[i]];
        }
        return total;
    }

    // ============================================================
    // POSITION MANAGEMENT - SEPARATED CONCERNS
    // ============================================================

    /**
     * @dev Adds a position to the active positions array
     * @param positionId ID of the position to add
     */
    function _addActivePosition(uint256 positionId) internal {
        activePositionIndex[positionId] = activePositionIds.length;
        activePositionIds.push(positionId);
        positionActive[positionId] = true;
    }

    /**
     * @dev Removes a position from active array (APR logic handled separately)
     * @param positionId ID of the position to remove
     */
    function _removeActivePosition(uint256 positionId) internal {
        uint256 index = activePositionIndex[positionId];
        uint256 lastId = activePositionIds[activePositionIds.length - 1];

        // Swap with last element and pop for O(1) removal
        activePositionIds[index] = lastId;
        activePositionIndex[lastId] = index;
        activePositionIds.pop();

        delete activePositionIndex[positionId];
        positionActive[positionId] = false;
    }

    /**
     * @dev Removes a position and zeroes its principal
     * @param positionId ID of the position to remove
     */
    function _removePosition(uint256 positionId) internal {
        // Zero first to prevent any reentrancy-like state confusion
        positionPrincipal[positionId] = 0;
        _removeActivePosition(positionId);
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
    {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        collateralEscrow.withdrawCollateral(borrower, amount, getTotalOwed());
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
            positionLastAccrualTime[tokenId] = block.timestamp;
            positionApr[tokenId] = filledOffers[i].apr;
            positionSeniority[tokenId] = filledOffers[i].seniority;
            positionSettled[tokenId] = false;
            positionClaimableAmount[tokenId] = 0;

            _addActivePosition(tokenId);
        }

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
    function repay(uint256 amount) external onlyBorrower nonReentrant initializedCheck {
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        uint256 totalDebt = getTotalOwed();
        if (totalDebt == 0) revert RevvFiErrors.ZeroAmount();
        if (amount > totalDebt) amount = totalDebt;

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), amount);

        (uint256 interestPaid, uint256 principalPaid) = _distributeRepayment(amount);

        // Track successful repayment cycle for reputation
        if (activePositionIds.length == 0) {
            if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
                reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
                currentCycleBorrowedAmount = 0;
            }
        }

        emit RevvFiEvents.Repay(borrower, amount, interestPaid, principalPaid);
    }

    /**
     * @dev Distributes repayment amounts proportionally to active positions'
     *      debt shares. Each position's own debt is computed via its own apr
     *      (_getPositionDebt) - no shared index - so the allocation itself is
     *      the same proportional-by-debt-share scheme as before, but what
     *      "debt" means per position is now independent of every other one.
     * @param repaymentAmount Total amount being repaid
     * @return totalInterestPaid Sum of the interest portion across all positions touched
     * @return totalPrincipalPaid Sum of the principal portion across all positions touched
     */
    function _distributeRepayment(uint256 repaymentAmount)
        internal
        returns (uint256 totalInterestPaid, uint256 totalPrincipalPaid)
    {
        uint256[] memory positions = activePositionIds;
        uint256 len = positions.length;

        uint256[] memory debts = new uint256[](len);
        uint256[] memory interests = new uint256[](len);
        uint256 totalDebtBefore = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId] || positionPrincipal[posId] == 0) continue;

            uint256 principal = positionPrincipal[posId];
            uint256 elapsed = block.timestamp - positionLastAccrualTime[posId];
            uint256 interest = RevvFiDebtAccounting.calculateInterest(principal, positionApr[posId], elapsed);

            debts[i] = principal + interest;
            interests[i] = interest;
            totalDebtBefore += debts[i];
        }

        if (totalDebtBefore == 0) return (0, 0);

        uint256 remainingRepayment = repaymentAmount;

        // Distribute repayment proportionally to each position's own debt share
        for (uint256 i = 0; i < len && remainingRepayment > 0; i++) {
            uint256 posId = positions[i];
            uint256 positionDebt = debts[i];
            if (positionDebt == 0) continue;

            uint256 share = (repaymentAmount * positionDebt) / totalDebtBefore;
            if (share > remainingRepayment) share = remainingRepayment;
            if (share == 0) continue;

            uint256 interestShare = share >= positionDebt ? interests[i] : (share * interests[i]) / positionDebt;
            uint256 principalShare = share - interestShare;
            totalInterestPaid += interestShare;
            totalPrincipalPaid += principalShare;

            positionClaimableAmount[posId] += share;

            positionPrincipal[posId] = positionDebt - share;
            positionLastAccrualTime[posId] = block.timestamp;

            emit RevvFiEvents.LenderRepaid(positionNFT.ownerOf(posId), posId, positionPrincipal[posId], share);

            remainingRepayment -= share;
        }

        // Clean up dust positions (negligible remaining debt)
        for (uint256 i = 0; i < len; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            uint256 currentDebt = _getPositionDebt(posId);

            if (positionPrincipal[posId] > 0 && currentDebt < DUST_THRESHOLD) {
                if (settledPositionOwner[posId] == address(0)) {
                    settledPositionOwner[posId] = positionNFT.ownerOf(posId);
                }
                positionClaimableAmount[posId] += currentDebt;
                _removePosition(posId);
                _settlePosition(posId);
            } else if (positionPrincipal[posId] == 0) {
                _removePosition(posId);
                _settlePosition(posId);
            }
        }
    }

    /**
     * @dev Repays entire outstanding debt and settles all positions
     */
    function repayFull() external onlyBorrower nonReentrant initializedCheck {
        uint256 totalDebt = getTotalOwed();
        if (totalDebt == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 borrowToken = IERC20(borrowAsset);
        borrowToken.safeTransferFrom(borrower, address(this), totalDebt);

        uint256[] memory positionsToSettle = activePositionIds;
        uint256 totalInterestPaid = 0;
        uint256 totalPrincipalPaid = 0;

        // Settle all active positions, each at its own apr
        for (uint256 i = 0; i < positionsToSettle.length; i++) {
            uint256 posId = positionsToSettle[i];
            if (!positionActive[posId]) continue;

            uint256 principal = positionPrincipal[posId];
            uint256 elapsed = block.timestamp - positionLastAccrualTime[posId];
            uint256 interest = RevvFiDebtAccounting.calculateInterest(principal, positionApr[posId], elapsed);

            positionClaimableAmount[posId] += principal + interest;
            totalInterestPaid += interest;
            totalPrincipalPaid += principal;

            _removePosition(posId);
            _settlePosition(posId);
        }

        // Update reputation for successful full repayment
        if (address(reputationRegistry) != address(0) && currentCycleBorrowedAmount > 0) {
            reputationRegistry.recordSuccessfulRepayment(borrower, currentCycleBorrowedAmount);
            currentCycleBorrowedAmount = 0;
        }

        emit RevvFiEvents.Repay(borrower, totalDebt, totalInterestPaid, totalPrincipalPaid);
    }

    /**
     * @dev Claims claimable funds from a settled position
     * @param positionId ID of the position to claim from
     */
    function claimFunds(uint256 positionId) external nonReentrant initializedCheck {
        uint256 claimable = positionClaimableAmount[positionId];
        if (claimable == 0) revert RevvFiErrors.NoPrincipalToClaim();

        uint256 contractBalance = IERC20(borrowAsset).balanceOf(address(this));
        if (claimable > contractBalance) revert RevvFiErrors.InsufficientCollateral();

        // Determine claimant (original owner for settled positions)
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

        if (positionSettled[positionId]) {
            emit RevvFiEvents.PositionSettled(positionId, claimable, 0);
        } else {
            emit RevvFiEvents.PositionClaimed(positionId, msg.sender, claimable);
        }
    }

    /**
     * @dev Internal function to mark a position as settled and burn NFT
     * @param positionId ID of the position to settle
     */
    function _settlePosition(uint256 positionId) internal {
        // Only check if already settled, not if active
        if (positionSettled[positionId]) return;

        if (settledPositionOwner[positionId] == address(0)) {
            settledPositionOwner[positionId] = positionNFT.ownerOf(positionId);
        }

        positionSettled[positionId] = true;
        positionNFT.redeemPosition(positionId);
    }

    /**
     * @dev Starts liquidation process if market is liquidatable
     */
    function startLiquidation() public initializedCheck {
        if (isLiquidating) revert RevvFiErrors.AlreadyLiquidating();
        if (!isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

        uint256 debt = getTotalOwed();
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
        if (isLiquidatable()) revert RevvFiErrors.InsufficientCollateral();

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

        uint256 originalDebt = getTotalOwed();

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

        // Junior positions first (seniority == 1) - they absorb losses first
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 1) continue;

            uint256 positionDebt = _getPositionDebt(posId);
            if (positionDebt == 0) continue;

            if (positionDebt >= remainingLoss) {
                // Partial loss for this position - own-apr debt minus the loss,
                // resetting its own accrual clock to now.
                positionPrincipal[posId] = positionDebt - remainingLoss;
                positionLastAccrualTime[posId] = block.timestamp;
                remainingLoss = 0;
            } else {
                // Full loss for this position
                remainingLoss -= positionDebt;
                _removePosition(posId);
                _settlePosition(posId);
            }
        }

        // Senior positions (seniority == 0) - absorb remaining losses
        for (uint256 i = 0; i < positions.length && remainingLoss > 0; i++) {
            uint256 posId = positions[i];
            if (!positionActive[posId]) continue;
            if (positionSeniority[posId] != 0) continue;

            uint256 positionDebt = _getPositionDebt(posId);
            if (positionDebt == 0) continue;

            if (positionDebt >= remainingLoss) {
                // Partial loss for this position
                positionPrincipal[posId] = positionDebt - remainingLoss;
                positionLastAccrualTime[posId] = block.timestamp;
                remainingLoss = 0;
            } else {
                // Full loss for this position
                remainingLoss -= positionDebt;
                _removePosition(posId);
                _settlePosition(posId);
            }
        }
    }

    /**
     * @dev Forces market closure when debt is below cleanup threshold
     * @notice Only callable by borrower when debt is minimal
     */
    function forceCloseMarket() external onlyBorrower nonReentrant initializedCheck {
        require(getTotalOwed() < FORCED_CLEANUP_THRESHOLD, "Debt too high to force close");

        // Clean up dust positions
        uint256[] memory positions = activePositionIds;
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            if (positionActive[posId] && positionPrincipal[posId] > 0) {
                uint256 positionDebt = _getPositionDebt(posId);
                if (positionDebt < FORCED_CLEANUP_THRESHOLD) {
                    positionClaimableAmount[posId] += positionDebt;
                    _removePosition(posId);
                    _settlePosition(posId);
                }
            }
        }

        if (getTotalOwed() > 0) revert RevvFiErrors.InsufficientRepayment();
        if (activePositionIds.length > 0) revert RevvFiErrors.TooManyActivePositions();
        isClosed = true;
        emit RevvFiEvents.MarketClosedEvent(borrower, block.timestamp);
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
    function closeMarket() external onlyBorrower nonReentrant initializedCheck {
        if (getTotalOwed() > 0) revert RevvFiErrors.InsufficientRepayment();
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
        uint256 totalDebt = getTotalOwed();
        if (maxFromCollateral <= totalDebt) return 0;
        return maxFromCollateral - totalDebt;
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
     * @dev Returns current value of a position including accrued interest
     * @param positionId ID of the position
     * @return Current value of the position
     */
    function getPositionValue(uint256 positionId) public view returns (uint256) {
        return _getPositionDebt(positionId);
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
     * @dev Returns total outstanding debt
     * @return Total debt amount
     */
    function totalDebt() external view returns (uint256) {
        return getTotalOwed();
    }
}
