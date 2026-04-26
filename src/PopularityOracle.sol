// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

// =============================================================
// PopularityOracle
// =============================================================
contract PopularityOracle is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    using StringsUpgradeable for uint256;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SCORE = 100;

    struct ScoreData {
        uint256 score;
        uint256 lastUpdateTime;
        bool exists;
    }

    mapping(address => ScoreData) public scores;
    mapping(address => uint256) public lastScoreRequest;

    address public factory;
    address public creatorRegistry;

    uint256 public cooldownPeriod;
    uint256 public minDepositorsForFullScore;

    event ScoreUpdated(
        address indexed bootstrapper,
        uint256 oldScore,
        uint256 newScore
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _factory,
        address _creatorRegistry,
        uint256 _cooldownPeriod,
        uint256 _minDepositors
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);

        factory = _factory;
        creatorRegistry = _creatorRegistry;
        cooldownPeriod = _cooldownPeriod;
        minDepositorsForFullScore = _minDepositors;
    }

    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "not guardian");
        _;
    }

    modifier onlyOracle() {
        require(hasRole(ORACLE_ROLE, msg.sender), "not oracle");
        _;
    }

    function updateScore(
        address bootstrapper,
        uint256 score
    ) external onlyOracle {
        require(score <= MAX_SCORE, "too high");

        uint256 old = scores[bootstrapper].exists
            ? scores[bootstrapper].score
            : 0;

        scores[bootstrapper] = ScoreData({
            score: score,
            lastUpdateTime: block.timestamp,
            exists: true
        });

        emit ScoreUpdated(bootstrapper, old, score);
    }

    function calculateScore(
        address bootstrapper
    ) external view returns (uint256) {
        if (!scores[bootstrapper].exists) return 0;
        return scores[bootstrapper].score;
    }

    function setCooldownPeriod(uint256 newPeriod) external onlyGuardian {
        cooldownPeriod = newPeriod;
    }

    function setFactory(address newFactory) external onlyGuardian {
        factory = newFactory;
    }

    function setCreatorRegistry(address newRegistry) external onlyGuardian {
        creatorRegistry = newRegistry;
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }
}