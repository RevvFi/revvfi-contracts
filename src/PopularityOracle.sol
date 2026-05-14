// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title PopularityOracle
 * @dev Calculates popularity score for each launch to help LPs evaluate opportunities.
 * @dev All role checks delegate to CentralAuthority
 */
contract PopularityOracle is Initializable, PausableUpgradeable {
    using StringsUpgradeable for uint256;

    // =============================================================
    // Role Constants (for CentralAuthority lookups)
    // =============================================================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // =============================================================
    // Custom Errors
    // =============================================================
    error ZeroAddress();
    error ScoreTooHigh();
    error UnauthorizedCaller();
    error CentralAuthorityNotSet();

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SCORE = 100;

    // =============================================================
    // Structs
    // =============================================================
    struct ScoreData {
        uint256 score;
        uint256 lastUpdateTime;
        uint256 depositVelocity;
        uint256 uniqueDepositors;
        uint256 socialScore;
        uint256 creatorReputation;
        uint256 timeToTargetScore;
        bool exists;
    }

    // =============================================================
    // Storage
    // =============================================================
    mapping(address => ScoreData) public scores;
    mapping(address => uint256) public lastScoreRequest;

    address public factory;
    address public creatorRegistry;
    address public centralAuthority;

    uint256 public cooldownPeriod;
    uint256 public minDepositorsForFullScore;

    // =============================================================
    // Events
    // =============================================================
    event ScoreUpdated(address indexed bootstrapper, uint256 oldScore, uint256 newScore, ScoreData details);
    event ScoreRequested(address indexed requester, address indexed bootstrapper);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MinDepositorsUpdated(uint256 oldMin, uint256 newMin);
    event CentralAuthorityUpdated(address indexed oldAuthority, address indexed newAuthority);

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
        address _factory,
        address _creatorRegistry,
        uint256 _cooldownPeriod,
        uint256 _minDepositors,
        address _centralAuthority
    ) external initializer {
        __Pausable_init();

        if (_factory == address(0)) revert ZeroAddress();
        if (_creatorRegistry == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        factory = _factory;
        creatorRegistry = _creatorRegistry;
        cooldownPeriod = _cooldownPeriod;
        minDepositorsForFullScore = _minDepositors;
        centralAuthority = _centralAuthority;
    }

    // =============================================================
    // Modifiers (using CentralAuthority)
    // =============================================================
    modifier onlyGuardian() {
        if (centralAuthority == address(0)) revert CentralAuthorityNotSet();
        if (!ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyOracle() {
        if (centralAuthority == address(0)) revert CentralAuthorityNotSet();
        if (!ICentralAuthority(centralAuthority).hasRole(ORACLE_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    // =============================================================
    // Score Management
    // =============================================================

    function updateScoreDetailed(
        address bootstrapper,
        uint256 score,
        uint256 depositVelocity,
        uint256 uniqueDepositors,
        uint256 socialScore,
        uint256 creatorReputation,
        uint256 timeToTargetScore
    ) external onlyOracle whenNotPaused {
        if (score > MAX_SCORE) revert ScoreTooHigh();

        uint256 old = scores[bootstrapper].exists ? scores[bootstrapper].score : 0;

        scores[bootstrapper] = ScoreData({
            score: score,
            lastUpdateTime: block.timestamp,
            depositVelocity: depositVelocity,
            uniqueDepositors: uniqueDepositors,
            socialScore: socialScore,
            creatorReputation: creatorReputation,
            timeToTargetScore: timeToTargetScore,
            exists: true
        });

        emit ScoreUpdated(bootstrapper, old, score, scores[bootstrapper]);
    }

    function updateScore(address bootstrapper, uint256 score) external onlyOracle whenNotPaused {
        if (score > MAX_SCORE) revert ScoreTooHigh();

        uint256 old = scores[bootstrapper].exists ? scores[bootstrapper].score : 0;

        scores[bootstrapper] = ScoreData({
            score: score,
            lastUpdateTime: block.timestamp,
            depositVelocity: 0,
            uniqueDepositors: 0,
            socialScore: 0,
            creatorReputation: 0,
            timeToTargetScore: 0,
            exists: true
        });

        emit ScoreUpdated(bootstrapper, old, score, scores[bootstrapper]);
    }

    function calculateScore(address bootstrapper) external view returns (uint256) {
        if (!scores[bootstrapper].exists) return 0;
        return scores[bootstrapper].score;
    }

    function getScoreDetails(address bootstrapper) external view returns (ScoreData memory) {
        return scores[bootstrapper];
    }

    function requestScoreUpdate(address bootstrapper) external whenNotPaused {
        if (bootstrapper == address(0)) revert ZeroAddress();

        if (cooldownPeriod > 0) {
            require(block.timestamp >= lastScoreRequest[msg.sender] + cooldownPeriod, "PopularityOracle: rate limited");
        }

        lastScoreRequest[msg.sender] = block.timestamp;
        emit ScoreRequested(msg.sender, bootstrapper);
    }

    function getBatchScores(address[] calldata bootstrappers) external view returns (uint256[] memory) {
        uint256[] memory results = new uint256[](bootstrappers.length);
        for (uint256 i = 0; i < bootstrappers.length; i++) {
            results[i] = scores[bootstrappers[i]].exists ? scores[bootstrappers[i]].score : 0;
        }
        return results;
    }

    // =============================================================
    // Admin Functions
    // =============================================================

    function setCooldownPeriod(uint256 newPeriod) external onlyGuardian {
        emit CooldownPeriodUpdated(cooldownPeriod, newPeriod);
        cooldownPeriod = newPeriod;
    }

    function setMinDepositorsForFullScore(uint256 newMin) external onlyGuardian {
        emit MinDepositorsUpdated(minDepositorsForFullScore, newMin);
        minDepositorsForFullScore = newMin;
    }

    function setFactory(address newFactory) external onlyGuardian {
        if (newFactory == address(0)) revert ZeroAddress();
        factory = newFactory;
    }

    function setCreatorRegistry(address newRegistry) external onlyGuardian {
        if (newRegistry == address(0)) revert ZeroAddress();
        creatorRegistry = newRegistry;
    }

    function setCentralAuthority(address newAuthority) external onlyGuardian {
        if (newAuthority == address(0)) revert ZeroAddress();
        emit CentralAuthorityUpdated(centralAuthority, newAuthority);
        centralAuthority = newAuthority;
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }
}
