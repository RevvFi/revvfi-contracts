// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/Create2Upgradeable.sol";

import "./interfaces/ITokenTemplateFactory.sol";
import "./interfaces/IPopularityOracle.sol";
import "./interfaces/ICreatorProfileRegistry.sol";
import "./interfaces/ICentralAuthority.sol";
import "./RevvFiBootstrapper.sol";
import "./CreatorVestingVault.sol";
import "./TreasuryVault.sol";
import "./StrategicReserveVault.sol";
import "./RewardDistributor.sol";
import "./RevvFiGovernance.sol";

/**
 * @title RevvFiFactory
 * @notice Deploys complete launch ecosystems with all vaults
 * @dev Non-upgradeable implementation for vaults, factory uses Transparent Proxy pattern with UUPS upgradeability
 *
 * Key Responsibilities:
 * - Validates launch configuration parameters
 * - Deploys all required contracts for a token launch using CREATE2 for deterministic addresses
 * - Collects launch fees to prevent spam
 * - Maintains registry of all launches
 * - Routes role-based access control to CentralAuthority
 */
contract RevvFiFactory is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress(); // Thrown when an address parameter is zero
    error InvalidFee(); // Thrown when sent ETH amount doesn't match launchFee
    error FeeTransferFailed(); // Thrown when fee transfer to recipient fails
    error SupplyMismatch(); // Thrown when token allocations don't sum to totalSupply
    error InvalidRaiseWindow(); // Thrown when raise window duration is out of bounds
    error InvalidLockDuration(); // Thrown when LP lock duration is out of bounds
    error InvalidCliffDuration(); // Thrown when cliff duration exceeds vesting duration
    error ZeroTargetLiquidity(); // Thrown when target liquidity is zero
    error HardCapLessThanTarget(); // Thrown when hard cap is less than target liquidity
    error ZeroLiquidityAllocation(); // Thrown when liquidity allocation is zero
    error LaunchFailed(); // Thrown when launch process fails
    error BootstrapperNotFound(); // Thrown when bootstrapper address doesn't exist
    error InvalidTemplateId(); // Thrown when template ID is invalid
    error DeploymentFailed(); // Thrown when contract deployment fails
    error Create2Failed(); // Thrown when CREATE2 deployment fails
    error InvalidTokenName(); // Thrown when token name is empty or too long
    error InvalidTokenSymbol(); // Thrown when token symbol is empty or too long
    error LaunchIdNotFound(); // Thrown when launch ID doesn't exist
    error UnauthorizedCaller(); // Thrown when caller lacks required role

    // =============================================================
    // Roles (Delegated to Central Authority)
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE"); // DAO governance role - controls protocol parameters
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // Guardian role - emergency operations
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE"); // Operations role - routine updates
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE"); // Upgrader role - contract upgrades
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE"); // Factory role - identifies factory contract

    // =============================================================
    // Constants (Updatable via governance)
    // =============================================================

    uint256 public launchFee; // Fee in ETH paid by creator to launch token (prevents spam)
    uint256 public keeperReward; // Reward paid to address that calls launch() (gas compensation)
    uint256 public minLockDuration; // Minimum LP lock duration in seconds (30 days default)
    uint256 public maxLockDuration; // Maximum LP lock duration in seconds (730 days/2 years default)
    uint256 public minRaiseWindow; // Minimum deposit window duration in seconds (7 days default)
    uint256 public maxRaiseWindow; // Maximum deposit window duration in seconds (90 days default)

    // =============================================================
    // Structs
    // =============================================================

    /**
     * @dev Configuration parameters for a new launch
     * @param tokenName Name of the token (e.g., "Bonk")
     * @param tokenSymbol Symbol of the token (e.g., "BONK")
     * @param totalSupply Total fixed supply minted at deployment
     * @param liquidityAllocation Tokens allocated to Uniswap liquidity pool
     * @param creatorVestingAmount Tokens allocated to creator with vesting schedule
     * @param treasuryAmount Tokens controlled by LP governance for operational expenses
     * @param strategicReserveAmount Tokens with stricter controls (higher threshold, quarterly limits)
     * @param rewardsAmount Tokens for community rewards distribution over time
     * @param raiseWindowDuration Duration LPs can deposit ETH (seconds)
     * @param targetLiquidityETH Minimum ETH required for launch success
     * @param hardCapETH Maximum ETH accepted (0 = no cap)
     * @param lockDuration Time LPs must wait after launch before withdrawal (seconds)
     * @param creatorCliffDuration Time creator must wait before any tokens unlock (seconds)
     * @param creatorVestingDuration Total time for creator tokens to linearly vest after cliff (seconds)
     * @param templateId Template identifier for token contract (bytes32 for flexibility)
     * @param tokenURI Metadata URI for the token (optional)
     */
    struct LaunchConfig {
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
        uint256 liquidityAllocation;
        uint256 creatorVestingAmount;
        uint256 treasuryAmount;
        uint256 strategicReserveAmount;
        uint256 rewardsAmount;
        uint256 raiseWindowDuration;
        uint256 targetLiquidityETH;
        uint256 hardCapETH;
        uint256 lockDuration;
        uint256 creatorCliffDuration;
        uint256 creatorVestingDuration;
        bytes32 templateId;
        string tokenURI;
    }

    /**
     * @dev Metadata stored for each launched token
     * @param launchId Unique identifier for this launch
     * @param creator Address of token creator
     * @param bootstrapper Address of RevvFiBootstrapper contract
     * @param createdAt Timestamp when launch was created
     * @param targetLiquidityETH Minimum ETH required (from config)
     * @param raiseEndTime Timestamp when deposit window closes
     * @param maturityTime Timestamp when LPs can withdraw (raiseEndTime + lockDuration)
     * @param status Current status: 0=Pending, 1=Launched, 2=Failed, 3=Completed
     */
    struct LaunchMetadata {
        uint256 launchId;
        address creator;
        address bootstrapper;
        uint256 createdAt;
        uint256 targetLiquidityETH;
        uint256 raiseEndTime;
        uint256 maturityTime;
        uint8 status;
    }

    // =============================================================
    // Storage
    // =============================================================

    uint256 public bootstrapperCount; // Total number of launches created
    mapping(uint256 => LaunchMetadata) public launches; // Launch ID -> metadata
    mapping(address => bool) public isDeployed; // Bootstrapper address -> exists flag
    mapping(address => uint256) public creatorNonce; // Creator address -> nonce for CREATE2 salt

    // External contracts
    address public tokenTemplateFactory; // TokenTemplateFactory contract address
    address public uniswapRouter; // Uniswap V2 router address
    address public weth; // WETH token address
    address public platformFeeRecipient; // Address receiving protocol fees
    address public creatorRegistry; // CreatorProfileRegistry for reputation tracking
    address public popularityOracle; // PopularityOracle for score calculation
    address public centralAuthority; // CentralAuthority for role management

    // Status constants
    uint8 public constant STATUS_PENDING = 0; // Launch created, awaiting deposits
    uint8 public constant STATUS_LAUNCHED = 1; // Launch successful, liquidity added
    uint8 public constant STATUS_FAILED = 2; // Launch failed (target not met)
    uint8 public constant STATUS_COMPLETED = 3; // Launch completed, all LPs exited

    // =============================================================
    // Events
    // =============================================================

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed bootstrapper,
        address indexed creator,
        uint256 targetLiquidityETH,
        uint256 raiseEndTime
    );

    event LaunchSucceeded(uint256 indexed launchId, address indexed bootstrapper, uint256 maturityTime);
    event LaunchFailed(uint256 indexed launchId, address indexed bootstrapper);
    event LaunchMetadataUpdated(uint256 indexed launchId, string field, uint256 value);

    event FeeRecipientUpdated(address indexed newRecipient);
    event UniswapRouterUpdated(address indexed newRouter);
    event WETHUpdated(address indexed newWeth);
    event TokenTemplateFactoryUpdated(address indexed newFactory);
    event CreatorRegistryUpdated(address indexed newRegistry);
    event PopularityOracleUpdated(address indexed newOracle);
    event CentralAuthorityUpdated(address indexed newAuthority);

    event FeesUpdated(uint256 newLaunchFee, uint256 newKeeperReward);
    event DurationBoundsUpdated(uint256 minLock, uint256 maxLock, uint256 minRaise, uint256 maxRaise);

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
        address _tokenTemplateFactory,
        address _uniswapRouter,
        address _weth,
        address _platformFeeRecipient,
        address _creatorRegistry,
        address _popularityOracle,
        address _centralAuthority
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        if (_tokenTemplateFactory == address(0)) revert ZeroAddress();
        if (_uniswapRouter == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        // Delegate role checks to Central Authority
        centralAuthority = _centralAuthority;

        // Grant self roles for initialization
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DAO_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(OPS_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        tokenTemplateFactory = _tokenTemplateFactory;
        uniswapRouter = _uniswapRouter;
        weth = _weth;
        platformFeeRecipient = _platformFeeRecipient;
        creatorRegistry = _creatorRegistry;
        popularityOracle = _popularityOracle;

        // Initialize configurable constants
        launchFee = 0.1 ether; // 0.1 ETH launch fee
        keeperReward = 0.01 ether; // 0.01 ETH keeper reward
        minLockDuration = 30 days; // Minimum 30 days lock
        maxLockDuration = 730 days; // Maximum 2 years lock
        minRaiseWindow = 7 days; // Minimum 7 days raise window
        maxRaiseWindow = 90 days; // Maximum 90 days raise window

        // Register factory with Central Authority
        ICentralAuthority(centralAuthority).setFactory(address(this));
    }

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

    modifier onlyOps() {
        if (!ICentralAuthority(centralAuthority).hasRole(OPS_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyUpgrader() {
        if (!ICentralAuthority(centralAuthority).hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    // =============================================================
    // Core Launch Logic
    // =============================================================

    /**
     * @dev Creates a new token launch with all associated contracts
     * @param config Launch configuration parameters
     * @return bootstrapperAddr Address of the deployed RevvFiBootstrapper
     *
     * Flow:
     * 1. Validate config and collect fee
     * 2. Generate deterministic salt using creator address + nonce + symbol
     * 3. Deploy token via TokenTemplateFactory (mints to predicted bootstrapper)
     * 4. Deploy all vault contracts (vesting, treasury, strategic reserve, rewards)
     * 5. Deploy governance module
     * 6. Deploy bootstrapper via CREATE2 with deterministic address
     * 7. Initialize bootstrapper with all addresses
     * 8. Initialize vaults with governance
     * 9. Transfer fee to recipient
     * 10. Record launch in registry
     */
    function createLaunch(LaunchConfig calldata config)
        external
        nonReentrant
        whenNotPaused
        returns (address bootstrapperAddr)
    {
        if (msg.value != launchFee) revert InvalidFee();

        _validateLaunchConfig(config);
        _validateTokenNameSymbol(config.tokenName, config.tokenSymbol);

        // Create deterministic salt using creator, nonce, and token symbol
        uint256 nonce = creatorNonce[msg.sender];
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, nonce, config.tokenSymbol));
        creatorNonce[msg.sender] = nonce + 1;

        // Precompute bootstrapper address using CREATE2
        address predictedBootstrapper =
            Create2Upgradeable.computeAddress(salt, keccak256(type(RevvFiBootstrapper).creationCode));

        // Deploy token - entire supply minted to predicted bootstrapper
        address token = ITokenTemplateFactory(tokenTemplateFactory)
            .deployToken(
                config.tokenName, config.tokenSymbol, config.totalSupply, config.templateId, predictedBootstrapper
            );

        if (token == address(0)) revert DeploymentFailed();

        // Deploy all vault contracts
        address creatorVestingVault = _deployCreatorVestingVault(); // Creator's vested tokens
        address treasuryVault = _deployTreasuryVault(token); // LP-governed treasury
        address strategicReserveVault = _deployStrategicReserveVault(token); // Stricter reserve
        address rewardsDistributor = _deployRewardsDistributor(token); // Community rewards

        // Deploy governance module for LP voting
        address governanceModule =
            _deployGovernanceModule(predictedBootstrapper, treasuryVault, strategicReserveVault, msg.sender);

        // Deploy bootstrapper using CREATE2
        bytes memory bytecode = type(RevvFiBootstrapper).creationCode;
        bootstrapperAddr = Create2Upgradeable.deploy(0, salt, bytecode);

        if (bootstrapperAddr != predictedBootstrapper) revert Create2Failed();
        if (bootstrapperAddr == address(0)) revert DeploymentFailed();

        // Record launch metadata
        bootstrapperCount++;
        uint256 launchId = bootstrapperCount;

        launches[launchId] = LaunchMetadata({
            launchId: launchId,
            creator: msg.sender,
            bootstrapper: bootstrapperAddr,
            createdAt: block.timestamp,
            targetLiquidityETH: config.targetLiquidityETH,
            raiseEndTime: block.timestamp + config.raiseWindowDuration,
            maturityTime: 0,
            status: STATUS_PENDING
        });

        isDeployed[bootstrapperAddr] = true;

        // Initialize bootstrapper with all parameters
        RevvFiBootstrapper(bootstrapperAddr)
            .initialize(
                msg.sender, // creator
                token, // revvToken
                weth, // weth
                uniswapRouter, // uniswapRouter
                config.liquidityAllocation,
                config.targetLiquidityETH,
                config.hardCapETH,
                config.raiseWindowDuration,
                config.lockDuration,
                config.creatorVestingAmount,
                config.treasuryAmount,
                config.strategicReserveAmount,
                config.rewardsAmount,
                config.creatorCliffDuration,
                config.creatorVestingDuration,
                platformFeeRecipient,
                keeperReward,
                creatorVestingVault,
                treasuryVault,
                strategicReserveVault,
                rewardsDistributor,
                governanceModule,
                launchId,
                centralAuthority
            );

        // Initialize vaults with governance module
        ITreasuryVault(treasuryVault).initializeGovernance(governanceModule);
        IStrategicReserveVault(strategicReserveVault).initializeGovernance(governanceModule);

        // Transfer fee after successful deployment (CE pattern)
        (bool sent,) = platformFeeRecipient.call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();

        // Record launch in creator registry for reputation tracking
        if (creatorRegistry != address(0)) {
            try ICreatorProfileRegistry(creatorRegistry)
                .recordLaunch(msg.sender, launchId, bootstrapperAddr, config.targetLiquidityETH) {}
                catch {}
        }

        emit LaunchCreated(
            launchId,
            bootstrapperAddr,
            msg.sender,
            config.targetLiquidityETH,
            block.timestamp + config.raiseWindowDuration
        );
    }

    // =============================================================
    // Internal Deployment Helpers
    // =============================================================

    /**
     * @dev Deploys CreatorVestingVault contract
     * @return address of deployed vault
     */
    function _deployCreatorVestingVault() internal returns (address) {
        return address(new CreatorVestingVault(address(this), platformFeeRecipient));
    }

    /**
     * @dev Deploys TreasuryVault contract (LP-governed)
     * @param token The token address being launched
     * @return address of deployed vault
     */
    function _deployTreasuryVault(address token) internal returns (address) {
        return address(new TreasuryVault(token, address(this), platformFeeRecipient));
    }

    /**
     * @dev Deploys StrategicReserveVault contract (stricter controls)
     * @param token The token address being launched
     * @return address of deployed vault
     */
    function _deployStrategicReserveVault(address token) internal returns (address) {
        return address(new StrategicReserveVault(token, address(this), platformFeeRecipient));
    }

    /**
     * @dev Deploys RewardsDistributor contract
     * @param token The token address being launched
     * @return address of deployed distributor
     */
    function _deployRewardsDistributor(address token) internal returns (address) {
        return address(new RewardsDistributor(token, address(this), platformFeeRecipient));
    }

    /**
     * @dev Deploys RevvFiGovernance contract
     * @param bootstrapper Bootstrapper address
     * @param treasuryVault Treasury vault address
     * @param strategicReserveVault Strategic reserve vault address
     * @param creator Creator address
     * @return address of deployed governance module
     */
    function _deployGovernanceModule(
        address bootstrapper,
        address treasuryVault,
        address strategicReserveVault,
        address creator
    ) internal returns (address) {
        return address(
            new RevvFiGovernance(
                bootstrapper, treasuryVault, strategicReserveVault, creator, address(this), centralAuthority
            )
        );
    }

    // =============================================================
    // Launch Status Updates (Called by Bootstrapper)
    // =============================================================

    /**
     * @dev Updates launch status to SUCCESS (called by bootstrapper)
     * @param launchId Launch ID
     * @param maturityTime Timestamp when LPs can withdraw
     */
    function updateLaunchSuccess(uint256 launchId, uint256 maturityTime) external {
        if (launches[launchId].bootstrapper != msg.sender) revert BootstrapperNotFound();

        launches[launchId].maturityTime = maturityTime;
        launches[launchId].status = STATUS_LAUNCHED;

        emit LaunchSucceeded(launchId, msg.sender, maturityTime);
    }

    /**
     * @dev Updates launch status to FAILED (called by bootstrapper)
     * @param launchId Launch ID
     */
    function updateLaunchFailure(uint256 launchId) external {
        if (launches[launchId].bootstrapper != msg.sender) revert BootstrapperNotFound();

        launches[launchId].status = STATUS_FAILED;

        emit LaunchFailed(launchId, msg.sender);
    }

    /**
     * @dev Callback when rewards distributor is initialized (called by bootstrapper)
     * @param launchId Launch ID
     */
    function updateLaunchRewardsInitialized(uint256 launchId) external {
        if (launches[launchId].bootstrapper != msg.sender) revert BootstrapperNotFound();
    }

    // =============================================================
    // Views
    // =============================================================

    function getLaunch(uint256 launchId) external view returns (LaunchMetadata memory) {
        if (launches[launchId].bootstrapper == address(0)) revert BootstrapperNotFound();
        return launches[launchId];
    }

    function getBootstrapperAddress(uint256 launchId) external view returns (address) {
        return launches[launchId].bootstrapper;
    }

    /**
     * @dev Gets live status from bootstrapper contract
     * @param bootstrapper Bootstrapper address
     * @return totalDepositedETH Total ETH deposited by LPs
     * @return totalShares Total shares outstanding
     * @return launched Whether launch has executed
     * @return failed Whether launch has failed
     * @return maturityTime Timestamp when withdrawals are allowed
     */
    function getLiveLaunchStatus(address bootstrapper)
        external
        view
        returns (uint256 totalDepositedETH, uint256 totalShares, bool launched, bool failed, uint256 maturityTime)
    {
        if (!isDeployed[bootstrapper]) {
            revert BootstrapperNotFound();
        }

        IRevvFiBootstrapper b = IRevvFiBootstrapper(bootstrapper);
        return (b.totalDepositedETH(), b.totalShares(), b.launched(), b.failed(), b.maturityTime());
    }

    // =============================================================
    // Guardian Functions
    // =============================================================

    function pauseLaunch(address bootstrapper) external onlyGuardian {
        if (!isDeployed[bootstrapper]) revert BootstrapperNotFound();
        IRevvFiBootstrapper(bootstrapper).emergencyPause();
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    // =============================================================
    // Admin Config (DAO and OPS roles via Central Authority)
    // =============================================================

    function setPlatformFeeRecipient(address newRecipient) external onlyDAO {
        if (newRecipient == address(0)) revert ZeroAddress();
        platformFeeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setUniswapRouter(address newRouter) external onlyOps {
        if (newRouter == address(0)) revert ZeroAddress();
        uniswapRouter = newRouter;
        emit UniswapRouterUpdated(newRouter);
    }

    function setWETH(address newWeth) external onlyOps {
        if (newWeth == address(0)) revert ZeroAddress();
        weth = newWeth;
        emit WETHUpdated(newWeth);
    }

    function setTokenTemplateFactory(address newFactory) external onlyDAO {
        if (newFactory == address(0)) revert ZeroAddress();
        tokenTemplateFactory = newFactory;
        emit TokenTemplateFactoryUpdated(newFactory);
    }

    function setCreatorRegistry(address newRegistry) external onlyOps {
        creatorRegistry = newRegistry;
        emit CreatorRegistryUpdated(newRegistry);
    }

    function setPopularityOracle(address newOracle) external onlyOps {
        popularityOracle = newOracle;
        emit PopularityOracleUpdated(newOracle);
    }

    function setCentralAuthority(address newAuthority) external onlyDAO {
        if (newAuthority == address(0)) revert ZeroAddress();
        centralAuthority = newAuthority;
        emit CentralAuthorityUpdated(newAuthority);
    }

    function setFees(uint256 newLaunchFee, uint256 newKeeperReward) external onlyDAO {
        launchFee = newLaunchFee;
        keeperReward = newKeeperReward;
        emit FeesUpdated(newLaunchFee, newKeeperReward);
    }

    function setDurationBounds(uint256 newMinLock, uint256 newMaxLock, uint256 newMinRaise, uint256 newMaxRaise)
        external
        onlyDAO
    {
        if (newMinLock > newMaxLock) revert InvalidLockDuration();
        if (newMinRaise > newMaxRaise) revert InvalidRaiseWindow();

        minLockDuration = newMinLock;
        maxLockDuration = newMaxLock;
        minRaiseWindow = newMinRaise;
        maxRaiseWindow = newMaxRaise;

        emit DurationBoundsUpdated(newMinLock, newMaxLock, newMinRaise, newMaxRaise);
    }

    // =============================================================
    // Internal Validation
    // =============================================================

    /**
     * @dev Validates launch configuration parameters
     */
    function _validateLaunchConfig(LaunchConfig calldata config) internal view {
        // Check that all token allocations sum to total supply
        uint256 totalAllocated = config.liquidityAllocation + config.creatorVestingAmount + config.treasuryAmount
            + config.strategicReserveAmount + config.rewardsAmount;

        if (totalAllocated != config.totalSupply) revert SupplyMismatch();

        // Validate raise window bounds
        if (config.raiseWindowDuration < minRaiseWindow || config.raiseWindowDuration > maxRaiseWindow) {
            revert InvalidRaiseWindow();
        }

        // Validate lock duration bounds
        if (config.lockDuration < minLockDuration || config.lockDuration > maxLockDuration) {
            revert InvalidLockDuration();
        }

        // Validate cliff is not longer than vesting period
        if (config.creatorCliffDuration > config.creatorVestingDuration) {
            revert InvalidCliffDuration();
        }

        // Validate target liquidity is positive
        if (config.targetLiquidityETH == 0) revert ZeroTargetLiquidity();

        // Validate hard cap is >= target if set
        if (config.hardCapETH > 0 && config.hardCapETH < config.targetLiquidityETH) {
            revert HardCapLessThanTarget();
        }

        // Validate at least some tokens are allocated to liquidity pool
        if (config.liquidityAllocation == 0) revert ZeroLiquidityAllocation();
    }

    /**
     * @dev Validates token name and symbol length
     */
    function _validateTokenNameSymbol(string memory name, string memory symbol) internal pure {
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidTokenName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) revert InvalidTokenSymbol();
    }

    // =============================================================
    // Storage Gap for Upgrades
    // =============================================================

    uint256[49] private __gap;
}
