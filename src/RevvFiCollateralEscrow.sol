// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiMarket.sol";
import "./interfaces/IAggregatorV3Interface.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiCollateralEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO = 10000;
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 9500;
    uint256 public constant STALE_PRICE_THRESHOLD = 2 hours;

    address public immutable factory;
    address public market;
    address public borrower;  // ADDED: store borrower address
    address public borrowAsset;
    address public collateralAsset;

    address public collateralOracle;
    uint8 public collateralOracleDecimals;
    uint8 public collateralDecimals;
    uint8 public borrowDecimals;

    mapping(address => uint256) public collateralBalance;
    uint256 public totalCollateral;

    uint256 public minCollateralRatio;
    uint256 public liquidationThreshold;

    bool public isInitialized;
    bool public liquidationActive; // Simplified - only one borrower per market

    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier notLiquidating() {
        if (liquidationActive) revert RevvFiErrors.AlreadyLiquidating();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        minCollateralRatio = DEFAULT_MIN_COLLATERAL_RATIO;
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        isInitialized = false;
        liquidationActive = false;
    }

    function initialize(
        address _market,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset,
        address _collateralOracle,
        uint8 _collateralDecimals,
        uint8 _borrowDecimals
    ) external onlyFactory {
        if (isInitialized) revert RevvFiErrors.AlreadyInitialized();
        if (_market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrower == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_borrowAsset == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_collateralAsset == address(0)) revert RevvFiErrors.ZeroAddress();
        if (_collateralOracle == address(0)) revert RevvFiErrors.OracleNotSet();
        if (_collateralDecimals == 0 || _collateralDecimals > 18) revert RevvFiErrors.InvalidDecimals();
        if (_borrowDecimals == 0 || _borrowDecimals > 18) revert RevvFiErrors.InvalidDecimals();

        market = _market;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        collateralOracle = _collateralOracle;
        collateralDecimals = _collateralDecimals;
        borrowDecimals = _borrowDecimals;

        collateralOracleDecimals = AggregatorV3Interface(_collateralOracle).decimals();

        isInitialized = true;
    }

    function depositCollateral(address borrowerAddr, uint256 amount) external onlyMarket nonReentrant notLiquidating {
        if (borrowerAddr == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 token = IERC20(collateralAsset);
        token.safeTransferFrom(borrowerAddr, address(this), amount);

        collateralBalance[borrowerAddr] += amount;
        totalCollateral += amount;

        emit RevvFiEvents.CollateralDeposited(borrowerAddr, amount);
    }

    function withdrawCollateral(address borrowerAddr, uint256 amount, uint256 currentDebt)
        external
        onlyMarket
        nonReentrant
        notLiquidating
    {
        if (borrowerAddr == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();
        if (collateralBalance[borrowerAddr] < amount) revert RevvFiErrors.InsufficientCollateral();

        uint256 newBalance = collateralBalance[borrowerAddr] - amount;
        if (currentDebt > 0) {
            uint256 valueAfter = _getCollateralValueFromAmount(newBalance);
            uint256 ratio = (valueAfter * BASIS_POINTS) / currentDebt;
            if (ratio < minCollateralRatio) revert RevvFiErrors.InsufficientCollateral();
        }

        collateralBalance[borrowerAddr] = newBalance;
        totalCollateral -= amount;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(borrowerAddr, amount);

        emit RevvFiEvents.CollateralWithdrawn(borrowerAddr, amount);
    }

    function _getCollateralValueFromAmount(uint256 amount) internal view returns (uint256 valueInBorrowAsset) {
        if (amount == 0) return 0;
        uint256 price = _getLatestPrice();

        uint256 denominator = 10 ** collateralDecimals;
        uint256 valueInCollateralUnits = amount * price;

        if (collateralOracleDecimals > borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits / (10 ** (collateralOracleDecimals - borrowDecimals));
        } else if (collateralOracleDecimals < borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits * (10 ** (borrowDecimals - collateralOracleDecimals));
        } else {
            valueInBorrowAsset = valueInCollateralUnits;
        }

        valueInBorrowAsset = valueInBorrowAsset / denominator;
    }

    function getCollateralRatio(address borrowerAddr, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        return (collateralValue * BASIS_POINTS) / debt;
    }

    function _getCollateralValue(address borrowerAddr) internal view returns (uint256 valueInBorrowAsset, uint256 amount) {
        amount = collateralBalance[borrowerAddr];
        valueInBorrowAsset = _getCollateralValueFromAmount(amount);
    }

    function _getLatestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(collateralOracle).latestRoundData();

        if (price <= 0) revert RevvFiErrors.OracleNotSet();
        if (updatedAt < block.timestamp - STALE_PRICE_THRESHOLD) revert RevvFiErrors.OraclePriceStale();
        if (answeredInRound < roundId) revert RevvFiErrors.OraclePriceStale();

        return uint256(price);
    }

    function isHealthy(address borrowerAddr, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio >= minCollateralRatio;
    }

    function isLiquidatable(address borrowerAddr, uint256 debt) public view returns (bool) {
        if (debt == 0) return false;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio < liquidationThreshold;
    }

    function getMaxBorrowable(address borrowerAddr) external view returns (uint256) {
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        if (collateralValue == 0) return 0;
        return (collateralValue * BASIS_POINTS) / minCollateralRatio;
    }

    function startLiquidation() external onlyMarket notLiquidating {
        liquidationActive = true;
        emit RevvFiEvents.LiquidationStarted(borrower);
    }

    function endLiquidation() external onlyMarket {
        liquidationActive = false;
        emit RevvFiEvents.LiquidationEnded(borrower);
    }

    function liquidate(address borrowerAddr, uint256 collateralToSeize, uint256 debtToCover, address liquidatorAddr)
        external
        onlyMarket
        nonReentrant
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        if (!liquidationActive) revert RevvFiErrors.UnauthorizedCaller();
        if (collateralBalance[borrowerAddr] < collateralToSeize) revert RevvFiErrors.InsufficientCollateral();

        collateralBalance[borrowerAddr] -= collateralToSeize;
        totalCollateral -= collateralToSeize;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(liquidatorAddr, collateralToSeize);

        emit RevvFiEvents.CollateralLiquidated(borrowerAddr, collateralToSeize, debtToCover);

        return (collateralToSeize, debtToCover);
    }

    function getCollateralBalance(address borrowerAddr) external view returns (uint256) {
        return collateralBalance[borrowerAddr];
    }

    function getCollateralValue(address borrowerAddr) external view returns (uint256 value, uint256 amount) {
        return _getCollateralValue(borrowerAddr);
    }

    function isLiquidationActive() external view returns (bool) {
        return liquidationActive;
    }

    function setMinCollateralRatio(uint256 newRatio) external onlyFactory {
        if (newRatio == 0 || newRatio > BASIS_POINTS * 2) revert RevvFiErrors.CollateralBelowMinimum();
        if (newRatio < liquidationThreshold) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.MinCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    function setLiquidationThreshold(uint256 newThreshold) external onlyFactory {
        if (newThreshold == 0 || newThreshold >= BASIS_POINTS) revert RevvFiErrors.CollateralBelowMinimum();
        if (newThreshold > minCollateralRatio) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }

    function setCollateralOracle(address newOracle) external onlyFactory {
        if (newOracle == address(0)) revert RevvFiErrors.ZeroAddress();
        collateralOracle = newOracle;
        collateralOracleDecimals = AggregatorV3Interface(newOracle).decimals();
        emit RevvFiEvents.OracleUpdated(collateralAsset, newOracle, collateralOracleDecimals);
    }
}