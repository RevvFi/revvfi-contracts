// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

contract RevvFiCollateralEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientCollateral();
    error UnauthorizedCaller();
    error CollateralBelowMinimum();
    error AlreadyInitialized();
    error OracleNotSet();
    error InvalidDecimals();
    error OraclePriceStale();
    error InvalidCollateralRatio();
    error AlreadyLiquidating();

    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event CollateralLiquidated(address indexed borrower, uint256 collateralAmount, uint256 debtAmount);
    event MinCollateralRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event OracleUpdated(address indexed collateralAsset, address oracle, uint8 decimals);
    event LiquidationStarted(address indexed borrower);
    event LiquidationEnded(address indexed borrower);

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO = 10000;
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 9500;
    uint256 public constant STALE_PRICE_THRESHOLD = 2 hours;

    address public immutable factory;
    address public market;
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
    bool public isLiquidating;
    address public liquidatingBorrower;

    modifier onlyMarket() {
        if (msg.sender != market) revert UnauthorizedCaller();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    modifier notLiquidating() {
        if (isLiquidating) revert AlreadyLiquidating();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        minCollateralRatio = DEFAULT_MIN_COLLATERAL_RATIO;
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        isInitialized = false;
        isLiquidating = false;
    }

    function initialize(
        address _market,
        address _borrowAsset,
        address _collateralAsset,
        address _collateralOracle,
        uint8 _collateralDecimals,
        uint8 _borrowDecimals
    ) external onlyFactory {
        if (isInitialized) revert AlreadyInitialized();
        if (_market == address(0)) revert ZeroAddress();
        if (_borrowAsset == address(0)) revert ZeroAddress();
        if (_collateralAsset == address(0)) revert ZeroAddress();
        if (_collateralOracle == address(0)) revert OracleNotSet();
        if (_collateralDecimals == 0 || _collateralDecimals > 18) revert InvalidDecimals();
        if (_borrowDecimals == 0 || _borrowDecimals > 18) revert InvalidDecimals();

        market = _market;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        collateralOracle = _collateralOracle;
        collateralDecimals = _collateralDecimals;
        borrowDecimals = _borrowDecimals;
        
        collateralOracleDecimals = AggregatorV3Interface(_collateralOracle).decimals();
        
        isInitialized = true;
    }

    function depositCollateral(address borrower, uint256 amount) external onlyMarket nonReentrant notLiquidating {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(collateralAsset);
        token.safeTransferFrom(borrower, address(this), amount);

        collateralBalance[borrower] += amount;
        totalCollateral += amount;

        emit CollateralDeposited(borrower, amount);
    }

    function withdrawCollateral(address borrower, uint256 amount, uint256 currentDebt) external onlyMarket nonReentrant notLiquidating {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[borrower] < amount) revert InsufficientCollateral();

        uint256 newBalance = collateralBalance[borrower] - amount;
        if (currentDebt > 0) {
            uint256 valueAfter = _getCollateralValueFromAmount(newBalance);
            uint256 ratio = (valueAfter * BASIS_POINTS) / currentDebt;
            if (ratio < minCollateralRatio) revert InsufficientCollateral();
        }

        collateralBalance[borrower] = newBalance;
        totalCollateral -= amount;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(borrower, amount);

        emit CollateralWithdrawn(borrower, amount);
    }

    function _getCollateralValueFromAmount(uint256 amount) internal view returns (uint256 valueInBorrowAsset) {
        if (amount == 0) return 0;
        uint256 price = _getLatestPrice();
        
        // Safe normalization with overflow protection
        uint256 denominator = 10 ** collateralDecimals;
        uint256 valueInCollateralUnits = amount * price;
        
        // Convert to borrow asset decimals
        if (collateralOracleDecimals > borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits / (10 ** (collateralOracleDecimals - borrowDecimals));
        } else if (collateralOracleDecimals < borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits * (10 ** (borrowDecimals - collateralOracleDecimals));
        } else {
            valueInBorrowAsset = valueInCollateralUnits;
        }
        
        valueInBorrowAsset = valueInBorrowAsset / denominator;
    }

    function getCollateralRatio(address borrower, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrower]);
        return (collateralValue * BASIS_POINTS) / debt;
    }

    function _getCollateralValue(address borrower) internal view returns (uint256 valueInBorrowAsset, uint256 amount) {
        amount = collateralBalance[borrower];
        valueInBorrowAsset = _getCollateralValueFromAmount(amount);
    }

    function _getLatestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = 
            AggregatorV3Interface(collateralOracle).latestRoundData();
        
        if (price <= 0) revert OracleNotSet();
        if (updatedAt < block.timestamp - STALE_PRICE_THRESHOLD) revert OraclePriceStale();
        if (answeredInRound < roundId) revert OraclePriceStale();
        
        return uint256(price);
    }

    function isHealthy(address borrower, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrower]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio >= minCollateralRatio;
    }

    function isLiquidatable(address borrower, uint256 debt) public view returns (bool) {
        if (debt == 0) return false;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrower]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio < liquidationThreshold;
    }

    function getMaxBorrowable(address borrower) external view returns (uint256) {
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrower]);
        if (collateralValue == 0) return 0;
        return (collateralValue * BASIS_POINTS) / minCollateralRatio;
    }

    function startLiquidation(address borrower) external onlyMarket notLiquidating {
        if (!isLiquidatable(borrower, IRevvFiMarket(market).getTotalOwed())) {
            revert InsufficientCollateral();
        }
        isLiquidating = true;
        liquidatingBorrower = borrower;
        emit LiquidationStarted(borrower);
    }

    function endLiquidation() external onlyMarket {
        isLiquidating = false;
        liquidatingBorrower = address(0);
        emit LiquidationEnded(liquidatingBorrower);
    }

    function liquidate(
        address borrower,
        uint256 collateralToSeize,
        uint256 debtToCover,
        address liquidator
    ) external onlyMarket nonReentrant returns (uint256 collateralAmount, uint256 debtAmount) {
        if (!isLiquidating || liquidatingBorrower != borrower) revert UnauthorizedCaller();
        if (collateralBalance[borrower] < collateralToSeize) revert InsufficientCollateral();

        collateralBalance[borrower] -= collateralToSeize;
        totalCollateral -= collateralToSeize;

        IERC20 token = IERC20(collateralAsset);
        token.safeTransfer(liquidator, collateralToSeize);

        emit CollateralLiquidated(borrower, collateralToSeize, debtToCover);

        return (collateralToSeize, debtToCover);
    }

    function getCollateralBalance(address borrower) external view returns (uint256) {
        return collateralBalance[borrower];
    }

    function getCollateralValue(address borrower) external view returns (uint256 value, uint256 amount) {
        return _getCollateralValue(borrower);
    }

    function isLiquidationActive() external view returns (bool, address) {
        return (isLiquidating, liquidatingBorrower);
    }

    function setMinCollateralRatio(uint256 newRatio) external onlyFactory {
        if (newRatio == 0 || newRatio > BASIS_POINTS * 2) revert CollateralBelowMinimum();
        if (newRatio < liquidationThreshold) revert InvalidCollateralRatio();
        emit MinCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    function setLiquidationThreshold(uint256 newThreshold) external onlyFactory {
        if (newThreshold == 0 || newThreshold >= BASIS_POINTS) revert CollateralBelowMinimum();
        if (newThreshold > minCollateralRatio) revert InvalidCollateralRatio();
        emit LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }

    function setCollateralOracle(address newOracle) external onlyFactory {
        if (newOracle == address(0)) revert ZeroAddress();
        collateralOracle = newOracle;
        collateralOracleDecimals = AggregatorV3Interface(newOracle).decimals();
        emit OracleUpdated(collateralAsset, newOracle, collateralOracleDecimals);
    }
}

interface IRevvFiMarket {
    function getTotalOwed() external view returns (uint256);
}