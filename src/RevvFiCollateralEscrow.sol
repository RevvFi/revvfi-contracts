// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRevvFiMarket.sol";
import "./interfaces/IAggregatorV3Interface.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiCollateralEscrow
 * @author Preet Singh
 * @notice Manages collateral deposits, withdrawals, and liquidation calculations for each borrower
 * @dev Each market has its own escrow contract that holds borrower collateral
 */
contract RevvFiCollateralEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Health status categories for a borrower's position
    enum HealthStatus {
        HEALTHY, // Ratio >= minCollateralRatio
        WARNING, // Ratio between liquidationThreshold and minCollateralRatio
        LIQUIDATABLE // Ratio < liquidationThreshold
    }

    /// @dev Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @dev Default minimum collateral ratio (100%)
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO = 10000;

    /// @dev Default liquidation threshold (95%)
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 9500;

    /// @dev Maximum age of oracle price data before considering it stale
    uint256 public constant STALE_PRICE_THRESHOLD = 2 hours;

    /// @dev Factory contract that deployed this escrow
    address public immutable factory;

    /// @dev The lending market this escrow belongs to
    address public market;

    /// @dev The borrower whose collateral is held here
    address public borrower;

    /// @dev Token being borrowed (e.g., USDC)
    address public borrowAsset;

    /// @dev Token used as collateral (e.g., WETH)
    address public collateralAsset;

    /// @dev Chainlink oracle for collateral asset price feed
    address public collateralOracle;

    /// @dev Number of decimals in oracle price data
    uint8 public collateralOracleDecimals;

    /// @dev Number of decimals for collateral token
    uint8 public collateralDecimals;

    /// @dev Number of decimals for borrow token
    uint8 public borrowDecimals;

    /// @dev Amount of collateral deposited by each borrower
    mapping(address => uint256) public collateralBalance;

    /// @dev Total collateral held across all borrowers
    uint256 public totalCollateral;

    /// @dev Minimum collateral ratio required to avoid liquidation
    uint256 public minCollateralRatio;

    /// @dev Threshold below which a position can be liquidated
    uint256 public liquidationThreshold;

    /// @dev Whether the contract has been initialized
    bool public isInitialized;

    /// @dev Whether liquidation is currently in progress
    bool public liquidationActive;

    /// @dev Restricts function calls to the associated market contract
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts function calls to the factory contract
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Prevents operations during active liquidation
    modifier notLiquidating() {
        if (liquidationActive) revert RevvFiErrors.AlreadyLiquidating();
        _;
    }

    /**
     * @dev Sets up escrow with factory address and default parameters
     * @param _factory Address of the RevvFiFactory that created this escrow
     */
    constructor(address _factory) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        minCollateralRatio = DEFAULT_MIN_COLLATERAL_RATIO;
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        isInitialized = false;
        liquidationActive = false;
    }

    /**
     * @dev Initializes the escrow with market-specific parameters
     * @param _market Address of the lending market
     * @param _borrower Address of the borrower
     * @param _borrowAsset Token being borrowed
     * @param _collateralAsset Token used as collateral
     * @param _collateralOracle Chainlink oracle for collateral price
     * @param _collateralDecimals Decimals of collateral token
     * @param _borrowDecimals Decimals of borrow token
     */
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

        collateralOracleDecimals = IAggregatorV3Interface(_collateralOracle).decimals();

        isInitialized = true;
    }

    /**
     * @dev Adds collateral to the borrower's position
     * @param borrowerAddr Address of the borrower
     * @param amount Amount of collateral to deposit
     */
    function depositCollateral(address borrowerAddr, uint256 amount) external onlyMarket nonReentrant notLiquidating {
        if (borrowerAddr == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20 token = IERC20(collateralAsset);
        token.safeTransferFrom(msg.sender, address(this), amount);

        collateralBalance[borrowerAddr] += amount;
        totalCollateral += amount;

        emit RevvFiEvents.CollateralDeposited(borrowerAddr, amount);
    }

    /**
     * @dev Withdraws collateral, ensuring position remains healthy
     * @param borrowerAddr Address of the borrower
     * @param amount Amount to withdraw
     * @param currentDebt Current debt of the borrower
     */
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

    /**
     * @dev Calculates value of collateral in terms of borrow asset
     * @param amount Amount of collateral tokens
     * @return valueInBorrowAsset Value in borrow asset units
     */
    function _getCollateralValueFromAmount(uint256 amount) internal view returns (uint256 valueInBorrowAsset) {
        if (amount == 0) return 0;
        uint256 price = _getLatestPrice();

        uint256 denominator = 10 ** collateralDecimals;
        uint256 valueInCollateralUnits = amount * price;

        // Adjust for decimal differences between oracle, collateral, and borrow token
        if (collateralOracleDecimals > borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits / (10 ** (collateralOracleDecimals - borrowDecimals));
        } else if (collateralOracleDecimals < borrowDecimals) {
            valueInBorrowAsset = valueInCollateralUnits * (10 ** (borrowDecimals - collateralOracleDecimals));
        } else {
            valueInBorrowAsset = valueInCollateralUnits;
        }

        valueInBorrowAsset = valueInBorrowAsset / denominator;
    }

    /**
     * @dev Returns the collateral ratio for a borrower
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return Collateral ratio in basis points
     */
    function getCollateralRatio(address borrowerAddr, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        return (collateralValue * BASIS_POINTS) / debt;
    }

    /**
     * @dev Internal helper to get both value and amount of collateral
     * @param borrowerAddr Address of the borrower
     * @return valueInBorrowAsset Value in borrow asset units
     * @return amount Raw collateral amount
     */
    function _getCollateralValue(address borrowerAddr)
        internal
        view
        returns (uint256 valueInBorrowAsset, uint256 amount)
    {
        amount = collateralBalance[borrowerAddr];
        valueInBorrowAsset = _getCollateralValueFromAmount(amount);
    }

    /**
     * @dev Fetches latest price from Chainlink oracle with staleness checks
     * @return Current price of collateral asset
     */
    function _getLatestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3Interface(collateralOracle).latestRoundData();

        if (price <= 0) revert RevvFiErrors.OracleNotSet();
        if (updatedAt == 0) revert RevvFiErrors.OraclePriceStale();
        if (block.timestamp > updatedAt + STALE_PRICE_THRESHOLD) revert RevvFiErrors.OraclePriceStale();
        if (answeredInRound < roundId) revert RevvFiErrors.OraclePriceStale();

        return uint256(price);
    }

    /**
     * @dev Checks if a position meets the minimum collateral requirement
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return True if collateral ratio >= minCollateralRatio
     */
    function isHealthy(address borrowerAddr, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio >= minCollateralRatio;
    }

    /**
     * @dev Checks if a position is eligible for liquidation
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return True if collateral ratio < liquidationThreshold
     */
    function isLiquidatable(address borrowerAddr, uint256 debt) public view returns (bool) {
        if (debt == 0) return false;
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;
        return ratio < liquidationThreshold;
    }

    /**
     * @dev Returns detailed health status of a position
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return HealthStatus enum value
     */
    function getHealthStatus(address borrowerAddr, uint256 debt) external view returns (HealthStatus) {
        if (debt == 0) return HealthStatus.HEALTHY;

        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        uint256 ratio = (collateralValue * BASIS_POINTS) / debt;

        if (ratio >= minCollateralRatio) return HealthStatus.HEALTHY;
        if (ratio >= liquidationThreshold) return HealthStatus.WARNING;
        return HealthStatus.LIQUIDATABLE;
    }

    /**
     * @dev Calculates maximum borrowable amount based on current collateral
     * @param borrowerAddr Address of the borrower
     * @return Maximum amount that can be borrowed
     */
    function getMaxBorrowable(address borrowerAddr) external view returns (uint256) {
        uint256 collateralValue = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        if (collateralValue == 0) return 0;
        return (collateralValue * BASIS_POINTS) / minCollateralRatio;
    }

    /**
     * @dev Begins liquidation process, prevents further operations
     */
    function startLiquidation() external onlyMarket notLiquidating {
        liquidationActive = true;
        emit RevvFiEvents.LiquidationStarted(borrower);
    }

    /**
     * @dev Ends liquidation process, re-enables normal operations
     */
    function endLiquidation() external onlyMarket {
        liquidationActive = false;
        emit RevvFiEvents.LiquidationEnded(borrower);
    }

    /**
     * @dev Executes liquidation by seizing collateral
     * @param borrowerAddr Address of the borrower being liquidated
     * @param collateralToSeize Amount of collateral to seize
     * @param debtToCover Amount of debt being covered
     * @param liquidatorAddr Address that will receive the seized collateral
     * @return collateralAmount Amount of collateral seized
     * @return debtAmount Amount of debt covered
     */
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

    /**
     * @dev Returns raw collateral balance for a borrower
     * @param borrowerAddr Address of the borrower
     * @return Amount of collateral held
     */
    function getCollateralBalance(address borrowerAddr) external view returns (uint256) {
        return collateralBalance[borrowerAddr];
    }

    /**
     * @dev Returns both value and amount of collateral for a borrower
     * @param borrowerAddr Address of the borrower
     * @return value Value in borrow asset units
     * @return amount Raw collateral amount
     */
    function getCollateralValue(address borrowerAddr) external view returns (uint256 value, uint256 amount) {
        return _getCollateralValue(borrowerAddr);
    }

    /**
     * @dev Checks if liquidation is currently active
     * @return True if liquidation in progress
     */
    function isLiquidationActive() external view returns (bool) {
        return liquidationActive;
    }

    /**
     * @dev Updates minimum collateral ratio (factory only)
     * @param newRatio New minimum collateral ratio in basis points
     */
    function setMinCollateralRatio(uint256 newRatio) external onlyFactory {
        if (newRatio == 0 || newRatio > BASIS_POINTS * 2) revert RevvFiErrors.CollateralBelowMinimum();
        if (newRatio < liquidationThreshold) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.MinCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    /**
     * @dev Updates liquidation threshold (factory only)
     * @param newThreshold New liquidation threshold in basis points
     */
    function setLiquidationThreshold(uint256 newThreshold) external onlyFactory {
        if (newThreshold == 0 || newThreshold >= BASIS_POINTS) revert RevvFiErrors.CollateralBelowMinimum();
        if (newThreshold > minCollateralRatio) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }

    /**
     * @dev Updates collateral oracle address (factory only)
     * @param newOracle New Chainlink oracle address
     */
    function setCollateralOracle(address newOracle) external onlyFactory {
        if (newOracle == address(0)) revert RevvFiErrors.ZeroAddress();
        collateralOracle = newOracle;
        collateralOracleDecimals = IAggregatorV3Interface(newOracle).decimals();
        emit RevvFiEvents.OracleUpdated(collateralAsset, newOracle, collateralOracleDecimals);
    }
}
