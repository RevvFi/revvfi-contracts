// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRevvFiBootstrapper.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/ICentralAuthority.sol";
import "./interfaces/IRewardDistributor.sol";

contract RevvFiGovernance is ReentrancyGuard, AccessControl {
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
    error VotingNotEnded();
    error AlreadyVoted();
    error NoVotingPower();
    error InvalidProposalType();
    error InvalidTarget();
    error InvalidFunctionSelector();
    error InsufficientProposingPower();
    error QuorumNotMet();
    error ApprovalThresholdNotMet();
    error RewardsDistributorError();
    error TimelockChangeTooRapid();
    error ProposalAlreadyFinalized();

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
    uint256 public constant MIN_QUORUM_BPS = 3000; // 30% quorum
    uint256 public constant TIMELOCK_UPDATE_DELAY = 7 days; // Delay for timelock changes

    uint8 public constant PROPOSAL_TYPE_TREASURY = 0;
    uint8 public constant PROPOSAL_TYPE_STRATEGIC = 1;
    uint8 public constant PROPOSAL_TYPE_LOCK_REDUCTION = 2;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 3;
    uint8 public constant PROPOSAL_TYPE_REWARDS_CLAIMER = 4;

    uint8 public constant PROPOSAL_STATE_PENDING = 0;
    uint8 public constant PROPOSAL_STATE_ACTIVE = 1;
    uint8 public constant PROPOSAL_STATE_SUCCEEDED = 2;
    uint8 public constant PROPOSAL_STATE_DEFEATED = 3;
    uint8 public constant PROPOSAL_STATE_EXECUTED = 4;
    uint8 public constant PROPOSAL_STATE_CANCELLED = 5;

    // =============================================================
    // Structs
    // =============================================================

    // Internal storage struct (with mapping - cannot be returned externally)
    struct Proposal {
        uint256 id;
        address proposer;
        address target;
        bytes callData;
        bytes4 selector;
        uint8 proposalType;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotingPowerAtStart;
        mapping(address => uint256) votingPowerSnapshot; // Snapshot per voter
        uint8 state;
        bool executed;
        bool cancelled;
        string description;
    }

    // External view struct (without mapping - can be returned)
    struct ProposalView {
        uint256 id;
        address proposer;
        address target;
        bytes callData;
        bytes4 selector;
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
    // Function Selector Whitelists
    // =============================================================

    // Treasury allowed selectors
    mapping(bytes4 => bool) public treasuryAllowedSelectors;
    // Strategic reserve allowed selectors
    mapping(bytes4 => bool) public strategicAllowedSelectors;
    // Rewards distributor allowed selectors
    mapping(bytes4 => bool) public rewardsAllowedSelectors;
    // Bootstrapper allowed selectors (for emergency/lock reduction)
    mapping(bytes4 => bool) public bootstrapperAllowedSelectors;

    // =============================================================
    // State Variables
    // =============================================================

    address public immutable bootstrapper;
    address public immutable treasuryVault;
    address public immutable strategicReserveVault;
    address public immutable creator;
    address public immutable factory;
    address public immutable centralAuthority;
    address public rewardsDistributor;

    uint256 public proposalCounter;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(uint256 => uint256) public proposalTimelock;
    mapping(uint256 => bool) public creatorVetoed;

    // Timelock configuration with pending updates
    uint256 public treasuryTimelock = 7 days;
    uint256 public strategicTimelock = 14 days;
    uint256 public lockReductionTimelock = 14 days;
    uint256 public emergencyTimelock = 2 days;
    uint256 public rewardsClaimerTimelock = 3 days;

    // Pending timelock updates (with delay)
    struct PendingTimelockUpdate {
        uint8 proposalType;
        uint256 newDuration;
        uint256 effectiveTime;
    }
    PendingTimelockUpdate[] public pendingTimelockUpdates;
    mapping(uint8 => bool) public hasPendingUpdate;

    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        bytes4 selector,
        uint8 proposalType,
        uint256 startTime,
        uint256 endTime,
        string description
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecution(uint256 indexed proposalId, address indexed executor);
    event ProposalFinalized(uint256 indexed proposalId, bool passed);
    event ProposalCancellation(uint256 indexed proposalId, address indexed canceller);
    event ProposalVetoed(uint256 indexed proposalId, address indexed creator);
    event GovernancePaused(address indexed executor);
    event GovernanceUnpaused(address indexed executor);
    event TimelockUpdateScheduled(uint8 indexed proposalType, uint256 newDuration, uint256 effectiveTime);
    event TimelockUpdated(uint8 indexed proposalType, uint256 newDuration);
    event RewardsDistributorSet(address indexed distributor);
    event SelectorWhitelisted(address indexed target, bytes4 selector, bool allowed);

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

        // Initialize whitelisted selectors for treasury
        treasuryAllowedSelectors[bytes4(keccak256("release(uint256,address)"))] = true;
        treasuryAllowedSelectors[bytes4(keccak256("proposeRelease(uint256,address)"))] = true;

        // Initialize whitelisted selectors for strategic reserve
        strategicAllowedSelectors[bytes4(keccak256("release(uint256,address)"))] = true;
        strategicAllowedSelectors[bytes4(keccak256("proposeRelease(uint256,address)"))] = true;

        // Initialize whitelisted selectors for rewards distributor
        rewardsAllowedSelectors[bytes4(keccak256("addClaimer(address)"))] = true;
        rewardsAllowedSelectors[bytes4(keccak256("removeClaimer(address)"))] = true;

        // Initialize whitelisted selectors for bootstrapper (emergency/lock reduction)
        bootstrapperAllowedSelectors[bytes4(keccak256("proposeRollOver(uint256)"))] = true;
        bootstrapperAllowedSelectors[bytes4(keccak256("emergencyPause()"))] = true;
    }

    // =============================================================
    // Selector Whitelist Management (Guardian Only)
    // =============================================================

    function setTreasuryAllowedSelector(bytes4 selector, bool allowed) external onlyGuardian {
        treasuryAllowedSelectors[selector] = allowed;
        emit SelectorWhitelisted(treasuryVault, selector, allowed);
    }

    function setStrategicAllowedSelector(bytes4 selector, bool allowed) external onlyGuardian {
        strategicAllowedSelectors[selector] = allowed;
        emit SelectorWhitelisted(strategicReserveVault, selector, allowed);
    }

    function setRewardsAllowedSelector(bytes4 selector, bool allowed) external onlyGuardian {
        rewardsAllowedSelectors[selector] = allowed;
        if (rewardsDistributor != address(0)) {
            emit SelectorWhitelisted(rewardsDistributor, selector, allowed);
        }
    }

    function setBootstrapperAllowedSelector(bytes4 selector, bool allowed) external onlyGuardian {
        bootstrapperAllowedSelectors[selector] = allowed;
        emit SelectorWhitelisted(bootstrapper, selector, allowed);
    }

    // =============================================================
    // Rewards Distributor Setup
    // =============================================================

    function setRewardsDistributor(address _rewardsDistributor) external {
        if (msg.sender != factory) revert NotAuthorized();
        if (_rewardsDistributor == address(0)) revert ZeroAddress();
        rewardsDistributor = _rewardsDistributor;
        emit RewardsDistributorSet(_rewardsDistributor);
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
        if (proposalType > 4) revert InvalidProposalType();

        // Validate selector is whitelisted
        bytes4 selector = bytes4(callData[:4]);
        _validateFunctionSelector(target, proposalType, selector);

        // Take voting power snapshot at proposal creation
        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
        uint256 totalShares = IRevvFiBootstrapper(bootstrapper).totalShares();
        uint256 minThreshold = (totalShares * MIN_PROPOSAL_THRESHOLD_BPS) / BASIS_POINTS;
        if (votingPower < minThreshold) revert InsufficientProposingPower();

        proposalCounter++;

        Proposal storage newProposal = proposals[proposalCounter];
        newProposal.id = proposalCounter;
        newProposal.proposer = msg.sender;
        newProposal.target = target;
        newProposal.callData = callData;
        newProposal.selector = selector;
        newProposal.proposalType = proposalType;
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + VOTING_PERIOD;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.totalVotingPowerAtStart = totalShares;
        newProposal.state = PROPOSAL_STATE_ACTIVE;
        newProposal.executed = false;
        newProposal.cancelled = false;
        newProposal.description = description;

        // Store voting power snapshot for proposer
        newProposal.votingPowerSnapshot[msg.sender] = votingPower;

        emit ProposalCreated(
            proposalCounter,
            msg.sender,
            target,
            selector,
            proposalType,
            block.timestamp,
            block.timestamp + VOTING_PERIOD,
            description
        );

        return proposalCounter;
    }

    function _validateFunctionSelector(address target, uint8 proposalType, bytes4 selector) internal view {
        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            if (target != treasuryVault) revert InvalidTarget();
            if (!treasuryAllowedSelectors[selector]) revert InvalidFunctionSelector();
        } else if (proposalType == PROPOSAL_TYPE_STRATEGIC) {
            if (target != strategicReserveVault) revert InvalidTarget();
            if (!strategicAllowedSelectors[selector]) revert InvalidFunctionSelector();
        } else if (proposalType == PROPOSAL_TYPE_REWARDS_CLAIMER) {
            if (rewardsDistributor == address(0) || target != rewardsDistributor) revert InvalidTarget();
            if (!rewardsAllowedSelectors[selector]) revert InvalidFunctionSelector();
        } else if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION || proposalType == PROPOSAL_TYPE_EMERGENCY) {
            if (target != bootstrapper) revert InvalidTarget();
            if (!bootstrapperAllowedSelectors[selector]) revert InvalidFunctionSelector();
        }
    }

    function castVote(uint256 proposalId, bool support) external whenNotPaused proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        if (block.timestamp < proposal.startTime) revert VotingNotStarted();
        if (block.timestamp > proposal.endTime) revert VotingEnded();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (votes[proposalId][msg.sender].cast) revert AlreadyVoted();

        // Use SNAPSHOT voting power from proposal creation time
        uint256 votingPower = proposal.votingPowerSnapshot[msg.sender];
        if (votingPower == 0) {
            // If no snapshot exists, take current (for voters who didn't propose)
            votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);
            if (votingPower == 0) revert NoVotingPower();
            proposal.votingPowerSnapshot[msg.sender] = votingPower;
        }

        votes[proposalId][msg.sender] = Vote({supported: support, votingPower: votingPower, cast: true});

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, support, votingPower);
    }

    /**
     * @dev Public function to finalize a proposal after voting period ends
     */
    function finalizeProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp <= proposal.endTime) revert VotingNotEnded();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (proposal.state == PROPOSAL_STATE_SUCCEEDED || proposal.state == PROPOSAL_STATE_DEFEATED) {
            revert ProposalAlreadyFinalized();
        }

        _finalizeProposal(proposalId);
    }

    function _finalizeProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != PROPOSAL_STATE_ACTIVE) return;

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 threshold = _getApprovalThreshold(proposal.proposalType);
        uint256 quorumRequired = (proposal.totalVotingPowerAtStart * MIN_QUORUM_BPS) / BASIS_POINTS;

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

        emit ProposalFinalized(proposalId, passed);
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

        if (msg.sender != proposal.proposer && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender))
        {
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

    // =============================================================
    // Proposal Actions for Rewards Distributor
    // =============================================================

    function addRewardsClaimer(address claimer) external {
        if (msg.sender != factory && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        if (rewardsDistributor == address(0)) revert RewardsDistributorError();
        IRewardDistributor(rewardsDistributor).addClaimer(claimer);
    }

    function removeRewardsClaimer(address claimer) external {
        if (msg.sender != factory && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        if (rewardsDistributor == address(0)) revert RewardsDistributorError();
        IRewardDistributor(rewardsDistributor).removeClaimer(claimer);
    }

    // =============================================================
    // Helper Functions
    // =============================================================

    function _getApprovalThreshold(uint8 proposalType) internal pure returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) return 6000;
        if (proposalType == PROPOSAL_TYPE_STRATEGIC) return 6600;
        if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) return 7500;
        if (proposalType == PROPOSAL_TYPE_EMERGENCY) return 8000;
        if (proposalType == PROPOSAL_TYPE_REWARDS_CLAIMER) return 6000;
        return 6000;
    }

    function _getTimelockDuration(uint8 proposalType) internal view returns (uint256) {
        if (proposalType == PROPOSAL_TYPE_TREASURY) return treasuryTimelock;
        if (proposalType == PROPOSAL_TYPE_STRATEGIC) return strategicTimelock;
        if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) return lockReductionTimelock;
        if (proposalType == PROPOSAL_TYPE_EMERGENCY) return emergencyTimelock;
        if (proposalType == PROPOSAL_TYPE_REWARDS_CLAIMER) return rewardsClaimerTimelock;
        return 7 days;
    }

    // =============================================================
    // Timelock Update Functions (with delay)
    // =============================================================

    function scheduleTimelockUpdate(uint8 proposalType, uint256 newDuration) external onlyGuardian {
        if (newDuration == 0) revert InvalidProposalType();
        if (newDuration > 30 days) revert InvalidProposalType(); // Sanity cap

        // Remove existing pending update for this type
        _removePendingUpdate(proposalType);

        pendingTimelockUpdates.push(
            PendingTimelockUpdate({
                proposalType: proposalType,
                newDuration: newDuration,
                effectiveTime: block.timestamp + TIMELOCK_UPDATE_DELAY
            })
        );
        hasPendingUpdate[proposalType] = true;

        emit TimelockUpdateScheduled(proposalType, newDuration, block.timestamp + TIMELOCK_UPDATE_DELAY);
    }

    function _removePendingUpdate(uint8 proposalType) internal {
        for (uint256 i = 0; i < pendingTimelockUpdates.length; i++) {
            if (pendingTimelockUpdates[i].proposalType == proposalType) {
                pendingTimelockUpdates[i] = pendingTimelockUpdates[pendingTimelockUpdates.length - 1];
                pendingTimelockUpdates.pop();
                break;
            }
        }
        hasPendingUpdate[proposalType] = false;
    }

    function executeTimelockUpdate(uint8 proposalType) external onlyGuardian {
        for (uint256 i = 0; i < pendingTimelockUpdates.length; i++) {
            if (pendingTimelockUpdates[i].proposalType == proposalType) {
                PendingTimelockUpdate memory update = pendingTimelockUpdates[i];
                if (block.timestamp < update.effectiveTime) revert TimelockChangeTooRapid();

                if (proposalType == PROPOSAL_TYPE_TREASURY) treasuryTimelock = update.newDuration;
                else if (proposalType == PROPOSAL_TYPE_STRATEGIC) strategicTimelock = update.newDuration;
                else if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) lockReductionTimelock = update.newDuration;
                else if (proposalType == PROPOSAL_TYPE_EMERGENCY) emergencyTimelock = update.newDuration;
                else if (proposalType == PROPOSAL_TYPE_REWARDS_CLAIMER) rewardsClaimerTimelock = update.newDuration;

                _removePendingUpdate(proposalType);
                emit TimelockUpdated(proposalType, update.newDuration);
                return;
            }
        }
        revert ProposalNotFound();
    }

    function getPendingTimelockUpdate(uint8 proposalType)
        external
        view
        returns (uint256 newDuration, uint256 effectiveTime)
    {
        for (uint256 i = 0; i < pendingTimelockUpdates.length; i++) {
            if (pendingTimelockUpdates[i].proposalType == proposalType) {
                return (pendingTimelockUpdates[i].newDuration, pendingTimelockUpdates[i].effectiveTime);
            }
        }
        return (0, 0);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        Proposal storage p = proposals[proposalId];
        return ProposalView({
            id: p.id,
            proposer: p.proposer,
            target: p.target,
            callData: p.callData,
            selector: p.selector,
            proposalType: p.proposalType,
            startTime: p.startTime,
            endTime: p.endTime,
            forVotes: p.forVotes,
            againstVotes: p.againstVotes,
            totalVotingPowerAtStart: p.totalVotingPowerAtStart,
            state: p.state,
            executed: p.executed,
            cancelled: p.cancelled,
            description: p.description
        });
    }

    function getProposalSnapshot(uint256 proposalId, address voter) external view returns (uint256) {
        return proposals[proposalId].votingPowerSnapshot[voter];
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
        if (proposal.state == PROPOSAL_STATE_SUCCEEDED || proposal.state == PROPOSAL_STATE_DEFEATED) {
            return proposal.state;
        }
        if (proposal.state != PROPOSAL_STATE_ACTIVE) return proposal.state;
        if (block.timestamp > proposal.endTime) return PROPOSAL_STATE_PENDING; // Needs finalization
        return PROPOSAL_STATE_ACTIVE;
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

        uint256 quorumRequired = (proposal.totalVotingPowerAtStart * MIN_QUORUM_BPS) / BASIS_POINTS;
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

    // =============================================================
    // Emergency Functions
    // =============================================================

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
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (block.timestamp <= proposal.endTime) revert VotingNotEnded();
        _finalizeProposal(proposalId);
    }

    function onSharesUpdated(address lp, uint256 newShares) external onlyBootstrapper {
        // Pure hook - no state changes needed
    }
}
