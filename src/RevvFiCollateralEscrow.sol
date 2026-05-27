// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IAggregatorV3Interface.sol";
import "./interfaces/IRevvFiCollateralEscrow.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiCollateralEscrow is ReentrancyGuard, Initializable, IRevvFiCollateralEscrow {
    using SafeERC20 for IERC20;

    uint256 public constant BP = 10000;
    uint256 private constant DEFAULT_MIN_CR = 10000;
    uint256 private constant DEFAULT_LIQ_THRESHOLD = 9500;
    uint256 private constant STALE_PRICE = 2 hours;

    address public factory;
    address public market;
    address public borrower;
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
    bool public liquidationActive;

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

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _factory,
        address _market,
        address _borrower,
        address _borrowAsset,
        address _collateralAsset,
        address _collateralOracle,
        uint8 _collateralDecimals,
        uint8 _borrowDecimals
    ) external initializer {
        if (
            _factory == address(0) || _market == address(0) || _borrower == address(0) || _borrowAsset == address(0)
                || _collateralAsset == address(0) || _collateralOracle == address(0)
        ) {
            revert RevvFiErrors.ZeroAddress();
        }

        if (_collateralDecimals == 0 || _collateralDecimals > 18 || _borrowDecimals == 0 || _borrowDecimals > 18) {
            revert RevvFiErrors.InvalidDecimals();
        }

        factory = _factory;
        market = _market;
        borrower = _borrower;
        borrowAsset = _borrowAsset;
        collateralAsset = _collateralAsset;
        collateralOracle = _collateralOracle;
        collateralDecimals = _collateralDecimals;
        borrowDecimals = _borrowDecimals;
        minCollateralRatio = DEFAULT_MIN_CR;
        liquidationThreshold = DEFAULT_LIQ_THRESHOLD;

        collateralOracleDecimals = IAggregatorV3Interface(_collateralOracle).decimals();
    }

    function depositCollateral(address borrowerAddr, uint256 amount) external onlyMarket nonReentrant notLiquidating {
        if (borrowerAddr == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), amount);
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
            uint256 ratio = (_getCollateralValueFromAmount(newBalance) * BP) / currentDebt;
            if (ratio < minCollateralRatio) revert RevvFiErrors.InsufficientCollateral();
        }

        collateralBalance[borrowerAddr] = newBalance;
        totalCollateral -= amount;
        IERC20(collateralAsset).safeTransfer(borrowerAddr, amount);

        emit RevvFiEvents.CollateralWithdrawn(borrowerAddr, amount);
    }

    function _getCollateralValueFromAmount(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        uint256 price = _getLatestPrice();
        uint256 value = amount * price;

        uint8 oracleDec = collateralOracleDecimals;
        uint8 borrowDec = borrowDecimals;

        if (oracleDec > borrowDec) {
            value /= 10 ** (oracleDec - borrowDec);
        } else if (oracleDec < borrowDec) {
            value *= 10 ** (borrowDec - oracleDec);
        }

        return value / (10 ** collateralDecimals);
    }

    function _getLatestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3Interface(collateralOracle).latestRoundData();

        if (price <= 0 || updatedAt == 0 || block.timestamp > updatedAt + STALE_PRICE || answeredInRound < roundId) {
            revert RevvFiErrors.OraclePriceStale();
        }

        return uint256(price);
    }

    function getCollateralRatio(address borrowerAddr, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt;
    }

    function isHealthy(address borrowerAddr, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt >= minCollateralRatio;
    }

    function isLiquidatable(address borrowerAddr, uint256 debt) public view returns (bool) {
        if (debt == 0) return false;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt < liquidationThreshold;
    }

    function getMaxBorrowable(address borrowerAddr) external view returns (uint256) {
        uint256 value = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        return value == 0 ? 0 : (value * BP) / minCollateralRatio;
    }

    function getHealthStatus(address borrowerAddr, uint256 debt) external view returns (HealthStatus) {
        if (debt == 0) return HealthStatus.HEALTHY;

        uint256 ratio = (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt;

        if (ratio < liquidationThreshold) {
            return HealthStatus.LIQUIDATABLE;
        } else if (ratio >= minCollateralRatio) {
            return HealthStatus.HEALTHY;
        } else {
            return HealthStatus.WARNING;
        }
    }

    function getCollateralValue(address borrower) external view returns (uint256 value, uint256 amount) {
        amount = collateralBalance[borrower];
        value = _getCollateralValueFromAmount(amount);
    }

    function isLiquidationActive() external view returns (bool) {
        return liquidationActive;
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
        returns (uint256, uint256)
    {
        if (!liquidationActive) revert RevvFiErrors.UnauthorizedCaller();
        if (collateralBalance[borrowerAddr] < collateralToSeize) revert RevvFiErrors.InsufficientCollateral();

        collateralBalance[borrowerAddr] -= collateralToSeize;
        totalCollateral -= collateralToSeize;
        IERC20(collateralAsset).safeTransfer(liquidatorAddr, collateralToSeize);

        emit RevvFiEvents.CollateralLiquidated(borrowerAddr, collateralToSeize, debtToCover);
        return (collateralToSeize, debtToCover);
    }

    function getCollateralBalance(address borrowerAddr) external view returns (uint256) {
        return collateralBalance[borrowerAddr];
    }

    function setMinCollateralRatio(uint256 newRatio) external onlyFactory {
        if (newRatio == 0 || newRatio > BP * 2) revert RevvFiErrors.CollateralBelowMinimum();
        if (newRatio < liquidationThreshold) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.MinCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    function setLiquidationThreshold(uint256 newThreshold) external onlyFactory {
        if (newThreshold == 0 || newThreshold >= BP) revert RevvFiErrors.CollateralBelowMinimum();
        if (newThreshold > minCollateralRatio) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }
}
