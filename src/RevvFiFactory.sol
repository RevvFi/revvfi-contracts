// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/Create2Upgradeable.sol";

import "./interfaces/ITokenTemplateFactory.sol";
import "./interfaces/IPopularityOracle.sol";
import "./interfaces/IRevvFiBootstrapper.sol";

/**
 * @title RevvFiFactory
 * @notice Transparent Proxy compatible version
 */
contract RevvFiFactory is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    // =============================================================
    // Roles
    // =============================================================

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant LAUNCH_FEE = 0.1 ether;
    uint256 public constant KEEPER_REWARD = 0.01 ether;

    uint256 public constant MIN_LOCK_DURATION = 30 days;
    uint256 public constant MAX_LOCK_DURATION = 730 days;

    uint256 public constant MIN_RAISE_WINDOW = 7 days;
    uint256 public constant MAX_RAISE_WINDOW = 90 days;

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
        uint8 templateId;
        string tokenURI;
    }

    struct LaunchMetadata {
        uint256 launchId;
        address creator;
        uint256 createdAt;
        bool active;
        uint256 targetLiquidityETH;
        uint256 totalDepositedETH;
        uint256 raiseEndTime;
        uint256 maturityTime;
        bool launched;
        bool failed;
    }

    // =============================================================
    // Storage
    // =============================================================

    uint256 public bootstrapperCount;

    mapping(uint256 => address) public bootstrappers;
    mapping(address => bool) public isDeployed;
    mapping(address => LaunchMetadata) public launchMetadata;

    address public tokenTemplateFactory;
    address public uniswapRouter;
    address public weth;
    address public platformFeeRecipient;
    address public creatorRegistry;
    address public popularityOracle;

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

    event LaunchPaused(address indexed bootstrapper, address indexed executor);

    event FeeRecipientUpdated(address indexed newRecipient);
    event UniswapRouterUpdated(address indexed newRouter);
    event WETHUpdated(address indexed newWeth);
    event TokenTemplateFactoryUpdated(address indexed newFactory);
    event CreatorRegistryUpdated(address indexed newRegistry);
    event PopularityOracleUpdated(address indexed newOracle);

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
        address _popularityOracle
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        require(_tokenTemplateFactory != address(0), "invalid token factory");
        require(_uniswapRouter != address(0), "invalid router");
        require(_weth != address(0), "invalid weth");
        require(_platformFeeRecipient != address(0), "invalid fee recipient");

        tokenTemplateFactory = _tokenTemplateFactory;
        uniswapRouter = _uniswapRouter;
        weth = _weth;
        platformFeeRecipient = _platformFeeRecipient;
        creatorRegistry = _creatorRegistry;
        popularityOracle = _popularityOracle;
    }

    // =============================================================
    // Core Launch Logic
    // =============================================================

    function createLaunch(
        LaunchConfig calldata config
    ) external payable whenNotPaused returns (address bootstrapper) {
        require(msg.value == LAUNCH_FEE, "invalid fee");

        _validateLaunchConfig(config);

        (bool sent, ) = platformFeeRecipient.call{value: LAUNCH_FEE}("");
        require(sent, "fee transfer failed");

        bytes32 salt = keccak256(
            abi.encodePacked(
                config.tokenName,
                config.tokenSymbol,
                config.totalSupply,
                block.timestamp,
                msg.sender
            )
        );

        address predictedBootstrapper = Create2Upgradeable.computeAddress(
            salt,
            keccak256(type(IRevvFiBootstrapper).creationCode)
        );

        address token = ITokenTemplateFactory(tokenTemplateFactory).deployToken(
            config.tokenName,
            config.tokenSymbol,
            config.totalSupply,
            config.templateId,
            predictedBootstrapper
        );

        bytes memory bytecode = abi.encodePacked(
            type(IRevvFiBootstrapper).creationCode,
            abi.encode(
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
                KEEPER_REWARD
            )
        );

        bootstrapper = Create2Upgradeable.deploy(0, salt, bytecode);

        bootstrapperCount++;

        bootstrappers[bootstrapperCount] = bootstrapper;
        isDeployed[bootstrapper] = true;

        launchMetadata[bootstrapper] = LaunchMetadata({
            launchId: bootstrapperCount,
            creator: msg.sender,
            createdAt: block.timestamp,
            active: true,
            targetLiquidityETH: config.targetLiquidityETH,
            totalDepositedETH: 0,
            raiseEndTime: block.timestamp + config.raiseWindowDuration,
            maturityTime: 0,
            launched: false,
            failed: false
        });

        emit LaunchCreated(
            bootstrapperCount,
            bootstrapper,
            msg.sender,
            config.targetLiquidityETH,
            block.timestamp + config.raiseWindowDuration
        );
    }

    // =============================================================
    // Views
    // =============================================================

    function getLaunch(
        uint256 launchId
    ) external view returns (LaunchMetadata memory) {
        address bootstrapper = bootstrappers[launchId];
        require(bootstrapper != address(0), "invalid id");
        return launchMetadata[bootstrapper];
    }

    function getBootstrapperAddress(
        uint256 launchId
    ) external view returns (address) {
        return bootstrappers[launchId];
    }

    // =============================================================
    // Guardian
    // =============================================================

    function pauseLaunch(address bootstrapper) external onlyRole(GUARDIAN_ROLE) {
        require(isDeployed[bootstrapper], "invalid bootstrapper");

        IRevvFiBootstrapper(bootstrapper).emergencyPause();

        emit LaunchPaused(bootstrapper, msg.sender);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // =============================================================
    // Admin Config
    // =============================================================

    function setPlatformFeeRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "zero addr");
        platformFeeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setUniswapRouter(
        address newRouter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRouter != address(0), "zero addr");
        uniswapRouter = newRouter;
        emit UniswapRouterUpdated(newRouter);
    }

    function setWETH(
        address newWeth
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newWeth != address(0), "zero addr");
        weth = newWeth;
        emit WETHUpdated(newWeth);
    }

    function setTokenTemplateFactory(
        address newFactory
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFactory != address(0), "zero addr");
        tokenTemplateFactory = newFactory;
        emit TokenTemplateFactoryUpdated(newFactory);
    }

    function setCreatorRegistry(
        address newRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        creatorRegistry = newRegistry;
        emit CreatorRegistryUpdated(newRegistry);
    }

    function setPopularityOracle(
        address newOracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        popularityOracle = newOracle;
        emit PopularityOracleUpdated(newOracle);
    }

    // =============================================================
    // Internal Validation
    // =============================================================

    function _validateLaunchConfig(
        LaunchConfig calldata config
    ) internal pure {
        uint256 totalAllocated =
            config.liquidityAllocation +
            config.creatorVestingAmount +
            config.treasuryAmount +
            config.strategicReserveAmount +
            config.rewardsAmount;

        require(totalAllocated == config.totalSupply, "supply mismatch");

        require(
            config.raiseWindowDuration >= MIN_RAISE_WINDOW &&
            config.raiseWindowDuration <= MAX_RAISE_WINDOW,
            "bad raise window"
        );

        require(
            config.lockDuration >= MIN_LOCK_DURATION &&
            config.lockDuration <= MAX_LOCK_DURATION,
            "bad lock duration"
        );

        require(
            config.creatorCliffDuration <= config.creatorVestingDuration,
            "cliff > vesting"
        );

        require(config.targetLiquidityETH > 0, "zero target");

        if (config.hardCapETH > 0) {
            require(
                config.hardCapETH >= config.targetLiquidityETH,
                "hardcap < target"
            );
        }

        require(config.liquidityAllocation > 0, "zero liquidity");
    }
}