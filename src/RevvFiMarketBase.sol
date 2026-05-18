// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IRevvFiArchController.sol";
import "./interfaces/IRevvFiCollateralEscrow.sol";
import "./interfaces/IRevvFiOfferBook.sol";
import "./interfaces/IRevvFiPositionNFT.sol";
import "./interfaces/IRevvFiLiquidator.sol";

/**
 * @title RevvFiMarketBase
 * @notice Base contract for RevvFi markets
 * @dev Contains core state and modifiers
 */
abstract contract RevvFiMarketBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

    error ZeroAddress();
    error UnauthorizedCaller();
    error MarketClosed();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error BorrowAmountTooHigh();
    error ZeroAmount();
    error NotApprovedBorrower();

    // ========================================================================== //
    //                                 Immutables                                  //
    // ========================================================================== //

    address public immutable factory;
    address public immutable archController;
    address public immutable borrower;
    address public immutable borrowAsset;
    address public immutable collateralAsset;

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiLiquidator public liquidator;

    uint256 public totalDebt;
    bool public isClosed;

    mapping(address => uint256[]) public lenderPositions;
    uint256 public nextPositionId;

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyBorrower() {
        if (msg.sender != borrower) revert UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    modifier marketOpen() {
        if (isClosed) revert MarketClosed();
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
        if (_factory == address(0)) revert ZeroAddress();
        if (_archController == address(0)) revert ZeroAddress();
        if (_borrower == address(0)) revert ZeroAddress();
        if (_borrowAsset == address(0)) revert ZeroAddress();
        if (_collateralAsset == address(0)) revert ZeroAddress();

        factory = _factory;
        archController = _archController;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;

        isClosed = false;
        totalDebt = 0;
        nextPositionId = 1;
    }

    // ========================================================================== //
    //                               Initialization                               //
    // ========================================================================== //

    function _setContracts(
        address _collateralEscrow,
        address _offerBook,
        address _positionNFT,
        address _liquidator
    ) internal {
        collateralEscrow = IRevvFiCollateralEscrow(_collateralEscrow);
        offerBook = IRevvFiOfferBook(_offerBook);
        positionNFT = IRevvFiPositionNFT(_positionNFT);
        liquidator = IRevvFiLiquidator(_liquidator);
    }

    // ========================================================================== //
    //                               View Functions                                //
    // ========================================================================== //

    function totalAssets() public view returns (uint256) {
        return IERC20(borrowAsset).balanceOf(address(this));
    }

    function getCollateralRatio() public view returns (uint256) {
        return collateralEscrow.getCollateralRatio(borrower, totalDebt);
    }

    function isHealthy() public view returns (bool) {
        return collateralEscrow.isHealthy(borrower, totalDebt);
    }

    function isLiquidatable() public view returns (bool) {
        return collateralEscrow.isLiquidatable(borrower, totalDebt);
    }

    function getMaxBorrowable() public view returns (uint256) {
        uint256 maxFromCollateral = collateralEscrow.getMaxBorrowable(borrower);
        if (maxFromCollateral <= totalDebt) return 0;
        return maxFromCollateral - totalDebt;
    }
}