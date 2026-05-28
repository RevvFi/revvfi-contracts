// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "./interfaces/IRevvFiArchController.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./interfaces/IRevvFiLiquidator.sol";
import "./interfaces/IReputationRegistry.sol";
import "./interfaces/IRevvFiMarket.sol";
import "./interfaces/IRevvFiCollateralEscrow.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./interfaces/IRevvFiLiquidityQueue.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiFactory
 * @author Preet Singh
 * @notice Factory contract for deploying and managing lending markets using EIP-1167 minimal proxies
 * @dev This contract serves as the deployment hub for the entire RevvFi protocol.
 *      It uses the clone pattern (EIP-1167) to deploy minimal proxy contracts for each market,
 *      significantly reducing deployment gas costs compared to deploying full contracts.
 *
 *      Key features:
 *      - Deploys per-market clones of Market, Escrow, OfferBook, and LiquidityQueue
 *      - Maintains protocol-wide singleton contracts (ArchController, PositionNFT, Liquidator, ReputationRegistry)
 *      - Validates deployment parameters against protocol guardrails
 *      - Handles fee collection for market deployments
 *      - Supports timelock-protected ArchController upgrades
 */
contract RevvFiFactory is Ownable, ReentrancyGuard {
    using Clones for address;

    // ============================================================
    //                    Core Protocol Contracts
    // ============================================================

    /// @dev Central registry for permissions and whitelists (set once by owner)
    IRevvFiArchController public archController;

    /// @dev NFT contract representing lender positions (set once by owner)
    IRevvFiPositionNFT public positionNFT;

    /// @dev Contract handling liquidation auctions (set once by owner)
    IRevvFiLiquidator public liquidator;

    /// @dev Contract tracking borrower reputation (set once by owner)
    IReputationRegistry public reputationRegistry;

    /// @dev Flag indicating whether core contracts have been set (prevents double initialization)
    bool public coreContractsSet;

    // ============================================================
    //                    Implementation Contracts
    // ============================================================

    /// @dev Implementation address for Market contracts (cloned per market)
    address public immutable marketImpl;

    /// @dev Implementation address for CollateralEscrow contracts (cloned per market)
    address public immutable escrowImpl;

    /// @dev Implementation address for OfferBook contracts (cloned per market)
    address public immutable offerBookImpl;

    /// @dev Implementation address for LiquidityQueue contracts (cloned per market)
    address public immutable liquidityQueueImpl;

    // ============================================================
    //                    Configuration
    // ============================================================

    /// @dev Fee charged for deploying a new market (in wei/ETH)
    uint256 public deploymentFee;

    /// @dev Address that receives deployment fees
    address public feeRecipient;

    /// @dev Pending ArchController address for timelock-protected update
    address public pendingArchController;

    /// @dev Timestamp when the pending ArchController update can be executed
    uint256 public archControllerUpdateTimelock;

    // ============================================================
    //                    Protocol Guardrails
    // ============================================================

    /// @dev Timelock duration for ArchController updates (2 days)
    uint256 private constant TIMELOCK = 2 days;

    /// @dev Minimum allowed collateral ratio (110%) - prevents undercollateralized positions
    uint256 private constant MIN_CR = 11000;

    /// @dev Maximum allowed collateral ratio (500%) - prevents over-collateralization abuse
    uint256 private constant MAX_CR = 50000;

    /// @dev Minimum buffer between collateral ratio and liquidation threshold (5%)
    uint256 private constant LIQ_BUFFER = 500;

    // ============================================================
    //                    Events
    // ============================================================

    event CoreContractsSet(address archController, address positionNFT, address liquidator, address reputationRegistry);
    event ImplementationsSet(address market, address escrow, address offerBook, address liquidityQueue);

    /**
     * @dev Initializes the factory with implementation addresses and configuration
     * @param _feeRecipient Address that receives deployment fees
     * @param _deploymentFee Fee charged per market deployment (in wei)
     * @param _marketImpl Implementation address for Market contracts
     * @param _escrowImpl Implementation address for CollateralEscrow contracts
     * @param _offerBookImpl Implementation address for OfferBook contracts
     * @param _liquidityQueueImpl Implementation address for LiquidityQueue contracts
     * @notice Core contracts are NOT set in constructor to avoid circular dependencies.
     *         They must be set later via setCoreContracts() after deployment.
     */
    constructor(
        address _feeRecipient,
        uint256 _deploymentFee,
        address _marketImpl,
        address _escrowImpl,
        address _offerBookImpl,
        address _liquidityQueueImpl
    ) Ownable(msg.sender) {
        if (
            _feeRecipient == address(0) || _marketImpl == address(0) || _escrowImpl == address(0)
                || _offerBookImpl == address(0) || _liquidityQueueImpl == address(0)
        ) {
            revert RevvFiErrors.ZeroAddress();
        }

        feeRecipient = _feeRecipient;
        deploymentFee = _deploymentFee;

        marketImpl = _marketImpl;
        escrowImpl = _escrowImpl;
        offerBookImpl = _offerBookImpl;
        liquidityQueueImpl = _liquidityQueueImpl;

        emit ImplementationsSet(marketImpl, escrowImpl, offerBookImpl, liquidityQueueImpl);
    }

    /**
     * @dev Sets the core protocol contracts (only callable once by owner)
     * @param _archController Address of the ArchController contract
     * @param _positionNFT Address of the PositionNFT contract
     * @param _liquidator Address of the Liquidator contract
     * @param _reputationRegistry Address of the ReputationRegistry contract
     * @notice This resolves the circular dependency between factory and core contracts.
     *         Core contracts are deployed with the factory address, then registered here.
     */
    function setCoreContracts(
        address _archController,
        address _positionNFT,
        address _liquidator,
        address _reputationRegistry
    ) external onlyOwner {
        if (coreContractsSet) revert RevvFiErrors.AlreadyInitialized();
        if (
            _archController == address(0) || _positionNFT == address(0) || _liquidator == address(0)
                || _reputationRegistry == address(0)
        ) {
            revert RevvFiErrors.ZeroAddress();
        }

        archController = IRevvFiArchController(_archController);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);
        reputationRegistry = IReputationRegistry(_reputationRegistry);
        coreContractsSet = true;

        emit CoreContractsSet(_archController, _positionNFT, _liquidator, _reputationRegistry);
    }

    /**
     * @dev Validates that collateral ratio and liquidation threshold meet protocol requirements
     * @param minCR Minimum collateral ratio in basis points
     * @param liqThreshold Liquidation threshold in basis points
     * @dev Requirements:
     *      - minCR between 110% and 500%
     *      - liqThreshold at least 5% below minCR
     *      - liqThreshold between 1% and 99%
     */
    function _validateRatios(uint256 minCR, uint256 liqThreshold) internal pure {
        if (minCR < MIN_CR) revert RevvFiErrors.CollateralBelowMinimum();
        if (minCR > MAX_CR) revert RevvFiErrors.CollateralAboveMaximum();
        if (liqThreshold >= minCR - LIQ_BUFFER) revert RevvFiErrors.LiquidationThresholdTooHigh();
        if (liqThreshold < 100 || liqThreshold >= 10000) revert RevvFiErrors.InvalidLiquidationThreshold();
    }

    /**
     * @dev Deploys a complete lending market with all associated components
     * @param borrower Address that will control the market (must be registered in ArchController)
     * @param borrowAsset Token that lenders will provide (e.g., USDC)
     * @param collateralAsset Token that borrowers will lock (e.g., WETH)
     * @param collateralOracle Chainlink oracle address for collateral pricing
     * @param collateralDecimals Decimals of collateral token
     * @param borrowDecimals Decimals of borrow token
     * @param minCollateralRatio Minimum required collateral ratio in basis points
     * @param liquidationThreshold Threshold for liquidation in basis points
     * @return marketAddress Address of the newly deployed market
     * @notice Requires payment of deploymentFee in ETH
     * @dev Deployment flow:
     *      1. Validate all parameters and permissions
     *      2. Clone all four implementation contracts
     *      3. Initialize and configure each component
     *      4. Register the market with all protocol systems
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
        if (!coreContractsSet) revert RevvFiErrors.UnauthorizedCaller();
        if (msg.value != deploymentFee) revert RevvFiErrors.InsufficientFee();
        if (!archController.isRegisteredBorrower(borrower)) revert RevvFiErrors.BorrowerNotRegistered();
        if (borrowAsset == collateralAsset) revert RevvFiErrors.SameAssetNotAllowed();
        if (
            archController.isBlacklistedAsset(borrowAsset) || archController.isBlacklistedAsset(collateralAsset)
                || archController.isBlacklistedAsset(collateralOracle)
        ) revert RevvFiErrors.AssetBlacklisted();

        _validateRatios(minCollateralRatio, liquidationThreshold);

        // Transfer deployment fee to fee recipient
        (bool feeSent,) = feeRecipient.call{value: deploymentFee}("");
        if (!feeSent) revert RevvFiErrors.FeeTransferFailed();

        // Register borrower in reputation system
        reputationRegistry.registerBorrower(borrower);

        // Deploy clones (EIP-1167 minimal proxies - ~100 bytes each!)
        marketAddress = marketImpl.clone();
        address escrowAddr = escrowImpl.clone();
        address offerBookAddr = offerBookImpl.clone();
        address liquidityQueueAddr = liquidityQueueImpl.clone();

        // Register market in PositionNFT BEFORE initialization (critical for permissions)
        positionNFT.registerMarket(marketAddress);

        // Initialize Market
        IRevvFiMarket(marketAddress)
            .initialize(address(this), address(archController), borrower, borrowAsset, collateralAsset);

        // Initialize and configure CollateralEscrow
        IRevvFiCollateralEscrow(escrowAddr)
            .initialize(
                address(this),
                marketAddress,
                borrower,
                borrowAsset,
                collateralAsset,
                collateralOracle,
                collateralDecimals,
                borrowDecimals
            );
        IRevvFiCollateralEscrow(escrowAddr).setMinCollateralRatio(minCollateralRatio);
        IRevvFiCollateralEscrow(escrowAddr).setLiquidationThreshold(liquidationThreshold);

        // Initialize OfferBook
        IRevvFiOfferBook(offerBookAddr).initialize(address(this), marketAddress, borrowAsset);

        // Initialize LiquidityQueue
        IRevvFiLiquidityQueue(liquidityQueueAddr).initialize(address(this), marketAddress, address(positionNFT));

        // Connect all components to the Market
        IRevvFiMarket(marketAddress)
            .setContracts(
                escrowAddr, offerBookAddr, address(positionNFT), address(liquidator), address(reputationRegistry)
            );

        // Register market with all protocol systems
        reputationRegistry.registerMarket(marketAddress);
        liquidator.registerMarket(marketAddress);
        archController.registerMarket(marketAddress);

        emit RevvFiEvents.MarketDeployed(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, block.timestamp
        );
    }

    /**
     * @dev Registers the factory with ArchController as both controller and controller factory
     * @notice Only callable by owner after core contracts are set
     * @dev This grants the factory permission to register markets and deploy controllers
     */
    function registerWithArchController() external onlyOwner {
        if (!coreContractsSet) revert RevvFiErrors.UnauthorizedCaller();
        archController.registerControllerFactory(address(this));
        archController.registerController(address(this));
    }

    /**
     * @dev Updates the deployment fee amount
     * @param newFee New fee amount in ETH (wei)
     * @notice Only callable by owner
     */
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        emit RevvFiEvents.FeeUpdated(deploymentFee, newFee);
        deploymentFee = newFee;
    }

    /**
     * @dev Updates the fee recipient address
     * @param newRecipient New address to receive deployment fees
     * @notice Only callable by owner
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert RevvFiErrors.ZeroAddress();
        feeRecipient = newRecipient;
    }

    /**
     * @dev Requests an ArchController update with timelock protection
     * @param newArchController Address of the new ArchController
     * @notice Only callable by owner
     * @dev Updates are timelocked for TIMELOCK duration to allow for governance review
     */
    function requestArchControllerUpdate(address newArchController) external onlyOwner {
        if (newArchController == address(0)) revert RevvFiErrors.ZeroAddress();
        pendingArchController = newArchController;
        archControllerUpdateTimelock = block.timestamp + TIMELOCK;
        emit RevvFiEvents.ArchControllerUpdateRequested(newArchController);
    }

    /**
     * @dev Executes a pending ArchController update after timelock expires
     * @notice Only callable by owner
     * @dev Reverts if timelock hasn't expired or no update is pending
     */
    function executeArchControllerUpdate() external onlyOwner {
        if (pendingArchController == address(0)) revert RevvFiErrors.PendingArchControllerNotSet();
        if (block.timestamp < archControllerUpdateTimelock) revert RevvFiErrors.UnauthorizedCaller();

        address oldArch = address(archController);
        archController = IRevvFiArchController(pendingArchController);
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;

        emit RevvFiEvents.ArchControllerUpdated(oldArch, address(archController));
    }

    /**
     * @dev Cancels a pending ArchController update
     * @notice Only callable by owner
     */
    function cancelArchControllerUpdate() external onlyOwner {
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
    }
}
