// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

import "./interfaces/IRevvFiGovernance.sol";
import "./interfaces/ICreatorVestingVault.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/IRewardsDistributor.sol";

contract RevvFiBootstrapper is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_LOCK_DURATION = 30 days;
    uint256 public constant MAX_LOCK_DURATION = 730 days;

    // =============================================================
    // Core Config
    // =============================================================

    address public creator;
    address public revvToken;
    address public weth;
    address public uniswapRouter;
    address public platformFeeRecipient;

    // =============================================================
    // Token Allocation
    // =============================================================

    uint256 public liquidityAllocation;
    uint256 public creatorVestingAmount;
    uint256 public treasuryAmount;
    uint256 public strategicReserveAmount;
    uint256 public rewardsAmount;

    // =============================================================
    // Timings
    // =============================================================

    uint256 public raiseEndTime;
    uint256 public lockDuration;
    uint256 public creatorCliffDuration;
    uint256 public creatorVestingDuration;

    // =============================================================
    // Raise Targets
    // =============================================================

    uint256 public targetLiquidityETH;
    uint256 public hardCapETH;

    uint256 public keeperReward;

    // =============================================================
    // Modules
    // =============================================================

    address public creatorVestingVault;
    address public treasuryVault;
    address public strategicReserveVault;
    address public rewardsDistributor;
    address public governanceModule;

    // =============================================================
    // LP Shares
    // =============================================================

    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalDepositedETH;

    // =============================================================
    // Status
    // =============================================================

    bool public launched;
    bool public failed;

    mapping(address => bool) public refundClaimed;

    // =============================================================
    // LP Tokens
    // =============================================================

    address public uniswapPair;
    uint256 public uniLPTokenAmount;

    uint256 public maturityTime;

    // =============================================================
    // Events
    // =============================================================

    event Deposited(address indexed user, uint256 amount);
    event LaunchExecuted(
        uint256 totalETH,
        uint256 lpMinted,
        address pair,
        uint256 maturityTime
    );
    event Refunded(address indexed user, uint256 amount);
    event AssetsWithdrawn(
        address indexed user,
        uint256 shareBurned,
        uint256 ethOut,
        uint256 tokenOut
    );

    event CreatorVestingVaultSet(address vault);
    event TreasuryVaultSet(address vault);
    event StrategicReserveVaultSet(address vault);
    event RewardsDistributorSet(address distributor);
    event GovernanceModuleSet(address governance);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyLaunchPhase() {
        require(!launched && !failed, "not launch phase");
        require(block.timestamp <= raiseEndTime, "raise ended");
        _;
    }

    modifier afterLaunch() {
        require(launched, "not launched");
        _;
    }

    // =============================================================
    // Initializer
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
        uint256 _keeperReward
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        require(_creator != address(0), "zero creator");
        require(_revvToken != address(0), "zero token");
        require(_weth != address(0), "zero weth");
        require(_uniswapRouter != address(0), "zero router");
        require(_platformFeeRecipient != address(0), "zero fee recipient");

        require(
            _lockDuration >= MIN_LOCK_DURATION &&
                _lockDuration <= MAX_LOCK_DURATION,
            "bad lock"
        );

        creator = _creator;
        revvToken = _revvToken;
        weth = _weth;
        uniswapRouter = _uniswapRouter;
        platformFeeRecipient = _platformFeeRecipient;

        liquidityAllocation = _liquidityAllocation;
        creatorVestingAmount = _creatorVestingAmount;
        treasuryAmount = _treasuryAmount;
        strategicReserveAmount = _strategicReserveAmount;
        rewardsAmount = _rewardsAmount;

        targetLiquidityETH = _targetLiquidityETH;
        hardCapETH = _hardCapETH;

        raiseEndTime = block.timestamp + _raiseWindowDuration;
        lockDuration = _lockDuration;

        creatorCliffDuration = _creatorCliffDuration;
        creatorVestingDuration = _creatorVestingDuration;

        keeperReward = _keeperReward;

        _transferOwnership(_creator);

        IERC20(revvToken).approve(uniswapRouter, type(uint256).max);
        IERC20(weth).approve(uniswapRouter, type(uint256).max);
    }

    // =============================================================
    // Module Wiring (Owner = Creator)
    // =============================================================

    function setCreatorVestingVault(address vault) external onlyOwner {
        require(vault != address(0), "zero addr");
        creatorVestingVault = vault;
        emit CreatorVestingVaultSet(vault);
    }

    function setTreasuryVault(address vault) external onlyOwner {
        require(vault != address(0), "zero addr");
        treasuryVault = vault;
        emit TreasuryVaultSet(vault);
    }

    function setStrategicReserveVault(address vault) external onlyOwner {
        require(vault != address(0), "zero addr");
        strategicReserveVault = vault;
        emit StrategicReserveVaultSet(vault);
    }

    function setRewardsDistributor(address distributor) external onlyOwner {
        require(distributor != address(0), "zero addr");
        rewardsDistributor = distributor;
        emit RewardsDistributorSet(distributor);
    }

    function setGovernanceModule(address governance) external onlyOwner {
        require(governance != address(0), "zero addr");
        governanceModule = governance;
        emit GovernanceModuleSet(governance);
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
        require(msg.value > 0, "zero deposit");

        if (hardCapETH > 0) {
            require(
                totalDepositedETH + msg.value <= hardCapETH,
                "hardcap exceeded"
            );
        }

        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalDepositedETH += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    // =============================================================
    // Launch
    // =============================================================

    function launch() external nonReentrant onlyLaunchPhase {
        require(totalDepositedETH >= targetLiquidityETH, "target not met");

        maturityTime = raiseEndTime + lockDuration;

        _transferToVaults();
        _addLiquidity();

        launched = true;

        emit LaunchExecuted(
            totalDepositedETH,
            uniLPTokenAmount,
            uniswapPair,
            maturityTime
        );
    }

    // =============================================================
    // Fail Raise + Refunds
    // =============================================================

    function markFailed() external onlyLaunchPhase {
        require(block.timestamp > raiseEndTime, "raise active");
        require(totalDepositedETH < targetLiquidityETH, "target met");

        failed = true;
    }

    function claimRefund() external nonReentrant {
        require(failed, "not failed");
        require(!refundClaimed[msg.sender], "claimed");

        uint256 amount = shares[msg.sender];
        require(amount > 0, "no shares");

        refundClaimed[msg.sender] = true;
        shares[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");

        emit Refunded(msg.sender, amount);
    }

    // =============================================================
    // Internal: Add Liquidity
    // =============================================================

    function _addLiquidity() internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        (, , uint256 liquidity) = router.addLiquidityETH{
            value: totalDepositedETH
        }(
            revvToken,
            liquidityAllocation,
            0,
            0,
            address(this),
            block.timestamp + 300
        );

        uniLPTokenAmount = liquidity;

        address factory = router.factory();

        address pair = IUniswapV2Factory(factory).getPair(
            revvToken,
            weth
        );

        require(pair != address(0), "pair not created");

        uniswapPair = pair;
    }

    // =============================================================
    // Withdraw LP Assets After Lock
    // =============================================================

    function withdrawAsAssets(uint256 shareAmount)
        external
        nonReentrant
        afterLaunch
        whenNotPaused
    {
        require(block.timestamp >= maturityTime, "locked");
        require(
            shareAmount > 0 && shareAmount <= shares[msg.sender],
            "bad amount"
        );

        uint256 fraction = (shareAmount * PRECISION) / totalShares;
        uint256 lpToRemove = (fraction * uniLPTokenAmount) / PRECISION;

        (uint256 ethOut, uint256 tokenOut) = _removeLiquidity(lpToRemove);

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uniLPTokenAmount -= lpToRemove;

        if (governanceModule != address(0)) {
            IRevvFiGovernance(governanceModule).onSharesUpdated(
                msg.sender,
                shares[msg.sender]
            );
        }

        if (ethOut > 0) {
            (bool ok, ) = msg.sender.call{value: ethOut}("");
            require(ok, "eth failed");
        }

        if (tokenOut > 0) {
            IERC20(revvToken).safeTransfer(msg.sender, tokenOut);
        }

        emit AssetsWithdrawn(
            msg.sender,
            shareAmount,
            ethOut,
            tokenOut
        );
    }

    // =============================================================
    // Remove Liquidity
    // =============================================================

    function _removeLiquidity(uint256 lpAmount)
        internal
        returns (uint256 ethOut, uint256 tokenOut)
    {
        require(uniswapPair != address(0), "pair not set");

        IERC20(uniswapPair).approve(uniswapRouter, lpAmount);

        (tokenOut, ethOut) = IUniswapV2Router02(uniswapRouter)
            .removeLiquidityETH(
                revvToken,
                lpAmount,
                0,
                0,
                address(this),
                block.timestamp + 300
            );
    }

    // =============================================================
    // Transfer Reserved Allocations
    // =============================================================

    function _transferToVaults() internal {
        IERC20 token = IERC20(revvToken);

        if (
            creatorVestingAmount > 0 &&
            creatorVestingVault != address(0)
        ) {
            token.safeTransfer(
                creatorVestingVault,
                creatorVestingAmount
            );
        }

        if (treasuryAmount > 0 && treasuryVault != address(0)) {
            token.safeTransfer(treasuryVault, treasuryAmount);
        }

        if (
            strategicReserveAmount > 0 &&
            strategicReserveVault != address(0)
        ) {
            token.safeTransfer(
                strategicReserveVault,
                strategicReserveAmount
            );
        }

        if (
            rewardsAmount > 0 &&
            rewardsDistributor != address(0)
        ) {
            token.safeTransfer(
                rewardsDistributor,
                rewardsAmount
            );
        }
    }

    // =============================================================
    // Guardian / Creator Controls
    // =============================================================

    function emergencyPause() external onlyOwner {
        _pause();
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
    }

    // =============================================================
    // Views
    // =============================================================

    function getShareValueBps(
        address user
    ) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * 10000) / totalShares;
    }

    receive() external payable {}

    uint256[50] private __gap;
}