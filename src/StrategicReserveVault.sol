// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title StrategicReserveVault
 * @dev Holds strategic reserve tokens with stricter governance controls.
 * @dev Features: 66% approval threshold, 14-day timelock, quarterly release limits based on initial balance.
 */
contract StrategicReserveVault is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error NotFactory();
    error NotGovernance();
    error NotAuthorized();
    error EmergencyPaused();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalCancelled();
    error InvalidAmount();
    error InsufficientBalance();
    error AlreadyInitialized();
    error QuarterlyLimitExceeded();
    error TimelockNotExpired();
    error QuorumNotMet();
    error ApprovalNotMet();
    error NoVotesCast();
    error AlreadyVoted();

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant APPROVAL_THRESHOLD = 6600; // 66%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TIMELOCK_DURATION = 14 days;
    uint256 public constant QUORUM_THRESHOLD = 3000; // 30%
    uint256 public constant QUARTERLY_RELEASE_LIMIT_BPS = 2500; // 25% per quarter
    uint256 public constant QUARTER_SECONDS = 90 days;

    // =============================================================
    // Structs
    // =============================================================

    struct ReleaseProposal {
        uint256 id;
        address proposer;
        uint256 amount;
        address recipient;
        uint256 createdAt;
        uint256 executedAt;
        bool executed;
        bool cancelled;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotingPowerAtProposal;
        uint256 quarterLimitSnapshot; // Store quarter limit at creation
        uint256 balanceSnapshot; // Store balance at creation
    }

    struct QuarterlyRelease {
        uint256 quarterStart;
        uint256 amountReleased;
        uint256 quarterLimit; // Store fixed limit for this quarter
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;
    address public immutable centralAuthority;

    address public governanceModule;

    uint256 public proposalCounter;
    mapping(uint256 => ReleaseProposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public totalReleased;
    mapping(uint256 => QuarterlyRelease) public quarterlyReleases;
    uint256 public quarterCounter;
    uint256 public initialBalance;

    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint256 amount,
        address indexed recipient,
        uint256 totalVotingPower,
        uint256 quarterLimitSnapshot,
        uint256 balanceSnapshot
    );
    event StrategicRelease(
        uint256 indexed proposalId, uint256 amount, address indexed recipient, address indexed executor
    );
    event StrategicProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event GovernanceModuleUpdated(address indexed oldModule, address indexed newModule);
    event StrategicPaused(address indexed executor);
    event StrategicUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);
    event QuarterlyReset(uint256 indexed quarterNumber, uint256 quarterStart, uint256 quarterLimit);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governanceModule) revert NotGovernance();
        _;
    }

    modifier onlyGuardian() {
        if (!ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }

    modifier whenNotPaused() {
        if (emergencyPaused) revert EmergencyPaused();
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        if (proposals[proposalId].createdAt == 0) revert ProposalNotFound();
        _;
    }

    modifier proposalNotExecuted(uint256 proposalId) {
        if (proposals[proposalId].executed) revert ProposalAlreadyExecuted();
        if (proposals[proposalId].cancelled) revert ProposalCancelled();
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor(address _token, address _factory, address _platformFeeRecipient, address _centralAuthority) {
        if (_token == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        token = IERC20(_token);
        factory = _factory;
        platformFeeRecipient = _platformFeeRecipient;
        centralAuthority = _centralAuthority;
        emergencyPaused = false;
        proposalCounter = 0;
        quarterCounter = 0;
        totalReleased = 0;
        initialBalance = 0;

        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _platformFeeRecipient);
    }

    // =============================================================
    // Initialization Functions
    // =============================================================

    function initializeGovernance(address _governanceModule) external onlyFactory {
        if (_governanceModule == address(0)) revert ZeroAddress();
        if (governanceModule != address(0)) revert AlreadyInitialized();

        governanceModule = _governanceModule;
        _grantRole(GOVERNANCE_ROLE, _governanceModule);

        initialBalance = token.balanceOf(address(this));
        _startNewQuarter();

        emit GovernanceModuleUpdated(address(0), _governanceModule);
    }

    // =============================================================
    // Proposal Functions
    // =============================================================

    function createProposal(address proposer, uint256 amount, address recipient, uint256 totalVotingPower)
        external
        onlyGovernance
        whenNotPaused
        returns (uint256 proposalId)
    {
        if (proposer == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 currentBalance = token.balanceOf(address(this));
        uint256 quarterLimit = getCurrentQuarterLimit();
        uint256 currentQuarterReleased = getCurrentQuarterReleased();

        if (amount > quarterLimit - currentQuarterReleased) revert QuarterlyLimitExceeded();
        if (amount > currentBalance) revert InsufficientBalance();

        proposalCounter++;

        proposals[proposalCounter] = ReleaseProposal({
            id: proposalCounter,
            proposer: proposer,
            amount: amount,
            recipient: recipient,
            createdAt: block.timestamp,
            executedAt: 0,
            executed: false,
            cancelled: false,
            forVotes: 0,
            againstVotes: 0,
            totalVotingPowerAtProposal: totalVotingPower,
            quarterLimitSnapshot: quarterLimit,
            balanceSnapshot: currentBalance
        });

        emit ProposalCreated(
            proposalCounter, proposer, amount, recipient, totalVotingPower, quarterLimit, currentBalance
        );
        return proposalCounter;
    }

    function castVote(uint256 proposalId, address voter, bool support, uint256 votingPower)
        external
        onlyGovernance
        proposalExists(proposalId)
        proposalNotExecuted(proposalId)
    {
        if (voter == address(0)) revert ZeroAddress();
        if (votingPower == 0) revert InvalidAmount();
        if (hasVoted[proposalId][voter]) revert AlreadyVoted();

        ReleaseProposal storage proposal = proposals[proposalId];
        hasVoted[proposalId][voter] = true;

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, voter, support, votingPower);
    }

    function executeProposal(uint256 proposalId)
        external
        nonReentrant
        whenNotPaused
        proposalExists(proposalId)
        proposalNotExecuted(proposalId)
    {
        ReleaseProposal storage proposal = proposals[proposalId];

        if (block.timestamp < proposal.createdAt + TIMELOCK_DURATION) revert TimelockNotExpired();

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes == 0) revert NoVotesCast();

        uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        if (approvalPercentage < APPROVAL_THRESHOLD) revert ApprovalNotMet();

        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        if (totalVotes < quorumThresholdAmount) revert QuorumNotMet();

        // Use stored snapshot values to validate, preventing dynamic manipulation
        uint256 currentQuarterReleased = getCurrentQuarterReleased();
        if (proposal.amount > proposal.quarterLimitSnapshot - currentQuarterReleased) revert QuarterlyLimitExceeded();

        uint256 amount = proposal.amount;
        address recipient = proposal.recipient;

        proposal.executed = true;
        proposal.executedAt = block.timestamp;
        totalReleased += amount;

        _updateQuarterlyRelease(amount);

        token.safeTransfer(recipient, amount);

        emit StrategicRelease(proposalId, amount, recipient, msg.sender);
    }

    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) proposalNotExecuted(proposalId) {
        ReleaseProposal storage proposal = proposals[proposalId];

        if (msg.sender != proposal.proposer && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender))
        {
            revert NotAuthorized();
        }

        if (block.timestamp >= proposal.createdAt + TIMELOCK_DURATION) revert TimelockNotExpired();

        proposal.cancelled = true;
        emit StrategicProposalCancelled(proposalId, msg.sender);
    }

    // =============================================================
    // Quarterly Limit Functions (Fixed - Based on Initial Balance)
    // =============================================================

    function _startNewQuarter() internal {
        uint256 quarterStart = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;
        uint256 quarterLimit = (initialBalance * QUARTERLY_RELEASE_LIMIT_BPS) / BASIS_POINTS;

        if (quarterCounter == 0 || quarterlyReleases[quarterCounter].quarterStart != quarterStart) {
            quarterCounter++;
            quarterlyReleases[quarterCounter] =
                QuarterlyRelease({quarterStart: quarterStart, amountReleased: 0, quarterLimit: quarterLimit});
            emit QuarterlyReset(quarterCounter, quarterStart, quarterLimit);
        }
    }

    function _updateQuarterlyRelease(uint256 amount) internal {
        uint256 currentQuarter = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;

        if (quarterCounter == 0 || quarterlyReleases[quarterCounter].quarterStart != currentQuarter) {
            _startNewQuarter();
        }

        quarterlyReleases[quarterCounter].amountReleased += amount;
    }

    function getCurrentQuarterLimit() public view returns (uint256) {
        if (quarterCounter == 0) {
            return (initialBalance * QUARTERLY_RELEASE_LIMIT_BPS) / BASIS_POINTS;
        }
        return quarterlyReleases[quarterCounter].quarterLimit;
    }

    function getCurrentQuarterReleased() public view returns (uint256) {
        uint256 currentQuarter = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;

        if (quarterCounter == 0) {
            return 0;
        }

        // Search for current quarter (quarters are stored sequentially)
        for (uint256 i = quarterCounter; i > 0; i--) {
            if (quarterlyReleases[i].quarterStart == currentQuarter) {
                return quarterlyReleases[i].amountReleased;
            }
        }
        return 0;
    }

    function getRemainingQuarterlyAllowance() public view returns (uint256) {
        uint256 limit = getCurrentQuarterLimit();
        uint256 released = getCurrentQuarterReleased();
        if (released >= limit) return 0;
        return limit - released;
    }

    function forceNewQuarter() external onlyGuardian {
        _startNewQuarter();
    }

    // =============================================================
    // Emergency Functions
    // =============================================================

    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit StrategicPaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit StrategicUnpaused(msg.sender);
    }

    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        if (_token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (_token == address(token)) revert InvalidAmount();

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    function updateGovernanceModule(address newGovernanceModule) external onlyGuardian {
        if (newGovernanceModule == address(0)) revert ZeroAddress();

        address oldModule = governanceModule;
        if (oldModule != address(0)) {
            _revokeRole(GOVERNANCE_ROLE, oldModule);
        }

        governanceModule = newGovernanceModule;
        _grantRole(GOVERNANCE_ROLE, newGovernanceModule);
        emit GovernanceModuleUpdated(oldModule, newGovernanceModule);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getVaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getAvailableBalance() external view returns (uint256) {
        return getRemainingQuarterlyAllowance();
    }

    function getProposal(uint256 proposalId) external view returns (ReleaseProposal memory) {
        return proposals[proposalId];
    }

    function canExecuteProposal(uint256 proposalId) external view returns (bool) {
        ReleaseProposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0 || proposal.executed || proposal.cancelled) return false;
        if (block.timestamp < proposal.createdAt + TIMELOCK_DURATION) return false;

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes == 0) return false;

        uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        if (approvalPercentage < APPROVAL_THRESHOLD) return false;

        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        if (totalVotes < quorumThresholdAmount) return false;

        uint256 currentQuarterReleased = getCurrentQuarterReleased();
        return proposal.amount <= proposal.quarterLimitSnapshot - currentQuarterReleased;
    }

    function getVoteResults(uint256 proposalId)
        external
        view
        returns (
            uint256 forVotes,
            uint256 againstVotes,
            uint256 totalVotes,
            uint256 approvalPercentage,
            bool meetsThreshold
        )
    {
        ReleaseProposal storage proposal = proposals[proposalId];
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        totalVotes = forVotes + againstVotes;

        if (totalVotes == 0) {
            approvalPercentage = 0;
            meetsThreshold = false;
        } else {
            approvalPercentage = (forVotes * BASIS_POINTS) / totalVotes;
            meetsThreshold = approvalPercentage >= APPROVAL_THRESHOLD;
        }
    }

    function getTotalReleased() external view returns (uint256) {
        return totalReleased;
    }

    function getReserveStatus()
        external
        view
        returns (uint256 initial, uint256 remaining, uint256 percentageRemaining)
    {
        initial = initialBalance;
        remaining = token.balanceOf(address(this));
        if (initial > 0) {
            percentageRemaining = (remaining * BASIS_POINTS) / initial;
        }
    }

    function getQuarterlyReleaseHistory() external view returns (QuarterlyRelease[] memory) {
        if (quarterCounter == 0) return new QuarterlyRelease[](0);

        QuarterlyRelease[] memory history = new QuarterlyRelease[](quarterCounter);
        for (uint256 i = 1; i <= quarterCounter; i++) {
            history[i - 1] = quarterlyReleases[i];
        }
        return history;
    }

    function hasVotedOnProposal(uint256 proposalId, address voter) external view returns (bool) {
        return hasVoted[proposalId][voter];
    }
}
