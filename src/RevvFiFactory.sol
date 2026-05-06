// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/Create2Upgradeable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// Keep only interface imports
import "./interfaces/ITokenTemplateFactory.sol";
import "./interfaces/IPopularityOracle.sol";
import "./interfaces/ICreatorProfileRegistry.sol";
import "./interfaces/ICentralAuthority.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/IRewardDistributor.sol";
import "./interfaces/ICreatorVestingVault.sol";
import "./interfaces/IRevvFiBootstrapper.sol";
import "./interfaces/IRevvFiGovernance.sol";
import "./interfaces/ITreasuryVault.sol";

// Import contract implementations for deployment
import "./CreatorVestingVault.sol";
import "./TreasuryVault.sol";
import "./StrategicReserveVault.sol";
import "./RewardDistributor.sol";
import "./RevvFiGovernance.sol";

/**
 * @title RevvFiFactory
 * @notice Deploys complete launch ecosystems with all vaults
 * @dev Uses Clone pattern for bootstrapper deployment (EIP-1167) instead of CREATE2 with full bytecode
 *
 * Key Responsibilities:
 * - Validates launch configuration parameters
 * - Deploys all required contracts for a token launch
 * - Uses Clones for gas-efficient bootstrapper deployment
 * - Collects launch fees to prevent spam
 * - Maintains registry of all launches
 * - Routes role-based access control to CentralAuthority
 */
