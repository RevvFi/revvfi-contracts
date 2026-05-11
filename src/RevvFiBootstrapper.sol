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

/**
 * @title RevvFiBootstrapper
 * @notice Core contract per launch. Holds ETH, tracks LP shares, creates Uniswap pool.
 * @dev IMMUTABLE AFTER DEPLOYMENT - all critical addresses set in initialize and cannot change
 */
contract RevvFiBootstrapper is Initializable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error ZeroDeposit();
    error HardCapExceeded();
    error TargetNotMet();
    error AlreadyLaunched();
    error AlreadyFailed();
    error NotLaunched();
    error RaiseNotEnded();
    error NotFailed();
    error RefundAlreadyClaimed();
    error NoShares();
    error RefundFailed();
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
    error InsufficientTokenBalance();
    error UnexpectedTokenBalance();

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADLINE_BUFFER = 300;
    uint256 public constant MIN_WITHDRAWAL_SHARES = 1e15; // Minimum 0.001 ETH worth of shares

    // =============================================================
    // Role Constants (for Central Authority)
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

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

    // Expected token balance to prevent manipulation
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

    modifier onlyFactory() {
        if (!ICentralAuthority(centralAuthority).hasRole(FACTORY_ROLE, msg.sender)) {
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
        if (block.timestamp > raiseEndTime) revert RaiseNotEnded();
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

        // Validate all required addresses
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

        // Set immutable core config
        creator = _creator;
        revvToken = _revvToken;
        weth = _weth;
        uniswapRouter = _uniswapRouter;
        platformFeeRecipient = _platformFeeRecipient;
        factory = msg.sender;
        launchId = _launchId;
        centralAuthority = _centralAuthority;

        // Set token allocations
        liquidityAllocation = _liquidityAllocation;
        creatorVestingAmount = _creatorVestingAmount;
        treasuryAmount = _treasuryAmount;
        strategicReserveAmount = _strategicReserveAmount;
        rewardsAmount = _rewardsAmount;

        // Calculate expected token balance
        expectedTokenBalance = _liquidityAllocation + _creatorVestingAmount + _treasuryAmount + _strategicReserveAmount + _rewardsAmount;

        // Set raise targets and timings
        targetLiquidityETH = _targetLiquidityETH;
        hardCapETH = _hardCapETH;
        raiseEndTime = block.timestamp + _raiseWindowDuration;
        lockDuration = _lockDuration;
        keeperReward = _keeperReward;

        // Set vesting parameters
        creatorCliffDuration = _creatorCliffDuration;
        creatorVestingDuration = _creatorVestingDuration;

        // Set vault addresses
        creatorVestingVault = _creatorVestingVault;
        treasuryVault = _treasuryVault;
        strategicReserveVault = _strategicReserveVault;
        rewardsDistributor = _rewardsDistributor;
        governanceModule = _governanceModule;

        rewardsInitialized = false;

        // Verify token balance
        uint256 actualBalance = IERC20(revvToken).balanceOf(address(this));
        if (actualBalance != expectedTokenBalance) revert InsufficientTokenBalance();

        // Safe approve for Uniswap router
        _safeApprove(revvToken, uniswapRouter, type(uint256).max);
        _safeApprove(weth, uniswapRouter, type(uint256).max);
    }

    // =============================================================
    // Safe Approval Helper
    // =============================================================

    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amount);
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

        emit Deposited(msg.sender, msg.value);
    }

    // =============================================================
    // Launch - Permissionless
    // =============================================================

    function launch() external nonReentrant onlyLaunchPhase {
        if (totalDepositedETH < targetLiquidityETH) revert TargetNotMet();

        // Verify token balance hasn't been manipulated
        uint256 currentBalance = IERC20(revvToken).balanceOf(address(this));
        if (currentBalance != expectedTokenBalance) revert UnexpectedTokenBalance();

        // Reserve keeper reward BEFORE adding liquidity
        uint256 ethForLiquidity = totalDepositedETH;
        if (keeperReward > 0) {
            if (totalDepositedETH <= keeperReward) revert InsufficientETHForLiquidity();
            ethForLiquidity = totalDepositedETH - keeperReward;
        }

        maturityTime = raiseEndTime + lockDuration;

        // Transfer tokens to vaults BEFORE initializing vesting
        _transferToVaults();

        // Now initialize creator vesting (tokens are already in vault)
        _initializeVestingVault();

        // Initialize rewards distributor schedule
        _initializeRewardsDistributor();

        // Add liquidity to Uniswap with remaining ETH
        _addLiquidityWithAmount(ethForLiquidity);

        launched = true;

        // Pay keeper reward to caller
        if (keeperReward > 0) {
            (bool sent,) = msg.sender.call{value: keeperReward}("");
            if (!sent) revert KeeperRewardFailed();
            emit KeeperRewardPaid(msg.sender, keeperReward);
        }

        // Notify factory of successful launch
        if (factory != address(0)) {
            IRevvFiFactory(factory).updateLaunchSuccess(launchId, maturityTime);
        }

        emit LaunchExecuted(totalDepositedETH, uniLPTokenAmount, uniswapPair, maturityTime, msg.sender);
    }

    // =============================================================
    // Mark Failed & Refunds
    // =============================================================

    function markFailed() external nonReentrant onlyLaunchPhase {
        if (block.timestamp <= raiseEndTime) revert RaiseNotEnded();
        if (totalDepositedETH >= targetLiquidityETH) revert TargetNotMet();
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

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit Refunded(msg.sender, amount);
    }

    // =============================================================
    // Withdrawals After Maturity
    // =============================================================

    function withdrawAsAssets(uint256 shareAmount) external nonReentrant afterLaunch whenNotPaused {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        
        // Prevent dust withdrawals that could cause rounding issues
        if (shareAmount < MIN_WITHDRAWAL_SHARES) revert InsufficientShareAmount();
        if (shareAmount > shares[msg.sender]) revert InvalidShareAmount();

        if (totalShares == 0) revert InvalidShareAmount();

        uint256 fraction = (shareAmount * PRECISION) / totalShares;
        uint256 lpToRemove = (fraction * uniLPTokenAmount) / PRECISION;

        if (lpToRemove == 0) revert InsufficientShareAmount();

        (uint256 ethOut, uint256 tokenOut) = _removeLiquidity(lpToRemove);

        // Update state before transfers
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uniLPTokenAmount -= lpToRemove;
        expectedTokenBalance -= tokenOut;

        // Notify governance
        if (governanceModule != address(0)) {
            try IRevvFiGovernance(governanceModule).onSharesUpdated(msg.sender, shares[msg.sender]) {} catch {}
        }

        // Transfer ETH
        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert RefundFailed();
        }

        // Transfer tokens
        if (tokenOut > 0) {
            IERC20(revvToken).safeTransfer(msg.sender, tokenOut);
        }

        emit AssetsWithdrawn(msg.sender, shareAmount, ethOut, tokenOut);
    }

    // =============================================================
    // Emergency Token Rescue (Guardian only after maturity)
    // Only allows rescue of tokens that are NOT core protocol assets
    // =============================================================

    function rescueTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidShareAmount();

        // CRITICAL: Never allow rescue of core protocol assets
        if (token == revvToken) revert CannotRescueCoreToken();
        if (token == uniswapPair) revert CannotRescueCoreToken();
        if (token == address(this)) revert CannotRescueCoreToken();

        // Also prevent rescuing WETH if it's part of the LP position
        if (token == weth) {
            if (uniLPTokenAmount > 0 && IERC20(uniswapPair).balanceOf(address(this)) > 0) {
                revert CannotRescueCoreToken();
            }
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InvalidShareAmount();

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRescued(token, amount, recipient);
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    function _addLiquidityWithAmount(uint256 ethAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        _createLPPair();

        uint256 minTokenAmount = (liquidityAllocation * 95) / 100;
        uint256 minETHAmount = (ethAmount * 95) / 100;

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

        // Update expected balance after token transfer to Uniswap
        expectedTokenBalance -= liquidityAllocation;

        address factoryAddr = router.factory();
        address pair = IUniswapV2Factory(factoryAddr).getPair(revvToken, weth);

        if (pair == address(0)) revert PairNotFound();
        uniswapPair = pair;
    }

    function _createLPPair() internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address factoryAddr = router.factory();
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(factoryAddr);

        address existingPair = uniswapFactory.getPair(revvToken, weth);
        
        if (existingPair == address(0)) {
            address newPair = uniswapFactory.createPair(revvToken, weth);
            if (newPair == address(0)) revert PairNotFound();
            uniswapPair = newPair;
        } else {
            uniswapPair = existingPair;
        }
    }

    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 ethOut, uint256 tokenOut) {
        if (uniswapPair == address(0)) revert PairNotFound();

        IERC20(uniswapPair).approve(uniswapRouter, lpAmount);

        (tokenOut, ethOut) = IUniswapV2Router02(uniswapRouter)
            .removeLiquidityETH(revvToken, lpAmount, 0, 0, address(this), block.timestamp + DEADLINE_BUFFER);
    }

    function _transferToVaults() internal {
        IERC20 token = IERC20(revvToken);

        // Transfer to Treasury Vault
        if (treasuryAmount > 0 && treasuryVault != address(0)) {
            token.safeTransfer(treasuryVault, treasuryAmount);
            emit TokensTransferredToVault(treasuryVault, treasuryAmount);
        }

        // Transfer to Strategic Reserve Vault
        if (strategicReserveAmount > 0 && strategicReserveVault != address(0)) {
            token.safeTransfer(strategicReserveVault, strategicReserveAmount);
            emit TokensTransferredToVault(strategicReserveVault, strategicReserveAmount);
        }

        // Transfer to Rewards Distributor
        if (rewardsAmount > 0 && rewardsDistributor != address(0)) {
            token.safeTransfer(rewardsDistributor, rewardsAmount);
            emit TokensTransferredToVault(rewardsDistributor, rewardsAmount);
        }

        // Note: Creator Vesting Vault tokens transferred later in _initializeVestingVault
        // to avoid double counting
        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            token.safeTransfer(creatorVestingVault, creatorVestingAmount);
            emit TokensTransferredToVault(creatorVestingVault, creatorVestingAmount);
        }
    }

    function _initializeVestingVault() internal {
        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            ICreatorVestingVault(creatorVestingVault).initializeVesting(
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
    }

    function emergencyUnpause() external onlyGuardian {
        _unpause();
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getShareValueBps(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * 10000) / totalShares;
    }

    function getVotingPower(address lp) external view returns (uint256) {
        return shares[lp];
    }

    function getLaunchId() external view returns (uint256) {
        return launchId;
    }

    // =============================================================
    // Receive ETH - restricted to prevent unexpected balance inflation
    // =============================================================

    receive() external payable {
        // Only allow ETH from Uniswap during withdrawals or during launch phase
        if (!launched && !failed && block.timestamp <= raiseEndTime) {
            // During launch phase, only accept ETH from depositETH function
            revert ZeroDeposit();
        }
        // After launch, ETH from Uniswap LP removal is allowed
    }

    uint256[46] private __gap;
}