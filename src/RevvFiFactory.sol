// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./RevvFiArchController.sol";
import "./RevvFiCollateralEscrow.sol";
import "./RevvFiOfferBook.sol";
import "./RevvFiPositionNFT.sol";
import "./RevvFiLiquidator.sol";
import "./RevvFiMarket.sol";

contract RevvFiFactory is Ownable, ReentrancyGuard {
    error ZeroAddress();
    error BorrowerNotRegistered();
    error InsufficientFee();
    error DeploymentFailed();
    error UnauthorizedCaller();
    error PendingArchControllerNotSet();

    event MarketDeployed(
        address indexed market,
        address indexed borrower,
        address borrowAsset,
        address collateralAsset,
        address collateralOracle,
        uint256 timestamp
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ArchControllerUpdateRequested(address indexed newArchController);
    event ArchControllerUpdated(address indexed oldArchController, address indexed newArchController);

    RevvFiArchController public archController;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;

    uint256 public deploymentFee;
    address public feeRecipient;

    address[] public allMarkets;

    address public pendingArchController;
    uint256 public archControllerUpdateTimelock;
    uint256 public constant TIMELOCK_DURATION = 2 days;

    constructor(
        address _archController,
        address _feeRecipient,
        uint256 _deploymentFee
    ) Ownable(msg.sender) {
        if (_archController == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        archController = RevvFiArchController(_archController);
        feeRecipient = _feeRecipient;
        deploymentFee = _deploymentFee;

        positionNFT = new RevvFiPositionNFT(address(this));
        liquidator = new RevvFiLiquidator(address(this));
        
        archController.registerControllerFactory(address(this));
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
        if (msg.value != deploymentFee) revert InsufficientFee();
        if (!archController.isRegisteredBorrower(borrower)) revert BorrowerNotRegistered();

        (bool feeSent, ) = feeRecipient.call{value: deploymentFee}("");
        require(feeSent, "Fee transfer failed");

        RevvFiMarket market = new RevvFiMarket(
            address(this),
            address(archController),
            borrower,
            borrowAsset,
            collateralAsset
        );

        marketAddress = address(market);

        RevvFiCollateralEscrow collateralEscrow = new RevvFiCollateralEscrow(address(this));
        collateralEscrow.initialize(
            marketAddress,
            borrowAsset,
            collateralAsset,
            collateralOracle,
            collateralDecimals,
            borrowDecimals
        );
        collateralEscrow.setMinCollateralRatio(minCollateralRatio);
        collateralEscrow.setLiquidationThreshold(liquidationThreshold);

        RevvFiOfferBook offerBook = new RevvFiOfferBook(address(this));
        offerBook.initialize(marketAddress, borrowAsset);

        market.setContracts(
            address(collateralEscrow),
            address(offerBook),
            address(positionNFT),
            address(liquidator)
        );

        archController.registerMarket(marketAddress);
        allMarkets.push(marketAddress);

        emit MarketDeployed(
            marketAddress,
            borrower,
            borrowAsset,
            collateralAsset,
            collateralOracle,
            block.timestamp
        );
    }

    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    function getMarketsCount() external view returns (uint256) {
        return allMarkets.length;
    }

    function setDeploymentFee(uint256 newFee) external onlyOwner {
        emit FeeUpdated(deploymentFee, newFee);
        deploymentFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    function requestArchControllerUpdate(address newArchController) external onlyOwner {
        if (newArchController == address(0)) revert ZeroAddress();
        pendingArchController = newArchController;
        archControllerUpdateTimelock = block.timestamp + TIMELOCK_DURATION;
        emit ArchControllerUpdateRequested(newArchController);
    }

    function executeArchControllerUpdate() external onlyOwner {
        if (pendingArchController == address(0)) revert PendingArchControllerNotSet();
        if (block.timestamp < archControllerUpdateTimelock) revert UnauthorizedCaller();
        
        address oldArchController = address(archController);
        archController = RevvFiArchController(pendingArchController);
        
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
        
        emit ArchControllerUpdated(oldArchController, address(archController));
    }

    function cancelArchControllerUpdate() external onlyOwner {
        pendingArchController = address(0);
        archControllerUpdateTimelock = 0;
    }
}