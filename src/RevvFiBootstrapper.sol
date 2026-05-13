// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

import "./interfaces/IRevvFiGovernance.sol";
import "./interfaces/ICreatorVestingVault.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRevvFiFactory.sol";
import "./interfaces/ICentralAuthority.sol";

contract RevvFiBootstrapper is Initializable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error ZeroDeposit();
    error HardCapExceeded();
    error TargetNotMet();
    error TargetReached();
    error AlreadyLaunched();
    error AlreadyFailed();
    error NotLaunched();
    error RaiseNotEnded();
    error RaiseEnded();
    error NotFailed();
    error RefundAlreadyClaimed();
    error NoShares();
    error ETHTransferFailed();
    error WithdrawLocked();
    error InsufficientShareAmount();
    error InvalidShareAmount();
    error LiquidityAddFailed();
    error PairNotFound();
    error UnauthorizedCaller();
    error InsufficientETHForLiquidity();
    error KeeperRewardFailed();
    error VestingInitFailed();
    error RewardsInitFailed();
    error CannotRescueCoreToken();
    error CannotRescueETH();
    error InsufficientTokenBalance();
    error UnexpectedTokenBalance();
    error InvalidFactoryCaller();
    error GovernanceCallbackFail();
    error DivisionByZero();
    error SlippageTooHigh();

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADLINE_BUFFER = 300;
    uint256 public constant MIN_WITHDRAWAL_SHARES_BPS = 10; // 0.1% of total shares minimum
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 100; // 1% default slippage

    // =============================================================
    // Role Constants
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // =============================================================
    // Immutable Core Config
    // =============================================================

    address public creator;
    address public revvToken;
    address public weth;
    address public uniswapRouter;
    address public platformFeeRecipient;
    address public factory;
    address public centralAuthority;
    uint256 public launchId;

    // =============================================================
    // Immutable Token Allocations
    // =============================================================

    uint256 public liquidityAllocation;
    uint256 public creatorVestingAmount;
    uint256 public treasuryAmount;
    uint256 public strategicReserveAmount;
    uint256 public rewardsAmount;

    // =============================================================
    // Immutable Timings
    // =============================================================

    uint256 public raiseEndTime;
    uint256 public lockDuration;
    uint256 public creatorCliffDuration;
    uint256 public creatorVestingDuration;

    // =============================================================
    // Immutable Raise Targets
    // =============================================================

    uint256 public targetLiquidityETH;
    uint256 public hardCapETH;
    uint256 public keeperReward;

    // =============================================================
    // Immutable Vault Addresses
    // =============================================================

    address public creatorVestingVault;
    address public treasuryVault;
    address public strategicReserveVault;
    address public rewardsDistributor;
    address public governanceModule;

    // =============================================================
    // Mutable State
    // =============================================================

    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalDepositedETH;

    bool public launched;
    bool public failed;
    mapping(address => bool) public refundClaimed;

    address public uniswapPair;
    uint256 public uniLPTokenAmount;
    uint256 public maturityTime;

    bool public rewardsInitialized;
    uint256 public expectedTokenBalance;

    // =============================================================
    // Events
    // =============================================================

    event Deposited(address indexed user, uint256 amount);
    event LaunchExecuted(
        uint256 totalETH, uint256 lpMinted, address pair, uint256 maturityTime, address indexed caller
    );
    event Refunded(address indexed user, uint256 amount);
    event AssetsWithdrawn(address indexed user, uint256 shareBurned, uint256 ethOut, uint256 tokenOut);
    event KeeperRewardPaid(address indexed keeper, uint256 amount);
    event RewardsDistributorInitialized(address indexed distributor, uint256 startTime, uint256 endTime);
    event VestingVaultInitialized(address indexed vault, address creator, uint256 amount);
    event TokensTransferredToVault(address indexed vault, uint256 amount);
    event TokensRescued(address indexed token, uint256 amount, address indexed recipient);
    event GovernanceCallbackFailed(address indexed governance, address indexed lp, uint256 shares);
    event ETHRescued(address indexed recipient, uint256 amount);
    event PausedStateChanged(bool paused, address indexed executor);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyDAO() {
        if (!ICentralAuthority(centralAuthority).hasRole(DAO_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyGuardian() {
        if (!ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert UnauthorizedCaller();
        _;
    }

    modifier onlyLaunchPhase() {
        if (launched) revert AlreadyLaunched();
        if (failed) revert AlreadyFailed();
        if (block.timestamp > raiseEndTime) revert RaiseEnded();
        _;
    }

    modifier afterLaunch() {
        if (!launched) revert NotLaunched();
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initialize
    // =============================================================

    function initialize(
        address _creator,
        address _revvToken,
        address _weth,
        address _uniswapRouter,
        uint256 _liquidityAllocation,
        uint256 _targetLiquidityETH,
        uint256 _hardCapETH,
        uint256 _raiseWindowDuration,
        uint256 _lockDuration,
        uint256 _creatorVestingAmount,
        uint256 _treasuryAmount,
        uint256 _strategicReserveAmount,
        uint256 _rewardsAmount,
        uint256 _creatorCliffDuration,
        uint256 _creatorVestingDuration,
        address _platformFeeRecipient,
        uint256 _keeperReward,
        address _creatorVestingVault,
        address _treasuryVault,
        address _strategicReserveVault,
        address _rewardsDistributor,
        address _governanceModule,
        uint256 _launchId,
        address _centralAuthority
    ) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();

        if (!ICentralAuthority(_centralAuthority).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidFactoryCaller();
        }

        if (_creator == address(0)) revert ZeroAddress();
        if (_revvToken == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_uniswapRouter == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_creatorVestingVault == address(0)) revert ZeroAddress();
        if (_treasuryVault == address(0)) revert ZeroAddress();
        if (_strategicReserveVault == address(0)) revert ZeroAddress();
        if (_rewardsDistributor == address(0)) revert ZeroAddress();
        if (_governanceModule == address(0)) revert ZeroAddress();
        if (_launchId == 0) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        creator = _creator;
        revvToken = _revvToken;
        weth = _weth;
        uniswapRouter = _uniswapRouter;
        platformFeeRecipient = _platformFeeRecipient;
        factory = msg.sender;
        launchId = _launchId;
        centralAuthority = _centralAuthority;

        liquidityAllocation = _liquidityAllocation;
        creatorVestingAmount = _creatorVestingAmount;
        treasuryAmount = _treasuryAmount;
        strategicReserveAmount = _strategicReserveAmount;
        rewardsAmount = _rewardsAmount;

        expectedTokenBalance =
            _liquidityAllocation + _creatorVestingAmount + _treasuryAmount + _strategicReserveAmount + _rewardsAmount;

        targetLiquidityETH = _targetLiquidityETH;
        hardCapETH = _hardCapETH;
        raiseEndTime = block.timestamp + _raiseWindowDuration;
        lockDuration = _lockDuration;
        keeperReward = _keeperReward;

        creatorCliffDuration = _creatorCliffDuration;
        creatorVestingDuration = _creatorVestingDuration;

        creatorVestingVault = _creatorVestingVault;
        treasuryVault = _treasuryVault;
        strategicReserveVault = _strategicReserveVault;
        rewardsDistributor = _rewardsDistributor;
        governanceModule = _governanceModule;

        rewardsInitialized = false;

        uint256 actualBalance = IERC20(revvToken).balanceOf(address(this));
        if (actualBalance < expectedTokenBalance) revert InsufficientTokenBalance();

        _safeApprove(revvToken, uniswapRouter, type(uint256).max);
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).forceApprove(spender, amount);
    }

    // =============================================================
    // Deposit ETH
    // =============================================================

    function depositETH() external payable nonReentrant whenNotPaused onlyLaunchPhase {
        if (msg.value == 0) revert ZeroDeposit();

        if (hardCapETH > 0) {
            if (totalDepositedETH + msg.value > hardCapETH) revert HardCapExceeded();
        }

        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalDepositedETH += msg.value;
        _takeGovernanceSnapshot(msg.sender, shares[msg.sender]);
        emit Deposited(msg.sender, msg.value);
    }

    // =============================================================
    // Launch - Permissionless
    // =============================================================

    function launch() external nonReentrant whenNotPaused onlyLaunchPhase {
        if (totalDepositedETH < targetLiquidityETH) revert TargetNotMet();

        uint256 currentBalance = IERC20(revvToken).balanceOf(address(this));
        if (currentBalance < liquidityAllocation) revert UnexpectedTokenBalance();

        uint256 ethForLiquidity = totalDepositedETH;
        if (keeperReward > 0) {
            if (totalDepositedETH <= keeperReward) revert InsufficientETHForLiquidity();
            ethForLiquidity = totalDepositedETH - keeperReward;
        }

        maturityTime = raiseEndTime + lockDuration;

        _transferToVaults();
        _initializeVestingVault();
        _initializeRewardsDistributor();
        _addLiquidityWithAmount(ethForLiquidity);

        launched = true;

        if (keeperReward > 0) {
            (bool sent,) = msg.sender.call{value: keeperReward}("");
            if (!sent) revert KeeperRewardFailed();
            emit KeeperRewardPaid(msg.sender, keeperReward);
        }

        if (factory != address(0)) {
            IRevvFiFactory(factory).updateLaunchSuccess(launchId, maturityTime);
        }

        emit LaunchExecuted(totalDepositedETH, uniLPTokenAmount, uniswapPair, maturityTime, msg.sender);
    }

    // =============================================================
    // Mark Failed & Refunds
    // =============================================================

    function markFailed() external nonReentrant whenNotPaused onlyLaunchPhase {
        if (block.timestamp <= raiseEndTime) revert RaiseNotEnded();
        if (totalDepositedETH >= targetLiquidityETH) revert TargetReached();
        if (failed) revert AlreadyFailed();

        failed = true;

        if (factory != address(0)) {
            try IRevvFiFactory(factory).updateLaunchFailure(launchId) {} catch {}
        }
    }

    function claimRefund() external nonReentrant {
        if (!failed) revert NotFailed();
        if (refundClaimed[msg.sender]) revert RefundAlreadyClaimed();

        uint256 amount = shares[msg.sender];
        if (amount == 0) revert NoShares();

        refundClaimed[msg.sender] = true;
        delete shares[msg.sender];
        totalShares -= amount;
        totalDepositedETH -= amount;

        _takeGovernanceSnapshot(msg.sender, 0);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();

        emit Refunded(msg.sender, amount);
    }

    // =============================================================
    // Withdrawals After Maturity
    // =============================================================

    function withdrawAsAssets(uint256 shareAmount, uint256 minETHOut, uint256 minTokenOut)
        external
        nonReentrant
        afterLaunch
        whenNotPaused
    {
        if (block.timestamp < maturityTime) revert WithdrawLocked();

        uint256 minShares = (totalShares * MIN_WITHDRAWAL_SHARES_BPS) / BASIS_POINTS;
        if (shareAmount < minShares && shareAmount < totalShares) revert InsufficientShareAmount();
        if (shareAmount > shares[msg.sender]) revert InvalidShareAmount();
        if (totalShares == 0) revert InvalidShareAmount();

        uint256 fraction = (shareAmount * PRECISION) / totalShares;
        uint256 lpToRemove = (fraction * uniLPTokenAmount) / PRECISION;

        if (lpToRemove == 0) revert InsufficientShareAmount();

        uint256 previousLP = uniLPTokenAmount;
        if (previousLP == 0) revert DivisionByZero();

        // CEI Pattern: Update state BEFORE external call
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uniLPTokenAmount -= lpToRemove;

        _takeGovernanceSnapshot(msg.sender, shares[msg.sender]);

        // Now external calls with slippage protection
        (uint256 ethOut, uint256 tokenOut) = _removeLiquidity(lpToRemove, minETHOut, minTokenOut);

        if (governanceModule != address(0)) {
            try IRevvFiGovernance(governanceModule).onSharesUpdated(msg.sender, shares[msg.sender]) {
            // Success
            }
            catch {
                emit GovernanceCallbackFailed(governanceModule, msg.sender, shares[msg.sender]);
            }
        }

        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert ETHTransferFailed();
        }

        if (tokenOut > 0) {
            IERC20(revvToken).safeTransfer(msg.sender, tokenOut);
        }

        emit AssetsWithdrawn(msg.sender, shareAmount, ethOut, tokenOut);
    }

    // =============================================================
    // Emergency Token Rescue (Guardian Only)
    // =============================================================

    function rescueTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidShareAmount();

        if (token == revvToken) revert CannotRescueCoreToken();
        if (token == uniswapPair) revert CannotRescueCoreToken();
        if (token == address(this)) revert CannotRescueCoreToken();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InvalidShareAmount();

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRescued(token, amount, recipient);
    }

    function rescueETH(address recipient) external onlyGuardian {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = recipient.call{value: balance}("");
            if (!ok) revert ETHTransferFailed();
            emit ETHRescued(recipient, balance);
        } else {
            revert CannotRescueETH();
        }
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    function _takeGovernanceSnapshot(address user, uint256 newShares) internal {
        if (governanceModule != address(0)) {
            try IRevvFiGovernance(governanceModule).onSharesUpdated(user, newShares) {
            // Success
            }
            catch {
                emit GovernanceCallbackFailed(governanceModule, user, newShares);
            }
        }
    }

    function _addLiquidityWithAmount(uint256 ethAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        _ensureLPPairExists();

        uint256 minTokenAmount = (liquidityAllocation * (BASIS_POINTS - DEFAULT_SLIPPAGE_BPS)) / BASIS_POINTS;
        uint256 minETHAmount = (ethAmount * (BASIS_POINTS - DEFAULT_SLIPPAGE_BPS)) / BASIS_POINTS;

        (,, uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            revvToken,
            liquidityAllocation,
            minTokenAmount,
            minETHAmount,
            address(this),
            block.timestamp + DEADLINE_BUFFER
        );

        if (liquidity == 0) revert LiquidityAddFailed();
        uniLPTokenAmount = liquidity;
    }

    function _ensureLPPairExists() internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address factoryAddr = router.factory();
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(factoryAddr);

        address pair = uniswapFactory.getPair(revvToken, weth);
        if (pair == address(0)) {
            pair = uniswapFactory.createPair(revvToken, weth);
            if (pair == address(0)) revert PairNotFound();
        }
        uniswapPair = pair;
    }

    function _removeLiquidity(uint256 lpAmount, uint256 minEthOut, uint256 minTokenOut)
        internal
        returns (uint256 ethOut, uint256 tokenOut)
    {
        if (uniswapPair == address(0)) revert PairNotFound();

        IERC20(uniswapPair).forceApprove(uniswapRouter, lpAmount);

        (tokenOut, ethOut) = IUniswapV2Router02(uniswapRouter)
            .removeLiquidityETH(
                revvToken, lpAmount, minTokenOut, minEthOut, address(this), block.timestamp + DEADLINE_BUFFER
            );

        if (ethOut < minEthOut || tokenOut < minTokenOut) revert SlippageTooHigh();
    }

    function _transferToVaults() internal {
        IERC20 token = IERC20(revvToken);

        if (treasuryAmount > 0 && treasuryVault != address(0)) {
            token.safeTransfer(treasuryVault, treasuryAmount);
            emit TokensTransferredToVault(treasuryVault, treasuryAmount);
        }

        if (strategicReserveAmount > 0 && strategicReserveVault != address(0)) {
            token.safeTransfer(strategicReserveVault, strategicReserveAmount);
            emit TokensTransferredToVault(strategicReserveVault, strategicReserveAmount);
        }

        if (rewardsAmount > 0 && rewardsDistributor != address(0)) {
            token.safeTransfer(rewardsDistributor, rewardsAmount);
            emit TokensTransferredToVault(rewardsDistributor, rewardsAmount);
        }

        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            token.safeTransfer(creatorVestingVault, creatorVestingAmount);
            emit TokensTransferredToVault(creatorVestingVault, creatorVestingAmount);
        }
    }

    function _initializeVestingVault() internal {
        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            ICreatorVestingVault(creatorVestingVault)
                .initializeVesting(
                    revvToken,
                    creator,
                    creatorVestingAmount,
                    creatorCliffDuration,
                    creatorVestingDuration,
                    block.timestamp
                );

            emit VestingVaultInitialized(creatorVestingVault, creator, creatorVestingAmount);
        }
    }

    function _initializeRewardsDistributor() internal {
        if (rewardsAmount > 0 && rewardsDistributor != address(0) && !rewardsInitialized) {
            uint256 startTime = block.timestamp + lockDuration;
            uint256 endTime = startTime + creatorVestingDuration;

            IRewardDistributor(rewardsDistributor).initializeSchedule(startTime, endTime, rewardsAmount);
            rewardsInitialized = true;
            emit RewardsDistributorInitialized(rewardsDistributor, startTime, endTime);
        }
    }

    // =============================================================
    // Guardian Controls
    // =============================================================

    function emergencyPause() external onlyGuardian {
        _pause();
        emit PausedStateChanged(true, msg.sender);
    }

    function emergencyUnpause() external onlyGuardian {
        _unpause();
        emit PausedStateChanged(false, msg.sender);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getMinimumWithdrawalShares() external view returns (uint256) {
        return (totalShares * MIN_WITHDRAWAL_SHARES_BPS) / BASIS_POINTS;
    }

    function getShareValueBps(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * BASIS_POINTS) / totalShares;
    }

    function getVotingPower(address lp) external view returns (uint256) {
        return shares[lp];
    }

    function getLaunchId() external view returns (uint256) {
        return launchId;
    }

    // =============================================================
    // Receive ETH
    // =============================================================

    receive() external payable {}

    uint256[46] private __gap;
}
