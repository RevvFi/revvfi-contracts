// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// =============================================================
// CreatorProfileRegistry
// =============================================================
contract CreatorProfileRegistry is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using Strings for uint256;

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // =============================================================
    // Custom Errors
    // =============================================================
    error InvalidTemplateId();
    error ZeroAddress();

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_REPUTATION_SCORE = 1000;
    uint256 public constant INITIAL_REPUTATION_SCORE = 500;

    uint256 public constant SUCCESSFUL_LAUNCH_WEIGHT = 100;
    uint256 public constant FAILED_LAUNCH_PENALTY = 50;
    uint256 public constant KYC_BONUS = 100;
    uint256 public constant SOCIAL_VERIFIED_BONUS = 50;

    // =============================================================
    // Structs
    // =============================================================
    struct CreatorProfile {
        string name;
        string website;
        string twitter;
        string github;
        string telegram;
        string discord;

        bool kycVerified;
        bool twitterVerified;
        bool githubVerified;

        uint256 successfulLaunches;
        uint256 failedLaunches;
        uint256 reputationScore;
        uint256 lastUpdateTime;

        bool isRegistered;
    }

    struct LaunchRecord {
        uint256 launchId;
        address bootstrapper;
        address token;
        uint256 createdAt;
        bool success;
        uint256 targetLiquidityETH;
        uint256 raisedETH;
    }

    struct TokenRecord {
        address token;
        string name;
        string symbol;
        uint256 launchId;
        uint256 deployedAt;
        address bootstrapper;
    }

    struct SocialVerification {
        string platform;
        string username;
        string proofHash;
        uint256 verifiedAt;
        bool verified;
    }

    // =============================================================
    // Storage
    // =============================================================
    mapping(address => CreatorProfile) public profiles;
    mapping(address => LaunchRecord[]) public creatorLaunches;
    mapping(address => TokenRecord[]) public creatorTokens;
    mapping(address => mapping(string => SocialVerification)) public socialVerifications;

    // Token address to creator mapping (for quick lookup)
    mapping(address => address) public tokenToCreator;

    mapping(address => bool) public blacklisted;
    mapping(address => string) public blacklistReason;

    uint256 public registrationFee;
    address public feeRecipient;
    address public factory;

    // =============================================================
    // Events
    // =============================================================
    event ProfileRegistered(address indexed creator, string name, uint256 reputationScore);

    event ReputationUpdated(address indexed creator, uint256 oldScore, uint256 newScore, string reason);

    event KYCVerified(address indexed creator, address indexed verifier);

    event Blacklisted(address indexed creator, string reason);
    event BlacklistRemoved(address indexed creator);

    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);

    event LaunchRecorded(
        address indexed creator,
        uint256 indexed launchId,
        address indexed bootstrapper,
        address token,
        uint256 targetLiquidityETH
    );

    event TokenDeployed(
        address indexed creator,
        address indexed token,
        string name,
        string symbol,
        uint256 indexed launchId,
        address bootstrapper
    );

    // =============================================================
    // Constructor Lock
    // =============================================================
    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initializer
    // =============================================================
    function initialize(address _factory, address _feeRecipient, uint256 _registrationFee) external initializer {
        __AccessControl_init();
        __Pausable_init();

        if (_factory == address(0)) revert InvalidTemplateId();
        if (_feeRecipient == address(0)) revert InvalidTemplateId();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);

        factory = _factory;
        feeRecipient = _feeRecipient;
        registrationFee = _registrationFee;
    }

    // =============================================================
    // Modifiers
    // =============================================================
    modifier onlyFactory() {
        if (msg.sender != factory) revert InvalidTemplateId();
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert InvalidTemplateId();
        _;
    }

    modifier onlyOracle() {
        if (!hasRole(ORACLE_ROLE, msg.sender)) revert InvalidTemplateId();
        _;
    }

    // =============================================================
    // Register
    // =============================================================
    function registerProfile(
        string calldata name,
        string calldata website,
        string calldata twitter,
        string calldata github,
        string calldata telegram,
        string calldata discord
    ) external payable whenNotPaused {
        if (profiles[msg.sender].isRegistered) revert InvalidTemplateId();
        if (bytes(name).length == 0) revert InvalidTemplateId();
        if (msg.value < registrationFee) revert InvalidTemplateId();

        if (registrationFee > 0) {
            (bool sent,) = feeRecipient.call{value: msg.value}("");
            if (!sent) revert InvalidTemplateId();
        }

        profiles[msg.sender] = CreatorProfile({
            name: name,
            website: website,
            twitter: twitter,
            github: github,
            telegram: telegram,
            discord: discord,
            kycVerified: false,
            twitterVerified: false,
            githubVerified: false,
            successfulLaunches: 0,
            failedLaunches: 0,
            reputationScore: INITIAL_REPUTATION_SCORE,
            lastUpdateTime: block.timestamp,
            isRegistered: true
        });

        emit ProfileRegistered(msg.sender, name, INITIAL_REPUTATION_SCORE);
    }

    // =============================================================
    // Reputation Logic
    // =============================================================
    function _updateReputation(address creator, int256 delta, string memory reason) internal {
        CreatorProfile storage p = profiles[creator];

        int256 newScore = int256(p.reputationScore) + delta;

        if (newScore < 0) newScore = 0;
        if (newScore > int256(MAX_REPUTATION_SCORE)) {
            newScore = int256(MAX_REPUTATION_SCORE);
        }

        uint256 old = p.reputationScore;
        p.reputationScore = uint256(newScore);
        p.lastUpdateTime = block.timestamp;

        emit ReputationUpdated(creator, old, p.reputationScore, reason);
    }

    function verifyKYC(address creator) external onlyOracle {
        if (!profiles[creator].isRegistered) revert InvalidTemplateId();
        if (profiles[creator].kycVerified) revert InvalidTemplateId();

        profiles[creator].kycVerified = true;

        _updateReputation(creator, int256(KYC_BONUS), "KYC verified");

        emit KYCVerified(creator, msg.sender);
    }

    // =============================================================
    // Launch & Token Tracking
    // =============================================================

    /**
     * @dev Records a new launch for a creator (called by factory)
     * @param creator Creator address
     * @param launchId Unique launch ID
     * @param bootstrapper Bootstrapper contract address
     * @param token Token contract address
     * @param targetLiquidityETH Target raise amount in ETH
     */
    function recordLaunch(
        address creator,
        uint256 launchId,
        address bootstrapper,
        address token,
        uint256 targetLiquidityETH
    ) external onlyFactory {
        if (!profiles[creator].isRegistered) revert InvalidTemplateId();
        if (blacklisted[creator]) revert InvalidTemplateId();

        LaunchRecord memory launch = LaunchRecord({
            launchId: launchId,
            bootstrapper: bootstrapper,
            token: token,
            createdAt: block.timestamp,
            success: false,
            targetLiquidityETH: targetLiquidityETH,
            raisedETH: 0
        });

        creatorLaunches[creator].push(launch);

        // Track token deployment
        TokenRecord memory tokenRec = TokenRecord({
            token: token,
            name: "",
            symbol: "",
            launchId: launchId,
            deployedAt: block.timestamp,
            bootstrapper: bootstrapper
        });

        creatorTokens[creator].push(tokenRec);
        tokenToCreator[token] = creator;

        emit LaunchRecorded(creator, launchId, bootstrapper, token, targetLiquidityETH);
    }

    /**
     * @dev Records launch success (called by factory)
     * @param creator Creator address
     * @param launchId Launch ID
     * @param raisedETH Amount raised in ETH
     */
    function recordLaunchSuccess(address creator, uint256 launchId, uint256 raisedETH) external onlyFactory {
        LaunchRecord[] storage launches = creatorLaunches[creator];
        for (uint256 i = 0; i < launches.length; i++) {
            if (launches[i].launchId == launchId) {
                launches[i].success = true;
                launches[i].raisedETH = raisedETH;
                profiles[creator].successfulLaunches++;
                _updateReputation(creator, int256(SUCCESSFUL_LAUNCH_WEIGHT), "Successful launch");
                break;
            }
        }
    }

    /**
     * @dev Records launch failure (called by factory)
     * @param creator Creator address
     * @param launchId Launch ID
     */
    function recordLaunchFailure(address creator, uint256 launchId) external onlyFactory {
        LaunchRecord[] storage launches = creatorLaunches[creator];
        for (uint256 i = 0; i < launches.length; i++) {
            if (launches[i].launchId == launchId) {
                profiles[creator].failedLaunches++;
                _updateReputation(creator, -int256(FAILED_LAUNCH_PENALTY), "Failed launch");
                break;
            }
        }
    }

    /**
     * @dev Gets all launches by a creator
     * @param creator Creator address
     * @return Array of launch records
     */
    function getCreatorLaunches(address creator) external view returns (LaunchRecord[] memory) {
        return creatorLaunches[creator];
    }

    /**
     * @dev Gets all tokens deployed by a creator
     * @param creator Creator address
     * @return Array of token records
     */
    function getCreatorTokens(address creator) external view returns (TokenRecord[] memory) {
        return creatorTokens[creator];
    }

    /**
     * @dev Gets creator for a specific token
     * @param token Token address
     * @return Creator address
     */
    function getTokenCreator(address token) external view returns (address) {
        return tokenToCreator[token];
    }

    /**
     * @dev Gets token count for a creator
     * @param creator Creator address
     * @return Number of tokens deployed
     */
    function getCreatorTokenCount(address creator) external view returns (uint256) {
        return creatorTokens[creator].length;
    }

    /**
     * @dev Gets launch count for a creator
     * @param creator Creator address
     * @return Number of launches
     */
    function getCreatorLaunchCount(address creator) external view returns (uint256) {
        return creatorLaunches[creator].length;
    }

    // =============================================================
    // Blacklist
    // =============================================================
    function blacklist(address creator, string calldata reason) external onlyGuardian {
        blacklisted[creator] = true;
        blacklistReason[creator] = reason;

        emit Blacklisted(creator, reason);
    }

    function removeBlacklist(address creator) external onlyGuardian {
        blacklisted[creator] = false;
        blacklistReason[creator] = "";

        emit BlacklistRemoved(creator);
    }

    // =============================================================
    // Admin
    // =============================================================
    function setRegistrationFee(uint256 newFee) external onlyGuardian {
        emit RegistrationFeeUpdated(registrationFee, newFee);
        registrationFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyGuardian {
        if (newRecipient == address(0)) revert InvalidTemplateId();
        feeRecipient = newRecipient;
    }

    function setFactory(address newFactory) external onlyGuardian {
        if (newFactory == address(0)) revert InvalidTemplateId();
        factory = newFactory;
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }
}
