// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// =============================================================
// CreatorProfileRegistry
// =============================================================
contract CreatorProfileRegistry is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    using Strings for uint256;

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

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
        uint256 createdAt;
        bool success;
        uint256 targetLiquidityETH;
        uint256 raisedETH;
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
    mapping(address => mapping(string => SocialVerification))
        public socialVerifications;

    mapping(address => bool) public blacklisted;
    mapping(address => string) public blacklistReason;

    uint256 public registrationFee;
    address public feeRecipient;
    address public factory;

    // =============================================================
    // Events
    // =============================================================
    event ProfileRegistered(
        address indexed creator,
        string name,
        uint256 reputationScore
    );

    event ReputationUpdated(
        address indexed creator,
        uint256 oldScore,
        uint256 newScore,
        string reason
    );

    event KYCVerified(address indexed creator, address indexed verifier);

    event Blacklisted(address indexed creator, string reason);
    event BlacklistRemoved(address indexed creator);

    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);

    // =============================================================
    // Constructor Lock
    // =============================================================
    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initializer
    // =============================================================
    function initialize(
        address _factory,
        address _feeRecipient,
        uint256 _registrationFee
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();

        require(_factory != address(0), "zero factory");
        require(_feeRecipient != address(0), "zero feeRecipient");

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
        require(msg.sender == factory, "not factory");
        _;
    }

    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "not guardian");
        _;
    }

    modifier onlyOracle() {
        require(hasRole(ORACLE_ROLE, msg.sender), "not oracle");
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
        require(!profiles[msg.sender].isRegistered, "already registered");
        require(bytes(name).length > 0, "invalid name");
        require(msg.value >= registrationFee, "fee required");

        if (registrationFee > 0) {
            (bool sent, ) = feeRecipient.call{value: msg.value}("");
            require(sent, "fee transfer failed");
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
    function _updateReputation(
        address creator,
        int256 delta,
        string memory reason
    ) internal {
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
        require(profiles[creator].isRegistered, "not registered");
        require(!profiles[creator].kycVerified, "already verified");

        profiles[creator].kycVerified = true;

        _updateReputation(creator, int256(KYC_BONUS), "KYC verified");

        emit KYCVerified(creator, msg.sender);
    }

    // =============================================================
    // Blacklist
    // =============================================================
    function blacklist(
        address creator,
        string calldata reason
    ) external onlyGuardian {
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
        require(newRecipient != address(0), "zero");
        feeRecipient = newRecipient;
    }

    function setFactory(address newFactory) external onlyGuardian {
        require(newFactory != address(0), "zero");
        factory = newFactory;
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }
}