// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./RevvFiArchController.sol";
import "./RevvFiCollateralEscrow.sol";
import "./RevvFiOfferBook.sol";
import "./RevvFiPositionNFT.sol";
import "./RevvFiLiquidator.sol";
import "./RevvFiMarket.sol";
import "./RevvFiLiquidityQueue.sol";
import "./ReputationRegistry.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiFactory
 * @author Preet Singh
 * @notice Deploys and manages all lending markets and their associated components
 * @dev Creates a complete lending market with escrow, offer book, and liquidity queue
 */
contract RevvFiFactory is Ownable, ReentrancyGuard {
    /// @dev Central registry controlling permissions and listings
    RevvFiArchController public archController;

    /// @dev NFT contract representing lender positions
    RevvFiPositionNFT public positionNFT;

    /// @dev Contract that handles liquidations and auctions
    RevvFiLiquidator public liquidator;

    /// @dev Contract that tracks borrower reputation
    ReputationRegistry public reputationRegistry;

    /// @dev Fee charged for deploying a new market
    uint256 public deploymentFee;

    /// @dev Address that receives deployment fees
    address public feeRecipient;

    /// @dev Pending arch controller address for update (timelock protected)
    address public pendingArchController;

    /// @dev Timestamp when arch controller update can be executed
    uint256 public archControllerUpdateTimelock;

    /// @dev Required waiting period for arch controller updates
    uint256 public constant TIMELOCK_DURATION = 2 days;

    // ============================================================
    //                    Protocol Guardrails
    // ============================================================

    /// @notice Minimum allowed collateral ratio (110% for safety)
    uint256 public constant MIN_ALLOWED_COLLATERAL_RATIO = 11000;

    /// @notice Maximum allowed collateral ratio (500% to prevent over-collateralization abuse)
    uint256 public constant MAX_ALLOWED_COLLATERAL_RATIO = 50000;

    /// @notice Minimum allowed liquidation threshold (must be at least 5% below min collateral ratio)
    uint256 public constant MIN_LIQUIDATION_BUFFER = 500; // 5% buffer

    /**
     * @dev Sets up factory with arch controller and fee configuration
     * @param _archController Address of the arch controller contract
     * @param _feeRecipient Address that receives deployment fees
     * @param _deploymentFee Fee charged per market deployment
     */
    constructor(address _archController, address _feeRecipient, uint256 _deploymentFee) Ownable(msg.sender) {
        if (_archController == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert RevvFiErrors.ZeroAddress();

        archController = RevvFiArchController(_archController);
        feeRecipient = _feeRecipient;
        deploymentFee = _deploymentFee;

        positionNFT = new RevvFiPositionNFT(address(this));
        liquidator = new RevvFiLiquidator(address(this));
        reputationRegistry = new ReputationRegistry(address(this));
    }

    /**
     * @dev Validates collateral ratio and liquidation threshold against protocol guardrails
     * @param minCollateralRatio Minimum collateral ratio being proposed
     * @param liquidationThreshold Liquidation threshold being proposed
     */
    function _validateRatios(uint256 minCollateralRatio, uint256 liquidationThreshold) internal pure {
        // Check against global bounds
        if (minCollateralRatio < MIN_ALLOWED_COLLATERAL_RATIO) {
            revert RevvFiErrors.CollateralBelowMinimum();
        }
        if (minCollateralRatio > MAX_ALLOWED_COLLATERAL_RATIO) {
            revert RevvFiErrors.CollateralAboveMaximum();
        }

        // Liquidation threshold must be at least MIN_LIQUIDATION_BUFFER below minCollateralRatio
        // This prevents nearly unsecured lending (e.g., min=101%, liquidation=100%)
        if (liquidationThreshold >= minCollateralRatio - MIN_LIQUIDATION_BUFFER) {
            revert RevvFiErrors.LiquidationThresholdTooHigh();
        }

        // Basic sanity - liquidation threshold must be reasonable (between 1% and 99%)
        if (liquidationThreshold < 100 || liquidationThreshold >= 10000) {
            revert RevvFiErrors.InvalidLiquidationThreshold();
        }
    }

    /**
     * @dev Deploys a complete lending market with all components
     * @param borrower Address that will control the market
     * @param borrowAsset Token that lenders will provide
     * @param collateralAsset Token that borrowers will lock
     * @param collateralOracle Chainlink oracle for collateral pricing
     * @param collateralDecimals Decimals of collateral token
     * @param borrowDecimals Decimals of borrow token
     * @param minCollateralRatio Minimum required collateral ratio
     * @param liquidationThreshold Threshold for liquidation
     * @return marketAddress Address of the newly deployed market
     */
    function deployMarket(
        address borrower,
        address borrowAsset,
        address collateralAsset,
        address collateralOracle,
        uint8 collateralDecimals,
        uint8 borrowDecimals,
        uint256 minCollateralRatio,
        uint256 liquidationThreshold
    ) external payable nonReentrant returns (address marketAddress) {
        if (msg.value != deploymentFee) revert RevvFiErrors.InsufficientFee();
        if (!archController.isRegisteredBorrower(borrower)) revert RevvFiErrors.BorrowerNotRegistered();

        // Prevent borrowing and collateral being the same asset
        if (borrowAsset == collateralAsset) revert RevvFiErrors.SameAssetNotAllowed();

        // Validate assets are not blacklisted
        if (archController.isBlacklistedAsset(borrowAsset)) revert RevvFiErrors.AssetBlacklisted();
        if (archController.isBlacklistedAsset(collateralAsset)) revert RevvFiErrors.AssetBlacklisted();
        if (archController.isBlacklistedAsset(collateralOracle)) revert RevvFiErrors.OracleBlacklisted();

        // Validate ratios against protocol guardrails
        _validateRatios(minCollateralRatio, liquidationThreshold);

        (bool feeSent,) = feeRecipient.call{value: deploymentFee}("");
        if (!feeSent) revert RevvFiErrors.FeeTransferFailed();

        // Register borrower with reputation system
        reputationRegistry.registerBorrower(borrower);

        RevvFiMarket market =
            new RevvFiMarket(address(this), address(archController), borrower, borrowAsset, collateralAsset);

        marketAddress = address(market);

        // Create and configure collateral escrow
        RevvFiCollateralEscrow collateralEscrow = new RevvFiCollateralEscrow(address(this));
        collateralEscrow.initialize(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, collateralDecimals, borrowDecimals
        );
        collateralEscrow.setMinCollateralRatio(minCollateralRatio);
        collateralEscrow.setLiquidationThreshold(liquidationThreshold);

        // Create offer book for lending offers
        RevvFiOfferBook offerBook = new RevvFiOfferBook(address(this));
        offerBook.initialize(marketAddress, borrowAsset);

        // Create liquidity queue for withdrawal management
        RevvFiLiquidityQueue liquidityQueue =
            new RevvFiLiquidityQueue(marketAddress, address(this), address(positionNFT));

        // Connect all contracts to the market
        market.setContracts(
            address(collateralEscrow),
            address(offerBook),
            address(positionNFT),
            address(liquidator),
            address(reputationRegistry)
        );

        // Register market with all necessary systems
        // ArchController is the SINGLE SOURCE OF TRUTH for all markets
        reputationRegistry.registerMarket(marketAddress);
        liquidator.registerMarket(marketAddress);
        archController.registerMarket(marketAddress);

        emit RevvFiEvents.MarketDeployed(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, block.timestamp
        );
    }

    /**
     * @dev Registers the factory with the arch controller (owner only)
     */
    function registerWithArchController() external onlyOwner {
        archController.registerControllerFactory(address(this));
        archController.registerController(address(this));
    }

    /**
     * @dev Updates deployment fee (owner only)
     * @param newFee New fee amount in ETH
     */
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        emit RevvFiEvents.FeeUpdated(deploymentFee, newFee);
        deploymentFee = newFee;
    }

    /**
     * @dev Updates fee recipient address (owner only)
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert RevvFiErrors.ZeroAddress();
        feeRecipient = newRecipient;
    }

    /**
     * @dev Requests an arch controller update with timelock (owner only)
     * @param newArchController Address of new arch controller
     */
    function requestArchControllerUpdate(address newArchController) external onlyOwner {
        if (newArchController == address(0)) revert RevvFiErrors.ZeroAddress();
        pendingArchController = newArchController;
        archControllerUpdateTimelock = block.timestamp + TIMELOCK_DURATION;
        emit RevvFiEvents.ArchControllerUpdateRequested(newArchController);
    }

    /**
     * @dev Executes pending arch controller update after timelock (owner only)
     */
    function executeArchControllerUpdate() external onlyOwner {
        if (pendingArchController == address(0)) revert RevvFiErrors.PendingArchControllerNotSet();
        if (block.timestamp < archControllerUpdateTimelock) revert RevvFiErrors.UnauthorizedCaller();

        address oldArchController = address(archController);
        archController = RevvFiArchController(pendingArchController);

        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;

        emit RevvFiEvents.ArchControllerUpdated(oldArchController, address(archController));
    }

    /**
     * @dev Cancels pending arch controller update (owner only)
     */
    function cancelArchControllerUpdate() external onlyOwner {
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
    }
}
