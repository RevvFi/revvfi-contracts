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
 *
 * Key Responsibilities:
 * - Accept ETH deposits from LPs and mint internal shares (1:1 ratio)
 * - Track LP positions via share ledger (no separate ERC20 tokens)
 * - Create Uniswap V2 pool with deposited ETH and allocated tokens
 * - Hold Uniswap LP tokens on behalf of LPs (prevents early withdrawal)
 * - Handle refunds if target liquidity not reached
 * - Allow proportional withdrawals after maturity period
 * - Distribute keeper rewards to launch callers
 */
contract RevvFiBootstrapper is Initializable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress(); // Address parameter is zero
    error ZeroDeposit(); // Deposit amount is zero
    error HardCapExceeded(); // Deposit would exceed hard cap
    error TargetNotMet(); // Target liquidity not reached
    error AlreadyLaunched(); // Launch already executed
    error AlreadyFailed(); // Launch already marked as failed
    error RaiseNotEnded(); // Raise window still active
    error NotFailed(); // Launch not failed
    error RefundAlreadyClaimed(); // LP already claimed refund
    error NoShares(); // LP has no shares to refund
    error RefundFailed(); // ETH transfer for refund failed
    error WithdrawLocked(); // Withdrawal before maturity
    error InvalidShareAmount(); // Share amount is zero or exceeds balance
    error LiquidityAddFailed(); // Uniswap add liquidity failed
    error PairNotFound(); // Uniswap pair not created
    error UnauthorizedCaller(); // Caller lacks required role
    error VaultAlreadySet(); // Vault already configured
    error InsufficientETHForLiquidity(); // Not enough ETH after keeper reward
    error KeeperRewardFailed(); // Keeper reward transfer failed
    error VestingInitFailed(); // Creator vesting initialization failed
    error RewardsInitFailed(); // Rewards distributor initialization failed

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION = 1e18; // Precision for percentage calculations
    uint256 public constant DEADLINE_BUFFER = 300; // 5 minutes deadline buffer for Uniswap

    // =============================================================
    // Role Constants (for Central Authority)
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE"); // DAO governance - can rescue tokens
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // Guardian - emergency ops
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE"); // Operations - routine updates
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE"); // Factory - can pause/unpause
    bytes32 public constant BOOTSTRAPPER_ROLE = keccak256("BOOTSTRAPPER_ROLE"); // Self-identity

    // =============================================================
    // Immutable Core Config (Set Once in Initialize)
    // =============================================================

    address public creator; // Token creator address (receives vested tokens)
    address public revvToken; // The ERC20 token being launched
    address public weth; // WETH token address for pair
    address public uniswapRouter; // Uniswap V2 router address
    address public platformFeeRecipient; // Address receiving keeper rewards
    address public factory; // RevvFiFactory that deployed this contract
    address public centralAuthority; // CentralAuthority for role management
    uint256 public launchId; // Unique identifier for this launch (for factory callbacks)

    // =============================================================
    // Immutable Token Allocations
    // =============================================================

    uint256 public liquidityAllocation; // Tokens allocated to Uniswap liquidity pool
    uint256 public creatorVestingAmount; // Tokens allocated to creator (vested)
    uint256 public treasuryAmount; // Tokens allocated to LP-governed treasury
    uint256 public strategicReserveAmount; // Tokens allocated to strategic reserve (stricter controls)
    uint256 public rewardsAmount; // Tokens allocated to community rewards

    // =============================================================
    // Immutable Timings
    // =============================================================

    uint256 public raiseEndTime; // Timestamp when deposit window closes
    uint256 public lockDuration; // Duration LPs must wait after launch (seconds)
    uint256 public creatorCliffDuration; // Duration creator must wait before vesting starts (seconds)
    uint256 public creatorVestingDuration; // Total vesting period after cliff (seconds)

    // =============================================================
    // Immutable Raise Targets
    // =============================================================

    uint256 public targetLiquidityETH; // Minimum ETH required for successful launch
    uint256 public hardCapETH; // Maximum ETH accepted (0 = no cap)
    uint256 public keeperReward; // Reward paid to address that calls launch()

    // =============================================================
    // Immutable Vault Addresses
    // =============================================================

    address public creatorVestingVault; // Contract holding creator's vested tokens
    address public treasuryVault; // Contract holding LP-governed treasury
    address public strategicReserveVault; // Contract holding strategic reserve (stricter controls)
    address public rewardsDistributor; // Contract for community reward distribution
    address public governanceModule; // Contract handling LP voting

    // =============================================================
    // Mutable State
    // =============================================================

    // Share Ledger (Internal accounting - NO ERC20 tokens)
    mapping(address => uint256) public shares; // LP address -> share amount (1 share = 1 ETH deposited)
    uint256 public totalShares; // Total shares outstanding
    uint256 public totalDepositedETH; // Total ETH deposited by LPs

    bool public launched; // True after successful launch and liquidity added
    bool public failed; // True if launch failed (target not met)
    mapping(address => bool) public refundClaimed; // Tracks which LPs claimed refund

    address public uniswapPair; // Uniswap V2 pair address (BONK/WETH)
    uint256 public uniLPTokenAmount; // Amount of Uniswap LP tokens held
    uint256 public maturityTime; // Timestamp when LPs can withdraw (raiseEndTime + lockDuration)

    bool public rewardsInitialized; // Whether rewards distributor schedule is initialized

    // =============================================================
    // Events
    // =============================================================

    event Deposited(address indexed user, uint256 amount); // LP deposited ETH
    event LaunchExecuted(
        uint256 totalETH, uint256 lpMinted, address pair, uint256 maturityTime, address indexed caller
    ); // Launch successfully executed
    event Refunded(address indexed user, uint256 amount); // LP claimed refund
    event AssetsWithdrawn(address indexed user, uint256 shareBurned, uint256 ethOut, uint256 tokenOut); // LP withdrew assets
    event KeeperRewardPaid(address indexed keeper, uint256 amount); // Keeper reward paid
    event RewardsDistributorInitialized(address indexed distributor, uint256 startTime, uint256 endTime); // Rewards schedule set

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

    /**
     * @dev Requires launch to be in deposit phase (not launched, not failed, within raise window)
     */
    modifier onlyLaunchPhase() {
        if (launched) revert AlreadyLaunched();
        if (failed) revert AlreadyFailed();
        if (block.timestamp > raiseEndTime) revert RaiseNotEnded();
        _;
    }

    /**
     * @dev Requires launch to have successfully executed
     */
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

    /**
     * @dev Initializes the bootstrapper with all immutable parameters
     * @param _creator Token creator address
     * @param _revvToken The ERC20 token being launched
     * @param _weth WETH address
     * @param _uniswapRouter Uniswap V2 router
     * @param _liquidityAllocation Tokens for liquidity pool
     * @param _targetLiquidityETH Minimum ETH required
     * @param _hardCapETH Maximum ETH accepted
     * @param _raiseWindowDuration Duration of deposit window
     * @param _lockDuration LP lock period after launch
     * @param _creatorVestingAmount Creator's token allocation
     * @param _treasuryAmount Treasury token allocation
     * @param _strategicReserveAmount Strategic reserve allocation
     * @param _rewardsAmount Community rewards allocation
     * @param _creatorCliffDuration Cliff period for creator
     * @param _creatorVestingDuration Vesting period for creator
     * @param _platformFeeRecipient Address for keeper rewards
     * @param _keeperReward Reward for launch caller
     * @param _creatorVestingVault Vesting vault address
     * @param _treasuryVault Treasury vault address
     * @param _strategicReserveVault Strategic reserve address
     * @param _rewardsDistributor Rewards distributor address
     * @param _governanceModule Governance module address
     * @param _launchId Unique launch identifier
     * @param _centralAuthority Central authority address
     */
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
        factory = msg.sender; // Factory is the creator of this contract
        launchId = _launchId;
        centralAuthority = _centralAuthority;

        // Set token allocations
        liquidityAllocation = _liquidityAllocation;
        creatorVestingAmount = _creatorVestingAmount;
        treasuryAmount = _treasuryAmount;
        strategicReserveAmount = _strategicReserveAmount;
        rewardsAmount = _rewardsAmount;

        // Set raise targets and timings
        targetLiquidityETH = _targetLiquidityETH;
        hardCapETH = _hardCapETH;
        raiseEndTime = block.timestamp + _raiseWindowDuration;
        lockDuration = _lockDuration;
        keeperReward = _keeperReward;

        // Set vesting parameters
        creatorCliffDuration = _creatorCliffDuration;
        creatorVestingDuration = _creatorVestingDuration;

        // Set vault addresses (immutable - cannot change after deployment)
        creatorVestingVault = _creatorVestingVault;
        treasuryVault = _treasuryVault;
        strategicReserveVault = _strategicReserveVault;
        rewardsDistributor = _rewardsDistributor;
        governanceModule = _governanceModule;

        rewardsInitialized = false;

        // Safe approve for Uniswap router
        _safeApprove(revvToken, uniswapRouter, type(uint256).max);
        _safeApprove(weth, uniswapRouter, type(uint256).max);

        // Approve CreatorVestingVault to pull creator vesting tokens
        if (creatorVestingVault != address(0) && _creatorVestingAmount > 0) {
            _safeApprove(revvToken, creatorVestingVault, _creatorVestingAmount);
        }

        // Register this bootstrapper with Central Authority
        ICentralAuthority(centralAuthority).authorizeContract(address(this), BOOTSTRAPPER_ROLE);
    }

    // =============================================================
    // Safe Approval Helper
    // =============================================================

    /**
     * @dev Safely approves a spender for a token amount (resets to zero first)
     * Required for tokens that require approval reset (like USDT)
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amount);
    }

    // =============================================================
    // Deposit ETH
    // =============================================================

    /**
     * @dev LP deposits ETH in exchange for internal shares (1:1 ratio)
     * Shares represent proportional claim on future liquidity + fees
     */
    function depositETH() external payable nonReentrant whenNotPaused onlyLaunchPhase {
        if (msg.value == 0) revert ZeroDeposit();

        // Enforce hard cap if set
        if (hardCapETH > 0) {
            if (totalDepositedETH + msg.value > hardCapETH) revert HardCapExceeded();
        }

        // Mint shares 1:1 with ETH deposited
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalDepositedETH += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    // =============================================================
    // Launch - Permissionless
    // =============================================================

    /**
     * @dev Executes the launch - adds liquidity, transfers tokens to vaults
     * Anyone can call this once target liquidity is met
     */
    function launch() external nonReentrant onlyLaunchPhase {
        if (totalDepositedETH < targetLiquidityETH) revert TargetNotMet();

        // Reserve keeper reward BEFORE adding liquidity
        uint256 ethForLiquidity = totalDepositedETH;
        if (keeperReward > 0) {
            if (totalDepositedETH <= keeperReward) revert InsufficientETHForLiquidity();
            ethForLiquidity = totalDepositedETH - keeperReward;
        }

        maturityTime = raiseEndTime + lockDuration; // Set maturity timestamp

        // Initialize creator vesting schedule FIRST (while bootstrapper has tokens)
        _initializeVestingVault();

        // Transfer remaining tokens to other vaults
        _transferToVaults();

        // Initialize rewards distributor schedule
        _initializeRewardsDistributor();

        // Add liquidity to Uniswap with remaining ETH
        _addLiquidityWithAmount(ethForLiquidity);

        launched = true;

        // Pay keeper reward to caller (msg.sender, not platformFeeRecipient)
        if (keeperReward > 0) {
            (bool sent,) = msg.sender.call{value: keeperReward}("");
            if (!sent) revert KeeperRewardFailed();
            emit KeeperRewardPaid(msg.sender, keeperReward);
        }

        // Notify factory of successful launch
        _notifyFactorySuccess();

        emit LaunchExecuted(totalDepositedETH, uniLPTokenAmount, uniswapPair, maturityTime, msg.sender);
    }

    // =============================================================
    // Mark Failed & Refunds
    // =============================================================

    /**
     * @dev Marks the launch as failed (anyone can call after raiseEndTime if target not met)
     */
    function markFailed() external nonReentrant onlyLaunchPhase {
        if (block.timestamp <= raiseEndTime) revert RaiseNotEnded();
        if (totalDepositedETH >= targetLiquidityETH) revert TargetNotMet();
        if (failed) revert AlreadyFailed();

        failed = true;
        _notifyFactoryFailure();
    }

    /**
     * @dev LP claims refund after launch failure
     * Returns original ETH amount proportional to shares held
     */
    function claimRefund() external nonReentrant {
        if (!failed) revert NotFailed();
        if (refundClaimed[msg.sender]) revert RefundAlreadyClaimed();

        uint256 amount = shares[msg.sender];
        if (amount == 0) revert NoShares();

        // Burn shares and transfer ETH
        refundClaimed[msg.sender] = true;
        shares[msg.sender] = 0;
        totalShares -= amount;
        totalDepositedETH -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit Refunded(msg.sender, amount);
    }

    // =============================================================
    // Withdrawals After Maturity
    // =============================================================

    /**
     * @dev LP withdraws proportional ETH + tokens after maturity
     * @param shareAmount Amount of shares to burn
     * Returns both ETH and tokens from the Uniswap pool
     * Requires minimum share amount to prevent rounding dust
     */
    function withdrawAsAssets(uint256 shareAmount) external nonReentrant afterLaunch whenNotPaused {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (shareAmount == 0 || shareAmount > shares[msg.sender]) revert InvalidShareAmount();

        if (totalShares == 0) revert InvalidShareAmount();

        // Calculate LP's proportional share of Uniswap LP tokens
        uint256 fraction = (shareAmount * PRECISION) / totalShares;
        uint256 lpToRemove = (fraction * uniLPTokenAmount) / PRECISION;

        // Ensure we're removing at least 1 LP token (prevents dust/rounding attacks)
        if (lpToRemove == 0) revert InvalidShareAmount();

        // Remove liquidity from Uniswap
        (uint256 ethOut, uint256 tokenOut) = _removeLiquidity(lpToRemove);

        // Update state before transfers (Checks-Effects pattern)
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uniLPTokenAmount -= lpToRemove;

        // Notify governance of share update for voting power
        if (governanceModule != address(0)) {
            try IRevvFiGovernance(governanceModule).onSharesUpdated(msg.sender, shares[msg.sender]) {} catch {}
        }

        // Transfer ETH to LP
        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert RefundFailed();
        }

        // Transfer tokens to LP
        if (tokenOut > 0) {
            IERC20(revvToken).safeTransfer(msg.sender, tokenOut);
        }

        emit AssetsWithdrawn(msg.sender, shareAmount, ethOut, tokenOut);
    }

    // =============================================================
    // Emergency Token Rescue (DAO only after maturity)
    // =============================================================

    /**
     * @dev Rescues tokens sent to this contract by mistake (DAO only, after maturity)
     * Cannot rescue locked revvTokens that belong to LPs
     */
    function rescueTokens(address token, uint256 amount, address recipient) external onlyDAO {
        if (block.timestamp < maturityTime) revert WithdrawLocked();
        if (recipient == address(0)) revert ZeroAddress();

        // Prevent rescuing the main token if it's still locked
        if (token == revvToken) {
            uint256 lockedAmount = IERC20(revvToken).balanceOf(address(this));
            if (amount > lockedAmount) revert InvalidShareAmount();
        }

        IERC20(token).safeTransfer(recipient, amount);
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    /**
     * @dev Adds liquidity to Uniswap V2 with specified ETH amount
     * Includes slippage protection with 5% minimum amounts
     */
    function _addLiquidityWithAmount(uint256 ethAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        // Create pair if it doesn't exist
        _createLPPair();

        // Calculate minimum amounts with 5% slippage tolerance
        // minTokenAmount = 95% of liquidityAllocation
        // minETHAmount = 95% of ethAmount
        uint256 minTokenAmount = (liquidityAllocation * 95) / 100;
        uint256 minETHAmount = (ethAmount * 95) / 100;

        // Add liquidity with correctly ordered tokens and slippage protection
        (,, uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            revvToken,
            liquidityAllocation,
            minTokenAmount,  // Require at least 95% of tokens
            minETHAmount,    // Require at least 95% of ETH
            address(this),
            block.timestamp + DEADLINE_BUFFER
        );

        if (liquidity == 0) revert LiquidityAddFailed();
        uniLPTokenAmount = liquidity;

        // Get pair address for future removals
        address factoryAddr = router.factory();
        address pair = IUniswapV2Factory(factoryAddr).getPair(revvToken, weth);

        if (pair == address(0)) revert PairNotFound();
        uniswapPair = pair;
    }

    /**
     * @dev Creates Uniswap V2 pair if it doesn't exist
     */
    function _createLPPair() internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address factoryAddr = router.factory();
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(factoryAddr);

        // Check if pair already exists
        address existingPair = uniswapFactory.getPair(revvToken, weth);
        
        if (existingPair == address(0)) {
            // Create new pair
            address newPair = uniswapFactory.createPair(revvToken, weth);
            if (newPair == address(0)) revert PairNotFound();
            uniswapPair = newPair;
        } else {
            uniswapPair = existingPair;
        }
    }

    /**
     * @dev Returns correctly ordered tokens for Uniswap (smaller address first)
     * @return token0 First token (smaller address)
     * @return token1 Second token (larger address)
     * @return amount0 Amount for token0
     * @return amount1 Amount for token1
     */
    function _getOrderedTokens()
        internal
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        // Order tokens by address value (smaller first)
        if (revvToken < weth) {
            token0 = revvToken;
            token1 = weth;
            amount0 = liquidityAllocation;
            amount1 = 0; // ETH amount handled separately by router
        } else {
            token0 = weth;
            token1 = revvToken;
            amount0 = 0; // ETH amount handled separately by router
            amount1 = liquidityAllocation;
        }
    }

    /**
     * @dev Removes liquidity from Uniswap and returns ETH + tokens
     */
    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 ethOut, uint256 tokenOut) {
        if (uniswapPair == address(0)) revert PairNotFound();

        IERC20(uniswapPair).approve(uniswapRouter, lpAmount);

        (tokenOut, ethOut) = IUniswapV2Router02(uniswapRouter)
            .removeLiquidityETH(revvToken, lpAmount, 0, 0, address(this), block.timestamp + DEADLINE_BUFFER);
    }

    /**
     * @dev Transfers allocated tokens to respective vaults
     */
    function _transferToVaults() internal {
        IERC20 token = IERC20(revvToken);

        // Transfer to Treasury Vault (LP-governed)
        if (treasuryAmount > 0 && treasuryVault != address(0)) {
            token.safeTransfer(treasuryVault, treasuryAmount);
        }

        // Transfer to Strategic Reserve Vault (stricter controls)
        if (strategicReserveAmount > 0 && strategicReserveVault != address(0)) {
            token.safeTransfer(strategicReserveVault, strategicReserveAmount);
        }

        // Transfer to Rewards Distributor
        if (rewardsAmount > 0 && rewardsDistributor != address(0)) {
            token.safeTransfer(rewardsDistributor, rewardsAmount);
        }

        // Transfer to Creator Vesting Vault (will be initialized separately)
        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            token.safeTransfer(creatorVestingVault, creatorVestingAmount);
        }
    }

    /**
     * @dev Initializes creator vesting schedule in the vesting vault
     */
    function _initializeVestingVault() internal {
        if (creatorVestingAmount > 0 && creatorVestingVault != address(0)) {
            try ICreatorVestingVault(creatorVestingVault)
                .initializeVesting(
                    revvToken,
                    creator,
                    creatorVestingAmount,
                    creatorCliffDuration,
                    creatorVestingDuration,
                    block.timestamp
                ) {
            // Success - vesting initialized
            }
            catch {
                revert VestingInitFailed();
            }
        }
    }

    /**
     * @dev Initializes rewards distributor schedule (only on successful launch)
     * Start time = now + lockDuration (rewards begin after LP lock period)
     */
    function _initializeRewardsDistributor() internal {
        if (rewardsAmount > 0 && rewardsDistributor != address(0) && !rewardsInitialized) {
            uint256 startTime = block.timestamp + lockDuration;
            uint256 endTime = startTime + creatorVestingDuration;

            try IRewardDistributor(rewardsDistributor).initializeSchedule(startTime, endTime, rewardsAmount) {
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

    /**
     * @dev Notifies factory of successful launch
     */
    function _notifyFactorySuccess() internal {
        if (factory != address(0)) {
            try IRevvFiFactory(factory).updateLaunchSuccess(launchId, maturityTime) {} catch {}
        }
    }

    /**
     * @dev Notifies factory of launch failure
     */
    function _notifyFactoryFailure() internal {
        if (factory != address(0)) {
            try IRevvFiFactory(factory).updateLaunchFailure(launchId) {} catch {}
        }
    }

    // =============================================================
    // Guardian Controls (via Factory)
    // =============================================================

    /**
     * @dev Emergency pause - only callable by factory
     * Pauses deposits and withdrawals
     */
    function emergencyPause() external onlyFactory {
        _pause();
    }

    /**
     * @dev Emergency unpause - only callable by factory
     */
    function emergencyUnpause() external onlyFactory {
        _unpause();
    }

    // =============================================================
    // View Functions
    // =============================================================

    /**
     * @dev Returns LP's share as basis points (1/10000) of total
     */
    function getShareValueBps(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * 10000) / totalShares;
    }

    /**
     * @dev Returns voting power for an LP (1 share = 1 vote)
     */
    function getVotingPower(address lp) external view returns (uint256) {
        return shares[lp];
    }

    /**
     * @dev Returns launch ID for factory callbacks
     */
    function getLaunchId() external view returns (uint256) {
        return launchId;
    }

    // =============================================================
    // Receive ETH
    // =============================================================

    /**
     * @dev Receive ETH from Uniswap when removing liquidity
     */
    receive() external payable {}

    // =============================================================
    // Storage Gap for Upgrades
    // =============================================================

    uint256[47] private __gap;
}
