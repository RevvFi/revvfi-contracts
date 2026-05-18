// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RevvFiCollateralEscrow
 * @notice Manages borrower collateral deposits and tracks collateral ratios
 * @dev Each market has its own CollateralEscrow contract
 */
contract RevvFiCollateralEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientCollateral();
    error TransferFailed();
    error UnauthorizedCaller();
    error CollateralBelowMinimum();
    error MarketAlreadySet();

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event CollateralLiquidated(address indexed borrower, uint256 collateralAmount, uint256 debtAmount);
    event MinimumCollateralRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ========================================================================== //
    //                                 Constants                                   //
    // ========================================================================== //

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO = 10000; // 100%
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 9500; // 95%

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    address public immutable factory;
    address public market;
    address public borrowAsset;
    address public collateralAsset;

    mapping(address => uint256) public collateralBalance;
    uint256 public totalCollateral;

    uint256 public minCollateralRatio; // Basis points (10000 = 100%)
    uint256 public liquidationThreshold; // Basis points (9500 = 95%)

    bool public isInitialized;

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyMarket() {
        if (msg.sender != market) revert UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        minCollateralRatio = DEFAULT_MIN_COLLATERAL_RATIO;
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        isInitialized = false;
    }

    // ========================================================================== //
    //                               Initialization                               //
    // ========================================================================== //

    function initialize(
        address _market,
        address _borrowAsset,
        address _collateralAsset
    ) external onlyFactory {
        if (isInitialized) revert MarketAlreadySet();
        if (_market == address(0)) revert ZeroAddress();
        if (_borrowAsset == address(0)) revert ZeroAddress();
        if (_collateralAsset == address(0)) revert ZeroAddress();

        market = _market;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        isInitialized = true;
    }

    // ========================================================================== //
    //                           Collateral Management                            //
    // ========================================================================== //

    /**
     * @dev Deposit collateral (callable by borrower via market)
     */
    function depositCollateral(address borrower, uint256 amount) external onlyMarket nonReentrant {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(collateralAsset);
        token.safeTransferFrom(borrower, address(this), amount);

        collateralBalance[borrower] += amount;
        totalCollateral += amount;

        emit CollateralDeposited(borrower, amount);
    }

    /**
     * @dev Withdraw collateral (callable by borrower via market)
     */
    function withdrawCollateral(address borrower, uint256 amount) external onlyMarket nonReentrant {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[borrower] < amount) revert InsufficientCollateral();

        collateralBalance[borrower] -= amount;
        totalCollateral -= amount;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(borrower, amount);

        emit CollateralWithdrawn(borrower, amount);
    }

    /**
     * @dev Get current collateral ratio for a borrower
     */
    function getCollateralRatio(address borrower, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = collateralBalance[borrower];
        return (collateralValue * BASIS_POINTS) / debt;
    }

    /**
     * @dev Check if borrower is healthy (ratio >= minCollateralRatio)
     */
    function isHealthy(address borrower, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        uint256 ratio = (collateralBalance[borrower] * BASIS_POINTS) / debt;
        return ratio >= minCollateralRatio;
    }

    /**
     * @dev Check if borrower is below liquidation threshold
     */
    function isLiquidatable(address borrower, uint256 debt) external view returns (bool) {
        if (debt == 0) return false;
        uint256 ratio = (collateralBalance[borrower] * BASIS_POINTS) / debt;
        return ratio < liquidationThreshold;
    }

    /**
     * @dev Get available borrowable amount based on collateral
     */
    function getMaxBorrowable(address borrower) external view returns (uint256) {
        uint256 collateralValue = collateralBalance[borrower];
        if (collateralValue == 0) return 0;
        return (collateralValue * BASIS_POINTS) / minCollateralRatio;
    }

    // ========================================================================== //
    //                           Liquidation Functions                             //
    // ========================================================================== //

    /**
     * @dev Liquidate a borrower's position (callable by liquidator)
     */
    function liquidate(
        address borrower,
        uint256 collateralToSeize,
        uint256 debtToCover,
        address liquidator
    ) external onlyMarket nonReentrant returns (uint256 collateralAmount, uint256 debtAmount) {
        if (collateralBalance[borrower] < collateralToSeize) revert InsufficientCollateral();

        collateralBalance[borrower] -= collateralToSeize;
        totalCollateral -= collateralToSeize;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(liquidator, collateralToSeize);

        emit CollateralLiquidated(borrower, collateralToSeize, debtToCover);

        return (collateralToSeize, debtToCover);
    }

    /**
     * @dev Get borrower's collateral balance
     */
    function getCollateralBalance(address borrower) external view returns (uint256) {
        return collateralBalance[borrower];
    }

    // ========================================================================== //
    //                               Admin Functions                               //
    // ========================================================================== //

    function setMinCollateralRatio(uint256 newRatio) external onlyMarket {
        if (newRatio == 0 || newRatio > BASIS_POINTS * 2) revert CollateralBelowMinimum();
        emit MinimumCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    function setLiquidationThreshold(uint256 newThreshold) external onlyMarket {
        if (newThreshold == 0 || newThreshold >= BASIS_POINTS) revert CollateralBelowMinimum();
        emit LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }
}