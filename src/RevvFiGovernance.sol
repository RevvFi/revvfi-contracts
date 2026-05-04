// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IRevvFiBootstrapper.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";

/**
 * @title RevvFiGovernance
 * @dev Manages linear voting for a specific launch using LP shares (no separate governance token).
 * @dev LPs vote with their share balance. 1 share = 1 vote (linear).
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract RevvFiGovernance is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

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
        address target; // Contract to call (TreasuryVault, etc.)
        bytes callData; // Changed from 'calldata' to 'callData' (reserved keyword)
        uint8 proposalType; // 0=Treasury, 1=Strategic, 2=LockReduction, 3=Emergency
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

    // Proposal tracking
    uint256 public proposalCounter;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public votes;

    // Timelock tracking
    mapping(uint256 => uint256) public proposalTimelock;
    uint256 public constant TREASURY_TIMELOCK = 7 days;
    uint256 public constant STRATEGIC_TIMELOCK = 14 days;
    uint256 public constant LOCK_REDUCTION_TIMELOCK = 14 days;
    uint256 public constant EMERGENCY_TIMELOCK = 2 days;

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

    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);

    event ProposalVetoed(uint256 indexed proposalId, address indexed creator);

    event EmergencyPaused(address indexed executor);
    event EmergencyUnpaused(address indexed executor);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyBootstrapper() {
        require(msg.sender == bootstrapper, "RevvFiGovernance: not bootstrapper");
        _;
    }

    modifier onlyCreator() {
        require(msg.sender == creator, "RevvFiGovernance: not creator");
        _;
    }

    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "RevvFiGovernance: not guardian");
        _;
    }

    modifier onlyExecutor() {
        require(hasRole(EXECUTOR_ROLE, msg.sender), "RevvFiGovernance: not executor");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "RevvFiGovernance: emergency paused");
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        require(proposals[proposalId].id != 0, "RevvFiGovernance: proposal not found");
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
        address _factory
    ) {
        require(_bootstrapper != address(0), "RevvFiGovernance: zero bootstrapper");
        require(_treasuryVault != address(0), "RevvFiGovernance: zero treasury vault");
        require(_strategicReserveVault != address(0), "RevvFiGovernance: zero strategic reserve");
        require(_creator != address(0), "RevvFiGovernance: zero creator");
        require(_factory != address(0), "RevvFiGovernance: zero factory");

        bootstrapper = _bootstrapper;
        treasuryVault = _treasuryVault;
        strategicReserveVault = _strategicReserveVault;
        creator = _creator;
        factory = _factory;

        emergencyPaused = false;
        proposalCounter = 0;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(EXECUTOR_ROLE, _factory);
    }

    // =============================================================
    // Proposal Management
    // =============================================================

    /**
     * @dev Creates a new proposal
     * @param target Contract to call
     * @param callData Encoded function call
     * @param proposalType Type of proposal (0-3)
     * @param description Human-readable description
     */
    function propose(address target, bytes calldata callData, uint8 proposalType, string calldata description)
        external
        whenNotPaused
        returns (uint256 proposalId)
    {
        require(target != address(0), "RevvFiGovernance: zero target");
        require(bytes(description).length > 0, "RevvFiGovernance: empty description");
        require(proposalType <= 3, "RevvFiGovernance: invalid proposal type");

        // Validate target matches proposal type
        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            require(target == treasuryVault, "RevvFiGovernance: target must be treasury vault");
        } else if (proposalType == PROPOSAL_TYPE_STRATEGIC) {
            require(target == strategicReserveVault, "RevvFiGovernance: target must be strategic reserve");
        }

        // Get proposer's voting power
        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
        uint256 totalShares = IRevvFiBootstrapper(bootstrapper).totalShares();

        // Check minimum proposal threshold (1% of total shares)
        uint256 minThreshold = (totalShares * MIN_PROPOSAL_THRESHOLD_BPS) / BASIS_POINTS;
        require(votingPower >= minThreshold, "RevvFiGovernance: insufficient voting power to propose");

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

    // The rest of the contract remains the same...
    // (keep all other functions unchanged from your original)

    /**
     * @dev Casts a vote on a proposal
     */
    function castVote(uint256 proposalId, bool support) external whenNotPaused proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(block.timestamp >= proposal.startTime, "RevvFiGovernance: voting not started");
        require(block.timestamp <= proposal.endTime, "RevvFiGovernance: voting ended");
        require(proposal.state == PROPOSAL_STATE_ACTIVE, "RevvFiGovernance: proposal not active");
        require(!votes[proposalId][msg.sender].cast, "RevvFiGovernance: already voted");

        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
        require(votingPower > 0, "RevvFiGovernance: no voting power");

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

        if (proposal.state != PROPOSAL_STATE_ACTIVE) {
            return;
        }

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 threshold = _getApprovalThreshold(proposal.proposalType);
        uint256 quorum = _getQuorumThreshold(proposal.proposalType);

        uint256 quorumRequired = (proposal.totalVotingPowerAtStart * quorum) / BASIS_POINTS;

        bool passed = false;

        if (totalVotes >= quorumRequired && totalVotes > 0) {
            uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
            if (approvalPercentage >= threshold) {
                passed = true;
            }
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

        require(proposal.state == PROPOSAL_STATE_SUCCEEDED, "RevvFiGovernance: proposal not succeeded");
        require(!proposal.executed, "RevvFiGovernance: already executed");
        require(!proposal.cancelled, "RevvFiGovernance: proposal cancelled");
        require(!creatorVetoed[proposalId], "RevvFiGovernance: proposal vetoed");
        require(block.timestamp >= proposalTimelock[proposalId], "RevvFiGovernance: timelock active");

        if (proposal.proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) {
            require(creatorVetoed[proposalId] == false, "RevvFiGovernance: creator vetoed");
        }

        proposal.executed = true;
        proposal.state = PROPOSAL_STATE_EXECUTED;

        (bool success,) = proposal.target.call(proposal.callData);
        require(success, "RevvFiGovernance: execution failed");

        emit ProposalExecuted(proposalId, msg.sender);
    }

    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.state == PROPOSAL_STATE_ACTIVE, "RevvFiGovernance: proposal not active");

        require(
            msg.sender == proposal.proposer || hasRole(GUARDIAN_ROLE, msg.sender), "RevvFiGovernance: not authorized"
        );

        proposal.cancelled = true;
        proposal.state = PROPOSAL_STATE_CANCELLED;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    function vetoProposal(uint256 proposalId) external onlyCreator proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(
            proposal.proposalType == PROPOSAL_TYPE_LOCK_REDUCTION, "RevvFiGovernance: cannot veto this proposal type"
        );
        require(proposal.state == PROPOSAL_STATE_SUCCEEDED, "RevvFiGovernance: proposal not in succeeded state");
        require(!proposal.executed, "RevvFiGovernance: already executed");

        creatorVetoed[proposalId] = true;
        proposal.state = PROPOSAL_STATE_DEFEATED;

        emit ProposalVetoed(proposalId, msg.sender);
    }

    function _getApprovalThreshold(uint8 proposalType) internal pure returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            return 6000;
        } else if (proposalType == PROPOSAL_TYPE_STRATEGIC) {
            return 6600;
        } else if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) {
            return 7500;
        } else if (proposalType == PROPOSAL_TYPE_EMERGENCY) {
            return 8000;
        }
        return 6000;
    }

    function _getQuorumThreshold(uint8 proposalType) internal pure returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_EMERGENCY) {
            return 2000;
        }
        return 3000;
    }

    function _getTimelockDuration(uint8 proposalType) internal pure returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            return TREASURY_TIMELOCK;
        } else if (proposalType == PROPOSAL_TYPE_STRATEGIC) {
            return STRATEGIC_TIMELOCK;
        } else if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) {
            return LOCK_REDUCTION_TIMELOCK;
        } else if (proposalType == PROPOSAL_TYPE_EMERGENCY) {
            return EMERGENCY_TIMELOCK;
        }
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
        if (proposal.state == PROPOSAL_STATE_SUCCEEDED) {
            if (block.timestamp < proposalTimelock[proposalId]) {
                return PROPOSAL_STATE_SUCCEEDED;
            }
            return PROPOSAL_STATE_SUCCEEDED;
        }
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
            uint256 threshold = _getApprovalThreshold(proposal.proposalType);
            passesThreshold = approvalPercentage >= threshold;
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
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    function forceFinalizeProposal(uint256 proposalId) external onlyGuardian proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "RevvFiGovernance: voting not ended");
        require(proposal.state == PROPOSAL_STATE_ACTIVE, "RevvFiGovernance: proposal not active");

        _finalizeProposal(proposalId);
    }

    function onSharesUpdated(address lp, uint256 newShares) external onlyBootstrapper {
        emit VoteCast(0, lp, false, newShares);
    }
}
