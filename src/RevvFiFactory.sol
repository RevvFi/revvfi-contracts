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

contract RevvFiFactory is Ownable, ReentrancyGuard {
    using Clones for address;

    // Core contracts (mutable - can be set once by owner)
    IRevvFiArchController public archController;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;
    IReputationRegistry public reputationRegistry;
    bool public coreContractsSet;

    // Implementation addresses (immutable)
    address public immutable marketImpl;
    address public immutable escrowImpl;
    address public immutable offerBookImpl;
    address public immutable liquidityQueueImpl;

    // Configuration
    uint256 public deploymentFee;
    address public feeRecipient;
    address public pendingArchController;
    uint256 public archControllerUpdateTimelock;

    uint256 private constant TIMELOCK = 2 days;
    uint256 private constant MIN_CR = 11000;
    uint256 private constant MAX_CR = 50000;
    uint256 private constant LIQ_BUFFER = 500;

    event CoreContractsSet(address archController, address positionNFT, address liquidator, address reputationRegistry);
    event ImplementationsSet(address market, address escrow, address offerBook, address liquidityQueue);

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

    function _validateRatios(uint256 minCR, uint256 liqThreshold) internal pure {
        if (minCR < MIN_CR) revert RevvFiErrors.CollateralBelowMinimum();
        if (minCR > MAX_CR) revert RevvFiErrors.CollateralAboveMaximum();
        if (liqThreshold >= minCR - LIQ_BUFFER) revert RevvFiErrors.LiquidationThresholdTooHigh();
        if (liqThreshold < 100 || liqThreshold >= 10000) revert RevvFiErrors.InvalidLiquidationThreshold();
    }

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

        (bool feeSent,) = feeRecipient.call{value: deploymentFee}("");
        if (!feeSent) revert RevvFiErrors.FeeTransferFailed();

        reputationRegistry.registerBorrower(borrower);

        marketAddress = marketImpl.clone();
        address escrowAddr = escrowImpl.clone();
        address offerBookAddr = offerBookImpl.clone();
        address liquidityQueueAddr = liquidityQueueImpl.clone();

        // Register market in PositionNFT BEFORE initializing market
        positionNFT.registerMarket(marketAddress);

        IRevvFiMarket(marketAddress)
            .initialize(address(this), address(archController), borrower, borrowAsset, collateralAsset);

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

        IRevvFiOfferBook(offerBookAddr).initialize(address(this), marketAddress, borrowAsset);

        IRevvFiLiquidityQueue(liquidityQueueAddr).initialize(address(this), marketAddress, address(positionNFT));

        IRevvFiMarket(marketAddress)
            .setContracts(
                escrowAddr, offerBookAddr, address(positionNFT), address(liquidator), address(reputationRegistry)
            );

        reputationRegistry.registerMarket(marketAddress);
        liquidator.registerMarket(marketAddress);
        archController.registerMarket(marketAddress);

        emit RevvFiEvents.MarketDeployed(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, block.timestamp
        );
    }

    function registerWithArchController() external onlyOwner {
        if (!coreContractsSet) revert RevvFiErrors.UnauthorizedCaller();
        archController.registerControllerFactory(address(this));
        archController.registerController(address(this));
    }

    function setDeploymentFee(uint256 newFee) external onlyOwner {
        emit RevvFiEvents.FeeUpdated(deploymentFee, newFee);
        deploymentFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert RevvFiErrors.ZeroAddress();
        feeRecipient = newRecipient;
    }

    function requestArchControllerUpdate(address newArchController) external onlyOwner {
        if (newArchController == address(0)) revert RevvFiErrors.ZeroAddress();
        pendingArchController = newArchController;
        archControllerUpdateTimelock = block.timestamp + TIMELOCK;
        emit RevvFiEvents.ArchControllerUpdateRequested(newArchController);
    }

    function executeArchControllerUpdate() external onlyOwner {
        if (pendingArchController == address(0)) revert RevvFiErrors.PendingArchControllerNotSet();
        if (block.timestamp < archControllerUpdateTimelock) revert RevvFiErrors.UnauthorizedCaller();

        address oldArch = address(archController);
        archController = IRevvFiArchController(pendingArchController);
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;

        emit RevvFiEvents.ArchControllerUpdated(oldArch, address(archController));
    }

    function cancelArchControllerUpdate() external onlyOwner {
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
    }
}