contract RevvFiFactory is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error InvalidFee();
    error FeeTransferFailed();
    error SupplyMismatch();
    error InvalidRaiseWindow();
    error InvalidLockDuration();
    error InvalidCliffDuration();
    error ZeroTargetLiquidity();
    error HardCapLessThanTarget();
    error ZeroLiquidityAllocation();
    error LaunchFailed();
    error BootstrapperNotFound();
    error InvalidTemplateId();
    error DeploymentFailed();
    error Create2Failed();
    error InvalidTokenName();
    error InvalidTokenSymbol();
    error LaunchIdNotFound();
    error UnauthorizedCaller();
    error BootstrapperImplementationNotSet();

    // =============================================================
    // Roles (Delegated to Central Authority)
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    // =============================================================
    // Constants (Updatable via governance)
    // =============================================================

    uint256 public launchFee;
    uint256 public keeperReward;
    uint256 public minLockDuration;
    uint256 public maxLockDuration;
    uint256 public minRaiseWindow;
    uint256 public maxRaiseWindow;

    // =============================================================
    // Bootstrapper Implementation (for cloning)
    // =============================================================

    address public bootstrapperImplementation;

    // =============================================================
    // Structs
    // =============================================================

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

    uint256 public bootstrapperCount;
    mapping(uint256 => LaunchMetadata) public launches;
    mapping(address => bool) public isDeployed;
    mapping(address => uint256) public creatorNonce;

    // External contracts
    address public tokenTemplateFactory;
    address public uniswapRouter;
    address public weth;
    address public platformFeeRecipient;
    address public creatorRegistry;
    address public popularityOracle;
    address public centralAuthority;

    // Status constants
    uint8 public constant STATUS_PENDING = 0;
    uint8 public constant STATUS_LAUNCHED = 1;
    uint8 public constant STATUS_FAILED = 2;
    uint8 public constant STATUS_COMPLETED = 3;

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
    event BootstrapperImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event FeeRecipientUpdated(address indexed newRecipient);
    event UniswapRouterUpdated(address indexed newRouter);
    event WETHUpdated(address indexed newWeth);
    event TokenTemplateFactoryUpdated(address indexed newFactory);
    event CreatorRegistryUpdated(address indexed newRegistry);
    event PopularityOracleUpdated(address indexed newOracle);
    event CentralAuthorityUpdated(address indexed newAuthority);
    event LaunchFailedEvent(uint256 indexed launchId, address indexed bootstrapper);
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
        address _centralAuthority,
        address _bootstrapperImplementation,
        uint256 _launchFee,
        uint256 _keeperReward,
        uint256 _minLockDuration,
        uint256 _maxLockDuration,
        uint256 _minRaiseWindow,
        uint256 _maxRaiseWindow
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        if (_tokenTemplateFactory == address(0)) revert ZeroAddress();
        if (_uniswapRouter == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();
        if (_bootstrapperImplementation == address(0)) revert ZeroAddress();

        // Validate duration and fee parameters
        if (_minLockDuration == 0 || _maxLockDuration == 0) revert InvalidLockDuration();
        if (_minLockDuration > _maxLockDuration) revert InvalidLockDuration();
        if (_minRaiseWindow == 0 || _maxRaiseWindow == 0) revert InvalidRaiseWindow();
        if (_minRaiseWindow > _maxRaiseWindow) revert InvalidRaiseWindow();

        centralAuthority = _centralAuthority;

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
        bootstrapperImplementation = _bootstrapperImplementation;

        // Set fees and durations from parameters
        launchFee = _launchFee;
        keeperReward = _keeperReward;
        minLockDuration = _minLockDuration;
        maxLockDuration = _maxLockDuration;
        minRaiseWindow = _minRaiseWindow;
        maxRaiseWindow = _maxRaiseWindow;

        ICentralAuthority(centralAuthority).setFactory(address(this));
    }

    // =============================================================
    // Role Check Modifiers
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
    // Admin Functions
    // =============================================================

    function setBootstrapperImplementation(address newImplementation) external onlyDAO {
        if (newImplementation == address(0)) revert ZeroAddress();
        address oldImplementation = bootstrapperImplementation;
        bootstrapperImplementation = newImplementation;
        emit BootstrapperImplementationUpdated(oldImplementation, newImplementation);
    }

    // =============================================================
    // Core Launch Logic
    // =============================================================

    function createLaunch(LaunchConfig calldata config)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address bootstrapperAddr)
    {
        if (msg.value != launchFee) revert InvalidFee();
        if (bootstrapperImplementation == address(0)) revert BootstrapperImplementationNotSet();

        _validateLaunchConfig(config);
        _validateTokenNameSymbol(config.tokenName, config.tokenSymbol);

        // Generate salt for CREATE2 (for deterministic address)
        uint256 nonce = creatorNonce[msg.sender];
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, nonce, config.tokenSymbol));
        creatorNonce[msg.sender] = nonce + 1;

        // Precompute bootstrapper address using CREATE2 with minimal proxy bytecode
        bytes memory bytecode = _getMinimalProxyBytecode(bootstrapperImplementation);

        address predictedBootstrapper = Create2Upgradeable.computeAddress(salt, keccak256(bytecode));

        // Deploy bootstrapper FIRST using CREATE2 with minimal proxy
        // This ensures we have the correct address before minting tokens
        bootstrapperAddr = Create2Upgradeable.deploy(0, salt, bytecode);

        if (bootstrapperAddr != predictedBootstrapper) revert Create2Failed();
        if (bootstrapperAddr == address(0)) revert DeploymentFailed();

        // NOW deploy token with ACTUAL bootstrapper address (not predicted)
        address token = ITokenTemplateFactory(tokenTemplateFactory)
            .deployToken(
                config.tokenName, config.tokenSymbol, config.totalSupply, config.templateId, bootstrapperAddr
            );

        if (token == address(0)) revert DeploymentFailed();

        // Deploy all vault contracts
        address creatorVestingVault = _deployCreatorVestingVault();
        address treasuryVault = _deployTreasuryVault(token);
        address strategicReserveVault = _deployStrategicReserveVault(token);
        address rewardsDistributor = _deployRewardsDistributor(token);

        // Deploy governance module (now we have the actual bootstrapper address)
        address governanceModule =
            _deployGovernanceModule(bootstrapperAddr, treasuryVault, strategicReserveVault, msg.sender);

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

        // Initialize bootstrapper (clone)
        IRevvFiBootstrapper(bootstrapperAddr)
            .initialize(
                msg.sender,
                token,
                weth,
                uniswapRouter,
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

        // Register all deployed contracts with CentralAuthority for role-based access
        if (centralAuthority != address(0)) {
            ICentralAuthority(centralAuthority).authorizeContract(creatorVestingVault, ICentralAuthority(centralAuthority).VAULT_ROLE());
            ICentralAuthority(centralAuthority).authorizeContract(treasuryVault, ICentralAuthority(centralAuthority).VAULT_ROLE());
            ICentralAuthority(centralAuthority).authorizeContract(strategicReserveVault, ICentralAuthority(centralAuthority).VAULT_ROLE());
            ICentralAuthority(centralAuthority).authorizeContract(rewardsDistributor, ICentralAuthority(centralAuthority).REWARDS_DISTRIBUTOR_ROLE());
            ICentralAuthority(centralAuthority).authorizeContract(governanceModule, ICentralAuthority(centralAuthority).GOVERNANCE_MODULE_ROLE());
        }

        // Transfer fee after successful deployment (wrapped in try-catch to prevent launch failure)
        // If fee transfer fails, launch still succeeds (prevents economic DoS)
        bool feeSent;
        (feeSent,) = platformFeeRecipient.call{value: launchFee}("");
        // Note: We don't revert on fee transfer failure. This is intentional to ensure
        // that launch cannot be prevented by a malicious fee recipient contract.

        // Record launch in creator registry
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

    function _deployCreatorVestingVault() internal returns (address) {
        return address(new CreatorVestingVault(address(this), platformFeeRecipient, centralAuthority));
    }

    function _deployTreasuryVault(address token) internal returns (address) {
        return address(new TreasuryVault(token, address(this), platformFeeRecipient, centralAuthority));
    }

    function _deployStrategicReserveVault(address token) internal returns (address) {
        return address(new StrategicReserveVault(token, address(this), platformFeeRecipient, centralAuthority));
    }

    function _deployRewardsDistributor(address token) internal returns (address) {
        return address(new RewardsDistributor(token, address(this), platformFeeRecipient));
    }

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

    function updateLaunchSuccess(uint256 launchId, uint256 maturityTime) external {
        if (launches[launchId].bootstrapper != msg.sender) revert BootstrapperNotFound();
        launches[launchId].maturityTime = maturityTime;
        launches[launchId].status = STATUS_LAUNCHED;
        emit LaunchSucceeded(launchId, msg.sender, maturityTime);
    }

    function updateLaunchFailure(uint256 launchId) external {
        if (launches[launchId].bootstrapper != msg.sender) revert BootstrapperNotFound();
        launches[launchId].status = STATUS_FAILED;
        emit LaunchFailedEvent(launchId, msg.sender);
    }

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
    // Admin Config
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
        // Validate fee bounds to prevent economic DoS
        if (newLaunchFee > 10 ether) revert InvalidFee();
        if (newKeeperReward > 1 ether) revert InvalidFee();
        
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

    function _validateLaunchConfig(LaunchConfig calldata config) internal view {
        uint256 totalAllocated = config.liquidityAllocation + config.creatorVestingAmount + config.treasuryAmount
            + config.strategicReserveAmount + config.rewardsAmount;

        if (totalAllocated != config.totalSupply) revert SupplyMismatch();

        if (config.raiseWindowDuration < minRaiseWindow || config.raiseWindowDuration > maxRaiseWindow) {
            revert InvalidRaiseWindow();
        }

        if (config.lockDuration < minLockDuration || config.lockDuration > maxLockDuration) {
            revert InvalidLockDuration();
        }

        if (config.creatorCliffDuration > config.creatorVestingDuration) {
            revert InvalidCliffDuration();
        }

        if (config.targetLiquidityETH == 0) revert ZeroTargetLiquidity();

        if (config.hardCapETH > 0 && config.hardCapETH < config.targetLiquidityETH) {
            revert HardCapLessThanTarget();
        }

        if (config.liquidityAllocation == 0) revert ZeroLiquidityAllocation();
    }

    function _validateTokenNameSymbol(string memory name, string memory symbol) internal pure {
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidTokenName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) revert InvalidTokenSymbol();
    }

    /**
     * @dev Returns the bytecode for an ERC-1167 minimal proxy pointing to implementation
     */
    function _getMinimalProxyBytecode(address implementation) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    // =============================================================
    // Storage Gap for Upgrades
    // =============================================================

    uint256[48] private __gap;
}
