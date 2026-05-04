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

// Fix import paths - these should exist in ./interfaces/ directory
import "./interfaces/IRevvFiGovernance.sol";
import "./interfaces/ICreatorVestingVault.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/IRewardsDistributor.sol";
import "./interfaces/IRevvFiFactory.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title RevvFiBootstrapper
 * @notice Core contract per launch. Holds ETH, tracks LP shares, creates Uniswap pool.
 * @dev IMMUTABLE AFTER DEPLOYMENT - all critical addresses set in initialize and cannot change
 */
contract RevvFiBootstrapper is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
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
    error RaiseNotEnded();
    error NotFailed();
    error RefundAlreadyClaimed();
    error NoShares();
    error RefundFailed();
    error WithdrawLocked();
    error InvalidShareAmount();
    error LiquidityAddFailed();
    error PairNotFound();
    error UnauthorizedCaller();
    error VaultAlreadySet();
    error InsufficientETHForLiquidity();
    error KeeperRewardFailed();
    error VestingInitFailed();
    error RewardsInitFailed();

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEADLINE_BUFFER = 300; // 5 minutes

    // =============================================================
    // Role Constants (for Central Authority)
    // =============================================================
    
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant BOOTSTRAPPER_ROLE = keccak256("BOOTSTRAPPER_ROLE");

    // =============================================================
    // Immutable Core Config (Set Once in Initialize)
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

    // =============================================================
    // Events
    // =============================================================

    event Deposited(address indexed user, uint256 amount);
    event LaunchExecuted(
        uint256 totalETH,
        uint256 lpMinted,
        address pair,
        uint256 maturityTime,
        address indexed caller
    );
    event Refunded(address indexed user, uint256 amount);
    event AssetsWithdrawn(
        address indexed user,
        uint256 shareBurned,
        uint256 ethOut,
        uint256 tokenOut
    );
    event KeeperRewardPaid(address indexed keeper, uint256 amount);
    event RewardsDistributorInitialized(address indexed distributor, uint256 startTime, uint256 endTime);

    // =============================================================
    // Role Check Modifiers (Using Central Authority)
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
        if (!launched) revert AlreadyLaunched();
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initialize (Called by Factory via CREATE2)
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

        _safeApprove(revvToken, uniswapRouter, type(uint256).max);
        _safeApprove(weth, uniswapRouter, type(uint256).max);
        
        // Register this bootstrapper with Central Authority
        ICentralAuthority(centralAuthority).authorizeContract(address(this), BOOTSTRAPPER_ROLE);
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

    function depositETH()
        external
        payable
        nonReentrant
        whenNotPaused
        onlyLaunchPhase
    {
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
            (bool sent, ) = msg.sender.call{value: keeperReward}("");
            if (!sent) revert KeeperRewardFailed();
            emit KeeperRewardPaid(msg.sender, keeperReward);
        }

        _notifyFactorySuccess();

        emit LaunchExecuted(
            totalDepositedETH,
            uniLPTokenAmount,
            uniswapPair,
            maturityTime,
            msg.sender
        );
    }

    // =============================================================
    // Mark Failed & Refunds
    // =============================================================

    function markFailed() external nonReentrant onlyLaunchPhase {
        if (block.timestamp <= raiseEndTime) revert RaiseNotEnded();
        if (totalDepositedETH >= targetLiquidityETH) revert TargetNotMet();
        if (failed) revert AlreadyFailed();

        failed = true;
        _notifyFactoryFailure();
    }

    function claimRefund() external nonReentrant {
        if (!failed) revert NotFailed();
        if (refundClaimed[msg.sender]) revert RefundAlreadyClaimed();

        uint256 amount = shares[msg.sender];
        if (amount == 0) revert NoShares();

        refundClaimed[msg.sender] = true;
        shares[msg.sender] = 0;
        totalShares -= amount;
        totalDepositedETH -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit Refunded(msg.sender, amount);
    }

    // =============================================================
    // Withdrawals After Maturity
    // =============================================================

    function withdrawAsAssets(uint256 shareAmount)
        external
        nonReentrant
        afterLaunch
        whenNotPaused
    {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (shareAmount == 0 || shareAmount > shares[msg.sender]) revert InvalidShareAmount();

        if (totalShares == 0) revert InvalidShareAmount();

        uint256 fraction = (shareAmount * PRECISION) / totalShares;
        uint256 lpToRemove = (fraction * uniLPTokenAmount) / PRECISION;

        (uint256 ethOut, uint256 tokenOut) = _removeLiquidity(lpToRemove);

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uniLPTokenAmount -= lpToRemove;

        if (governanceModule != address(0)) {
            try IRevvFiGovernance(governanceModule).onSharesUpdated(
                msg.sender,
                shares[msg.sender]
            ) {} catch {}
        }

        if (ethOut > 0) {
            (bool ok, ) = msg.sender.call{value: ethOut}("");
            if (!ok) revert RefundFailed();
        }

        if (tokenOut > 0) {
            IERC20(revvToken).safeTransfer(msg.sender, tokenOut);
        }

        emit AssetsWithdrawn(msg.sender, shareAmount, ethOut, tokenOut);
    }

    // =============================================================
    // Emergency Token Rescue (DAO only after maturity)
    // =============================================================

    function rescueTokens(address token, uint256 amount, address recipient) external onlyDAO {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (recipient == address(0)) revert ZeroAddress();
        
        if (token == revvToken) {
            uint256 lockedAmount = IERC20(revvToken).balanceOf(address(this));
            if (amount > lockedAmount) revert InvalidShareAmount();
        }
        
        IERC20(token).safeTransfer(recipient, amount);
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    function _addLiquidityWithAmount(uint256 ethAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        (, , uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            revvToken,
            liquidityAllocation,
            0,
            0,
            address(this),
            block.timestamp + DEADLINE_BUFFER
        );

        if (liquidity == 0) revert LiquidityAddFailed();
        uniLPTokenAmount = liquidity;

        address factoryAddr = router.factory();
        address pair = IUniswapV2Factory(factoryAddr).getPair(revvToken, weth);

        if (pair == address(0)) revert PairNotFound();
        uniswapPair = pair;
    }

    function _removeLiquidity(uint256 lpAmount)
        internal
        returns (uint256 ethOut, uint256 tokenOut)
    {
        if (uniswapPair == address(0)) revert PairNotFound();

        IERC20(uniswapPair).approve(uniswapRouter, lpAmount);

        (tokenOut, ethOut) = IUniswapV2Router02(uniswapRouter).removeLiquidityETH(
            revvToken,
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp + DEADLINE_BUFFER
        );
    }

    function _transferToVaults() internal {
        IERC20 token = IERC20(revvToken);

        if (treasuryAmount > 0 && treasuryVault != address(0)) {
            token.safeTransfer(treasuryVault, treasuryAmount);
        }

        if (strategicReserveAmount > 0 && strategicReserveVault != address(0)) {
            token.safeTransfer(strategicReserveVault, strategicReserveAmount);
        }

        if (rewardsAmount > 0 && rewardsDistributor != address(0)) {
            token.safeTransfer(rewardsDistributor, rewardsAmount);
        }

        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            token.safeTransfer(creatorVestingVault, creatorVestingAmount);
        }
    }

    function _initializeVestingVault() internal {
    if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
        try ICreatorVestingVault(creatorVestingVault).initializeVesting(
            revvToken,
            creator,
            creatorVestingAmount,
            creatorCliffDuration,
            creatorVestingDuration,
            block.timestamp
        ) {
            // success
        } catch {
            revert VestingInitFailed();
        }
    }
}

    function _initializeRewardsDistributor() internal {
        if (rewardsAmount > 0 && rewardsDistributor != address(0) && !rewardsInitialized) {
            uint256 startTime = block.timestamp + lockDuration;
            uint256 endTime = startTime + creatorVestingDuration;
            
            try IRewardsDistributor(rewardsDistributor).initializeSchedule(
                startTime,
                endTime,
                rewardsAmount
            ) {
                rewardsInitialized = true;
                emit RewardsDistributorInitialized(rewardsDistributor, startTime, endTime);
                
                if (factory != address(0)) {
                    try IRevvFiFactory(factory).updateLaunchRewardsInitialized(launchId) {} catch {}
                }
            } catch {
                revert RewardsInitFailed();
            }
        }
    }

    function _notifyFactorySuccess() internal {
        if (factory != address(0)) {
            try IRevvFiFactory(factory).updateLaunchSuccess(launchId, maturityTime) {} catch {}
        }
    }

    function _notifyFactoryFailure() internal {
        if (factory != address(0)) {
            try IRevvFiFactory(factory).updateLaunchFailure(launchId) {} catch {}
        }
    }

    // =============================================================
    // Guardian Controls (via Factory)
    // =============================================================

    function emergencyPause() external onlyFactory {
        _pause();
    }

    function emergencyUnpause() external onlyFactory {
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
    // Receive ETH
    // =============================================================

    receive() external payable {}

    // =============================================================
    // Storage Gap for Upgrades
    // =============================================================

    uint256[47] private __gap;
}