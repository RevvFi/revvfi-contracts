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

/**
 * @title RevvFiFactory
 * @notice Factory for deploying new RevvFi markets
 */
contract RevvFiFactory is Ownable, ReentrancyGuard {
    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

    error ZeroAddress();
    error BorrowerNotRegistered();
    error InsufficientFee();
    error DeploymentFailed();

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

    event MarketDeployed(
        address indexed market,
        address indexed borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 timestamp
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    RevvFiArchController public archController;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;

    uint256 public deploymentFee;
    address public feeRecipient;

    address[] public allMarkets;

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

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

        // Deploy global contracts
        positionNFT = new RevvFiPositionNFT(address(this));
        liquidator = new RevvFiLiquidator(address(this));
    }

    // ========================================================================== //
    //                              Market Deployment                              //
    // ========================================================================== //

    /**
     * @dev Deploy a new market
     */
    function deployMarket(
        address borrower,
        address borrowAsset,
        address collateralAsset,
        uint256 minCollateralRatio,
        uint256 liquidationThreshold
    ) external payable nonReentrant returns (address marketAddress) {
        if (msg.value != deploymentFee) revert InsufficientFee();
        if (!archController.isRegisteredBorrower(borrower)) revert BorrowerNotRegistered();

        // Transfer fee
        (bool feeSent, ) = feeRecipient.call{value: deploymentFee}("");
        require(feeSent, "Fee transfer failed");

        // Deploy collateral escrow
        RevvFiCollateralEscrow collateralEscrow = new RevvFiCollateralEscrow(address(this));
        collateralEscrow.initialize(address(this), borrowAsset, collateralAsset);
        collateralEscrow.setMinCollateralRatio(minCollateralRatio);
        collateralEscrow.setLiquidationThreshold(liquidationThreshold);

        // Deploy offer book
        RevvFiOfferBook offerBook = new RevvFiOfferBook(address(this));
        offerBook.initialize(address(this), borrowAsset);

        // Deploy market
        RevvFiMarket market = new RevvFiMarket(
            address(this),
            address(archController),
            borrower,
            borrowAsset,
            collateralAsset
        );

        market.initialize(
            address(collateralEscrow),
            address(offerBook),
            address(positionNFT),
            address(liquidator)
        );

        marketAddress = address(market);

        // Register market with arch controller
        archController.registerMarket(marketAddress);

        allMarkets.push(marketAddress);

        emit MarketDeployed(marketAddress, borrower, borrowAsset, collateralAsset, block.timestamp);
    }

    // ========================================================================== //
    //                               View Functions                                //
    // ========================================================================== //

    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    function getMarketsCount() external view returns (uint256) {
        return allMarkets.length;
    }

    // ========================================================================== //
    //                               Admin Functions                               //
    // ========================================================================== //

    function setDeploymentFee(uint256 newFee) external onlyOwner {
        emit FeeUpdated(deploymentFee, newFee);
        deploymentFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    function setArchController(address newArchController) external onlyOwner {
        if (newArchController == address(0)) revert ZeroAddress();
        archController = RevvFiArchController(newArchController);
    }
}