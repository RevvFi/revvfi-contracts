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

/**
 * @title RevvFiCollateralEscrow
 * @author Preet Singh
 * @notice Manages collateral deposits, withdrawals, and liquidation calculations for each borrower
 * @dev This contract is deployed per lending market and holds borrower collateral.
 *      It uses a clone (EIP-1167) pattern where the factory deploys minimal proxies pointing to a single implementation.
 *      Features include:
 *      - Collateral deposits and withdrawals with health checks
 *      - Chainlink oracle integration for price feeds with staleness protection
 *      - Collateral ratio calculations for health monitoring
 *      - Liquidation threshold enforcement
 */
contract RevvFiCollateralEscrow is ReentrancyGuard, Initializable, IRevvFiCollateralEscrow {
    using SafeERC20 for IERC20;

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BP = 10000;

    /// @dev Default minimum collateral ratio (100%) used when not explicitly set
    uint256 private constant DEFAULT_MIN_CR = 10000;

    /// @dev Default liquidation threshold (95%) used when not explicitly set
    uint256 private constant DEFAULT_LIQ_THRESHOLD = 9500;

    /// @dev Maximum age of oracle price data before considering it stale (2 hours)
    uint256 private constant STALE_PRICE = 2 hours;

    /// @dev Factory contract that deployed this escrow (immutable reference)
    address public factory;

    /// @dev The lending market contract that controls this escrow
    address public market;

    /// @dev The borrower whose collateral is held in this escrow
    address public borrower;

    /// @dev Token being borrowed (e.g., USDC) - used for debt calculations
    address public borrowAsset;

    /// @dev Token used as collateral (e.g., WETH) - held in this contract
    address public collateralAsset;

    /// @dev Chainlink oracle address for collateral asset price feed
    address public collateralOracle;

    /// @dev Number of decimals in the oracle price data (e.g., 8 for Chainlink ETH/USD)
    uint8 public collateralOracleDecimals;

    /// @dev Number of decimals for the collateral token (e.g., 18 for WETH)
    uint8 public collateralDecimals;

    /// @dev Number of decimals for the borrow token (e.g., 6 for USDC)
    uint8 public borrowDecimals;

    /// @dev Amount of collateral deposited by each borrower
    mapping(address => uint256) public collateralBalance;

    /// @dev Total collateral held across all borrowers in this escrow
    uint256 public totalCollateral;

    /// @dev Minimum collateral ratio required to avoid liquidation (in basis points)
    uint256 public minCollateralRatio;

    /// @dev Threshold below which a position can be liquidated (in basis points)
    uint256 public liquidationThreshold;

    /// @dev Flag indicating whether liquidation is currently in progress
    bool public liquidationActive;

    /**
     * @dev Restricts function execution to the associated market contract only
     */
    modifier onlyMarket() {
        if (msg.sender != market) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Restricts function execution to the factory contract only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Prevents operations during active liquidation to maintain state consistency
     */
    modifier notLiquidating() {
        if (liquidationActive) revert RevvFiErrors.AlreadyLiquidating();
        _;
    }

    /**
     * @dev Constructor disables initializers for the implementation contract
     *      This prevents the implementation from being initialized directly
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes a cloned escrow instance with market-specific parameters
     * @param _factory Address of the RevvFiFactory that created this escrow
     * @param _market Address of the lending market this escrow belongs to
     * @param _borrower Address of the borrower whose collateral is held
     * @param _borrowAsset Token being borrowed (e.g., USDC)
     * @param _collateralAsset Token used as collateral (e.g., WETH)
     * @param _collateralOracle Chainlink oracle address for collateral price feeds
     * @param _collateralDecimals Number of decimals for the collateral token
     * @param _borrowDecimals Number of decimals for the borrow token
     * @notice Only callable by the factory contract
     * @dev Sets default ratios and fetches oracle decimals during initialization
     */
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

    /**
     * @dev Adds collateral to the borrower's position
     * @param borrowerAddr Address of the borrower depositing collateral
     * @param amount Amount of collateral tokens to deposit
     * @notice Only callable by the associated market contract
     * @dev Transfers collateral from the market to this escrow
     */
    function depositCollateral(address borrowerAddr, uint256 amount) external onlyMarket nonReentrant notLiquidating {
        if (borrowerAddr == address(0)) revert RevvFiErrors.ZeroAddress();
        if (amount == 0) revert RevvFiErrors.ZeroAmount();

        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[borrowerAddr] += amount;
        totalCollateral += amount;

        emit RevvFiEvents.CollateralDeposited(borrowerAddr, amount);
    }

    /**
     * @dev Withdraws collateral from the borrower's position
     * @param borrowerAddr Address of the borrower withdrawing collateral
     * @param amount Amount of collateral tokens to withdraw
     * @param currentDebt Current debt of the borrower
     * @notice Only callable by the associated market contract
     * @dev Ensures position remains healthy (ratio >= minCollateralRatio) after withdrawal
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
            uint256 ratio = (_getCollateralValueFromAmount(newBalance) * BP) / currentDebt;
            if (ratio < minCollateralRatio) revert RevvFiErrors.InsufficientCollateral();
        }

        collateralBalance[borrowerAddr] = newBalance;
        totalCollateral -= amount;
        IERC20(collateralAsset).safeTransfer(borrowerAddr, amount);

        emit RevvFiEvents.CollateralWithdrawn(borrowerAddr, amount);
    }

    /**
     * @dev Calculates the value of a given amount of collateral in borrow asset units
     * @param amount Amount of collateral tokens
     * @return valueInBorrowAsset Value in borrow asset units (with proper decimals)
     * @dev Handles decimal differences between:
     *      - Oracle price (typically 8 decimals)
     *      - Collateral token (varies, e.g., 18 for ETH)
     *      - Borrow token (varies, e.g., 6 for USDC)
     */
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

    /**
     * @dev Fetches the latest price from Chainlink oracle with staleness checks
     * @return Current price of the collateral asset
     * @dev Reverts if:
     *      - Price is <= 0
     *      - Updated at timestamp is 0
     *      - Price data is stale (> 2 hours old)
     *      - Round data is inconsistent (answeredInRound < roundId)
     */
    function _getLatestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3Interface(collateralOracle).latestRoundData();

        if (price <= 0 || updatedAt == 0 || block.timestamp > updatedAt + STALE_PRICE || answeredInRound < roundId) {
            revert RevvFiErrors.OraclePriceStale();
        }

        return uint256(price);
    }

    /**
     * @dev Returns the collateral ratio for a borrower
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return Collateral ratio in basis points (e.g., 15000 = 150%)
     * @dev Returns type(uint256).max when debt is 0 (infinite ratio)
     */
    function getCollateralRatio(address borrowerAddr, uint256 debt) external view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt;
    }

    /**
     * @dev Checks if a position meets the minimum collateral requirement
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return True if collateral ratio >= minCollateralRatio
     */
    function isHealthy(address borrowerAddr, uint256 debt) external view returns (bool) {
        if (debt == 0) return true;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt >= minCollateralRatio;
    }

    /**
     * @dev Checks if a position is eligible for liquidation
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return True if collateral ratio < liquidationThreshold
     */
    function isLiquidatable(address borrowerAddr, uint256 debt) public view returns (bool) {
        if (debt == 0) return false;
        return (_getCollateralValueFromAmount(collateralBalance[borrowerAddr]) * BP) / debt < liquidationThreshold;
    }

    /**
     * @dev Calculates maximum borrowable amount based on current collateral
     * @param borrowerAddr Address of the borrower
     * @return Maximum amount that can be borrowed in borrow asset units
     */
    function getMaxBorrowable(address borrowerAddr) external view returns (uint256) {
        uint256 value = _getCollateralValueFromAmount(collateralBalance[borrowerAddr]);
        return value == 0 ? 0 : (value * BP) / minCollateralRatio;
    }

    /**
     * @dev Returns detailed health status of a position
     * @param borrowerAddr Address of the borrower
     * @param debt Current debt amount
     * @return HealthStatus enum value (HEALTHY, WARNING, or LIQUIDATABLE)
     */
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

    /**
     * @dev Returns both value and raw amount of collateral for a borrower
     * @param borrower Address of the borrower
     * @return value Value in borrow asset units
     * @return amount Raw collateral amount
     */
    function getCollateralValue(address borrower) external view returns (uint256 value, uint256 amount) {
        amount = collateralBalance[borrower];
        value = _getCollateralValueFromAmount(amount);
    }

    /**
     * @dev Checks if liquidation is currently active
     * @return True if liquidation in progress
     */
    function isLiquidationActive() external view returns (bool) {
        return liquidationActive;
    }

    /**
     * @dev Begins liquidation process, prevents further operations
     * @notice Only callable by the associated market contract
     */
    function startLiquidation() external onlyMarket notLiquidating {
        liquidationActive = true;
        emit RevvFiEvents.LiquidationStarted(borrower);
    }

    /**
     * @dev Ends liquidation process, re-enables normal operations
     * @notice Only callable by the associated market contract
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
     * @notice Only callable by the associated market contract during active liquidation
     */
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

    /**
     * @dev Returns raw collateral balance for a borrower
     * @param borrowerAddr Address of the borrower
     * @return Amount of collateral held
     */
    function getCollateralBalance(address borrowerAddr) external view returns (uint256) {
        return collateralBalance[borrowerAddr];
    }

    /**
     * @dev Updates the minimum collateral ratio
     * @param newRatio New minimum collateral ratio in basis points
     * @notice Only callable by the factory contract
     * @dev Validates that the new ratio is within acceptable bounds (0 < ratio <= 20000)
     *      and that it's not below the liquidation threshold
     */
    function setMinCollateralRatio(uint256 newRatio) external onlyFactory {
        if (newRatio == 0 || newRatio > BP * 2) revert RevvFiErrors.CollateralBelowMinimum();
        if (newRatio < liquidationThreshold) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.MinCollateralRatioUpdated(minCollateralRatio, newRatio);
        minCollateralRatio = newRatio;
    }

    /**
     * @dev Updates the liquidation threshold
     * @param newThreshold New liquidation threshold in basis points
     * @notice Only callable by the factory contract
     * @dev Validates that the new threshold is within acceptable bounds (0 < threshold < 10000)
     *      and that it's not above the minimum collateral ratio
     */
    function setLiquidationThreshold(uint256 newThreshold) external onlyFactory {
        if (newThreshold == 0 || newThreshold >= BP) revert RevvFiErrors.CollateralBelowMinimum();
        if (newThreshold > minCollateralRatio) revert RevvFiErrors.InvalidCollateralRatio();
        emit RevvFiEvents.LiquidationThresholdUpdated(liquidationThreshold, newThreshold);
        liquidationThreshold = newThreshold;
    }
}
