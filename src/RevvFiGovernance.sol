// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IRevvFiBootstrapper.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title RevvFiGovernance
 * @dev Manages linear voting for a specific launch using LP shares (no separate governance token).
 * @dev LPs vote with their share balance. 1 share = 1 vote (linear).
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract RevvFiGovernance is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error NotBootstrapper();
    error NotCreator();
    error NotAuthorized();
    error EmergencyPaused();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalNotSucceeded();
    error ProposalExecuted();
    error ProposalCancelled();
    error TimelockActive();
    error ExecutionFailed();
    error VotingNotStarted();
    error VotingEnded();
    error AlreadyVoted();
    error NoVotingPower();
    error InvalidProposalType();
    error InvalidTarget();
    error InsufficientProposingPower();
    error QuorumNotMet();
    error ApprovalThresholdNotMet();

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant VOTING_PERIOD = 5 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD_BPS = 100; // 1% of total shares
    uint256 public constant MIN_QUORUM_BPS = 6000; // 60% - Required for all proposals

    // Proposal types and their requirements
    uint8 public constant PROPOSAL_TYPE_TREASURY = 0;
    uint8 public constant PROPOSAL_TYPE_STRATEGIC = 1;
    uint8 public constant PROPOSAL_TYPE_LOCK_REDUCTION = 2;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 3;

    // Proposal state
    uint8 public constant PROPOSAL_STATE_PENDING = 0;
    uint8 public constant PROPOSAL_STATE_ACTIVE = 1;
    uint8 public constant PROPOSAL_STATE_SUCCEEDED = 2;
    uint8 public constant PROPOSAL_STATE_DEFEATED = 3;
    uint8 public constant PROPOSAL_STATE_EXECUTED = 4;
    uint8 public constant PROPOSAL_STATE_CANCELLED = 5;

    // =============================================================
    // Structs
    // =============================================================

    struct Proposal {
        uint256 id;
        address proposer;
        address target;
        bytes callData;
        uint8 proposalType;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotingPowerAtStart;
        uint8 state;
        bool executed;
        bool cancelled;
        string description;
    }

    struct Vote {
        bool supported;
        uint256 votingPower;
        bool cast;
    }

    // =============================================================
    // State Variables
    // =============================================================

    address public immutable bootstrapper;
    address public immutable treasuryVault;
    address public immutable strategicReserveVault;
    address public immutable creator;
    address public immutable factory;
    address public immutable centralAuthority;

    // Proposal tracking
    uint256 public proposalCounter;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public votes;

    // Timelock tracking - Now updatable
    mapping(uint256 => uint256) public proposalTimelock;
    uint256 public treasuryTimelock = 7 days;
    uint256 public strategicTimelock = 14 days;
    uint256 public lockReductionTimelock = 14 days;
    uint256 public emergencyTimelock = 2 days;

    // Emergency flag
    bool public emergencyPaused;

    // Creator veto flag (limited use)
    mapping(uint256 => bool) public creatorVetoed;

    // =============================================================
    // Events
    // =============================================================

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint8 proposalType,
        uint256 startTime,
        uint256 endTime,
        string description
    );

    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecution(uint256 indexed proposalId, address indexed executor);
    event ProposalCancellation(uint256 indexed proposalId, address indexed canceller);
    event ProposalVetoed(uint256 indexed proposalId, address indexed creator);
    event GovernancePaused(address indexed executor);
    event GovernanceUnpaused(address indexed executor);
    event TimelockUpdated(uint8 indexed proposalType, uint256 newDuration);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyBootstrapper() {
        if (msg.sender != bootstrapper) revert NotBootstrapper();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert NotCreator();
        _;
    }

    modifier onlyGuardian() {
        if (!ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyExecutor() {
        if (!ICentralAuthority(centralAuthority).hasRole(EXECUTOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }

    modifier whenNotPaused() {
        if (emergencyPaused) revert EmergencyPaused();
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        if (proposals[proposalId].id == 0) revert ProposalNotFound();
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor(
        address _bootstrapper,
        address _treasuryVault,
        address _strategicReserveVault,
        address _creator,
        address _factory,
        address _centralAuthority
    ) {
        if (_bootstrapper == address(0)) revert ZeroAddress();
        if (_treasuryVault == address(0)) revert ZeroAddress();
        if (_strategicReserveVault == address(0)) revert ZeroAddress();
        if (_creator == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        bootstrapper = _bootstrapper;
        treasuryVault = _treasuryVault;
        strategicReserveVault = _strategicReserveVault;
        creator = _creator;
        factory = _factory;
        centralAuthority = _centralAuthority;

        emergencyPaused = false;
        proposalCounter = 0;

        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(EXECUTOR_ROLE, _factory);
    }

    // =============================================================
    // Proposal Management
    // =============================================================

    function propose(address target, bytes calldata callData, uint8 proposalType, string calldata description)
        external
        whenNotPaused
        returns (uint256 proposalId)
    {
        if (target == address(0)) revert InvalidTarget();
        if (bytes(description).length == 0) revert InvalidProposalType();
        if (proposalType > 3) revert InvalidProposalType();

        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            if (target != treasuryVault) revert InvalidTarget();
        } else if (proposalType == PROPOSAL_TYPE_STRATEGIC) {
            if (target != strategicReserveVault) revert InvalidTarget();
        }

        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
        uint256 totalShares = IRevvFiBootstrapper(bootstrapper).totalShares();

        uint256 minThreshold = (totalShares * MIN_PROPOSAL_THRESHOLD_BPS) / BASIS_POINTS;
        if (votingPower < minThreshold) revert InsufficientProposingPower();

        proposalCounter++;

        proposals[proposalCounter] = Proposal({
            id: proposalCounter,
            proposer: msg.sender,
            target: target,
            callData: callData,
            proposalType: proposalType,
            startTime: block.timestamp,
            endTime: block.timestamp + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            totalVotingPowerAtStart: totalShares,
            state: PROPOSAL_STATE_ACTIVE,
            executed: false,
            cancelled: false,
            description: description
        });

        emit ProposalCreated(
            proposalCounter,
            msg.sender,
            target,
            proposalType,
            block.timestamp,
            block.timestamp + VOTING_PERIOD,
            description
        );

        return proposalCounter;
    }

    function castVote(uint256 proposalId, bool support) external whenNotPaused proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        if (block.timestamp < proposal.startTime) revert VotingNotStarted();
        if (block.timestamp > proposal.endTime) revert VotingEnded();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (votes[proposalId][msg.sender].cast) revert AlreadyVoted();

        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
        if (votingPower == 0) revert NoVotingPower();

        votes[proposalId][msg.sender] = Vote({supported: support, votingPower: votingPower, cast: true});

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, support, votingPower);
        _checkAndFinalizeProposal(proposalId);
    }

    function _checkAndFinalizeProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp > proposal.endTime) {
            _finalizeProposal(proposalId);
        }
    }

    function _finalizeProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != PROPOSAL_STATE_ACTIVE) return;

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 threshold = _getApprovalThreshold(proposal.proposalType);
        uint256 quorum = _getQuorumThreshold(proposal.proposalType);
        uint256 quorumRequired = (proposal.totalVotingPowerAtStart * quorum) / BASIS_POINTS;

        bool passed = false;
        if (totalVotes >= quorumRequired && totalVotes > 0) {
            uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
            if (approvalPercentage >= threshold) passed = true;
        }

        if (passed) {
            proposal.state = PROPOSAL_STATE_SUCCEEDED;
            proposalTimelock[proposalId] = block.timestamp + _getTimelockDuration(proposal.proposalType);
        } else {
            proposal.state = PROPOSAL_STATE_DEFEATED;
        }
    }

    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.state != PROPOSAL_STATE_SUCCEEDED) revert ProposalNotSucceeded();
        if (proposal.executed) revert ProposalExecuted();
        if (proposal.cancelled) revert ProposalCancelled();
        if (creatorVetoed[proposalId]) revert ProposalCancelled();
        if (block.timestamp < proposalTimelock[proposalId]) revert TimelockActive();

        proposal.executed = true;
        proposal.state = PROPOSAL_STATE_EXECUTED;

        (bool success,) = proposal.target.call(proposal.callData);
        if (!success) revert ExecutionFailed();

        emit ProposalExecution(proposalId, msg.sender);
    }

    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (msg.sender != proposal.proposer && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        proposal.cancelled = true;
        proposal.state = PROPOSAL_STATE_CANCELLED;
        emit ProposalCancellation(proposalId, msg.sender);
    }

    function vetoProposal(uint256 proposalId) external onlyCreator proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.proposalType != PROPOSAL_TYPE_LOCK_REDUCTION) revert InvalidProposalType();
        if (proposal.state != PROPOSAL_STATE_SUCCEEDED) revert ProposalNotSucceeded();
        if (proposal.executed) revert ProposalExecuted();

        creatorVetoed[proposalId] = true;
        proposal.state = PROPOSAL_STATE_DEFEATED;
        emit ProposalVetoed(proposalId, msg.sender);
    }

    function _getApprovalThreshold(uint8 proposalType) internal pure returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) return 6000;
        if (proposalType == PROPOSAL_TYPE_STRATEGIC) return 6600;
        if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) return 7500;
        if (proposalType == PROPOSAL_TYPE_EMERGENCY) return 8000;
        return 6000;
    }

    function _getQuorumThreshold(uint8 proposalType) internal pure returns (uint256) {
        // All proposals require 60% of total shares to participate (minimum quorum)
        return 6000; // 60% in basis points
    }

    function _getTimelockDuration(uint8 proposalType) internal view returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) return treasuryTimelock;
        if (proposalType == PROPOSAL_TYPE_STRATEGIC) return strategicTimelock;
        if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) return lockReductionTimelock;
        if (proposalType == PROPOSAL_TYPE_EMERGENCY) return emergencyTimelock;
        return 7 days;
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getVote(uint256 proposalId, address voter)
        external
        view
        returns (bool supported, uint256 votingPower, bool cast)
    {
        Vote memory vote = votes[proposalId][voter];
        return (vote.supported, vote.votingPower, vote.cast);
    }

    function getProposalState(uint256 proposalId) public view returns (uint8) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.cancelled) return PROPOSAL_STATE_CANCELLED;
        if (proposal.executed) return PROPOSAL_STATE_EXECUTED;
        if (proposal.state == PROPOSAL_STATE_SUCCEEDED) return PROPOSAL_STATE_SUCCEEDED;
        if (proposal.state == PROPOSAL_STATE_DEFEATED) return PROPOSAL_STATE_DEFEATED;
        if (block.timestamp < proposal.startTime) return PROPOSAL_STATE_PENDING;
        if (block.timestamp <= proposal.endTime) return PROPOSAL_STATE_ACTIVE;
        return PROPOSAL_STATE_PENDING;
    }

    function getVoteResults(uint256 proposalId)
        external
        view
        returns (
            uint256 forVotes,
            uint256 againstVotes,
            uint256 totalVotes,
            uint256 approvalPercentage,
            bool passesThreshold,
            bool meetsQuorum
        )
    {
        Proposal storage proposal = proposals[proposalId];
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        totalVotes = forVotes + againstVotes;

        if (totalVotes == 0) {
            approvalPercentage = 0;
            passesThreshold = false;
        } else {
            approvalPercentage = (forVotes * BASIS_POINTS) / totalVotes;
            passesThreshold = approvalPercentage >= _getApprovalThreshold(proposal.proposalType);
        }

        uint256 quorumRequired =
            (proposal.totalVotingPowerAtStart * _getQuorumThreshold(proposal.proposalType)) / BASIS_POINTS;
        meetsQuorum = totalVotes >= quorumRequired;
    }

    function canExecute(uint256 proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != PROPOSAL_STATE_SUCCEEDED) return false;
        if (proposal.executed) return false;
        if (proposal.cancelled) return false;
        if (creatorVetoed[proposalId]) return false;
        if (block.timestamp < proposalTimelock[proposalId]) return false;
        return true;
    }

    function getRemainingTimelock(uint256 proposalId) external view returns (uint256) {
        if (proposalTimelock[proposalId] == 0) return 0;
        if (block.timestamp >= proposalTimelock[proposalId]) return 0;
        return proposalTimelock[proposalId] - block.timestamp;
    }

    function getVotingPower(address lp) external view returns (uint256) {
        return IRevvFiBootstrapper(bootstrapper).shares(lp);
    }

    function getTotalVotingPower() external view returns (uint256) {
        return IRevvFiBootstrapper(bootstrapper).totalShares();
    }

    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit GovernancePaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit GovernanceUnpaused(msg.sender);
    }

    function forceFinalizeProposal(uint256 proposalId) external onlyGuardian proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp <= proposal.endTime) revert ProposalNotActive();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        _finalizeProposal(proposalId);
    }

    // =============================================================
    // Timelock Update Functions (Guardian Only)
    // =============================================================

    /**
     * @dev Updates the timelock duration for treasury proposals
     * @param _newDuration New timelock duration in seconds
     */
    function setTreasuryTimelock(uint256 _newDuration) external onlyGuardian {
        if (_newDuration == 0) revert InvalidProposalType();
        treasuryTimelock = _newDuration;
        emit TimelockUpdated(PROPOSAL_TYPE_TREASURY, _newDuration);
    }

    /**
     * @dev Updates the timelock duration for strategic reserve proposals
     * @param _newDuration New timelock duration in seconds
     */
    function setStrategicTimelock(uint256 _newDuration) external onlyGuardian {
        if (_newDuration == 0) revert InvalidProposalType();
        strategicTimelock = _newDuration;
        emit TimelockUpdated(PROPOSAL_TYPE_STRATEGIC, _newDuration);
    }

    /**
     * @dev Updates the timelock duration for lock reduction proposals
     * @param _newDuration New timelock duration in seconds
     */
    function setLockReductionTimelock(uint256 _newDuration) external onlyGuardian {
        if (_newDuration == 0) revert InvalidProposalType();
        lockReductionTimelock = _newDuration;
        emit TimelockUpdated(PROPOSAL_TYPE_LOCK_REDUCTION, _newDuration);
    }

    /**
     * @dev Updates the timelock duration for emergency proposals
     * @param _newDuration New timelock duration in seconds
     */
    function setEmergencyTimelock(uint256 _newDuration) external onlyGuardian {
        if (_newDuration == 0) revert InvalidProposalType();
        emergencyTimelock = _newDuration;
        emit TimelockUpdated(PROPOSAL_TYPE_EMERGENCY, _newDuration);
    }

    function onSharesUpdated(address lp, uint256 newShares) external onlyBootstrapper {
        emit VoteCast(0, lp, false, newShares);
    }
}
