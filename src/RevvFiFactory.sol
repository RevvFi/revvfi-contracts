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

contract RevvFiFactory is Ownable, ReentrancyGuard {
    RevvFiArchController public archController;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    uint256 public deploymentFee;
    address public feeRecipient;

    address[] public allMarkets;

    address public pendingArchController;
    uint256 public archControllerUpdateTimelock;
    uint256 public constant TIMELOCK_DURATION = 2 days;

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

        (bool feeSent,) = feeRecipient.call{value: deploymentFee}("");
        if (!feeSent) revert RevvFiErrors.FeeTransferFailed();

        // Register borrower with reputation registry
        reputationRegistry.registerBorrower(borrower);

        RevvFiMarket market =
            new RevvFiMarket(address(this), address(archController), borrower, borrowAsset, collateralAsset);

        marketAddress = address(market);

        RevvFiCollateralEscrow collateralEscrow = new RevvFiCollateralEscrow(address(this));
        collateralEscrow.initialize(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, collateralDecimals, borrowDecimals
        );
        collateralEscrow.setMinCollateralRatio(minCollateralRatio);
        collateralEscrow.setLiquidationThreshold(liquidationThreshold);

        RevvFiOfferBook offerBook = new RevvFiOfferBook(address(this));
        offerBook.initialize(marketAddress, borrowAsset);

        // Deploy LiquidityQueue for this market
        RevvFiLiquidityQueue liquidityQueue =
            new RevvFiLiquidityQueue(marketAddress, address(this), address(positionNFT));

        market.setContracts(
            address(collateralEscrow),
            address(offerBook),
            address(positionNFT),
            address(liquidator),
            address(reputationRegistry)
        );

        // After market.setContracts(...)
        reputationRegistry.registerMarket(marketAddress);

        archController.registerMarket(marketAddress);
        allMarkets.push(marketAddress);

        emit RevvFiEvents.MarketDeployed(
            marketAddress, borrower, borrowAsset, collateralAsset, collateralOracle, block.timestamp
        );
    }

    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    function getMarketsCount() external view returns (uint256) {
        return allMarkets.length;
    }

    function registerWithArchController() external onlyOwner {
        archController.registerControllerFactory(address(this));
        // Also register the factory as a controller so it can register markets
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
        archControllerUpdateTimelock = block.timestamp + TIMELOCK_DURATION;
        emit RevvFiEvents.ArchControllerUpdateRequested(newArchController);
    }

    function executeArchControllerUpdate() external onlyOwner {
        if (pendingArchController == address(0)) revert RevvFiErrors.PendingArchControllerNotSet();
        if (block.timestamp < archControllerUpdateTimelock) revert RevvFiErrors.UnauthorizedCaller();

        address oldArchController = address(archController);
        archController = RevvFiArchController(pendingArchController);

        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;

        emit RevvFiEvents.ArchControllerUpdated(oldArchController, address(archController));
    }

    function cancelArchControllerUpdate() external onlyOwner {
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
    }
}
