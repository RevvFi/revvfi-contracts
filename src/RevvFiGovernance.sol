// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IRevvFiBootstrapper.sol";
import "./interfaces/ITreasuryVault.sol";
import "./interfaces/IStrategicReserveVault.sol";
import "./interfaces/ICentralAuthority.sol";
import "./interfaces/IRewardDistributor.sol";

contract RevvFiGovernance is ReentrancyGuard, AccessControl {
    using Address for address;

    // =============================================================
    // Role Constants
    // =============================================================
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

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
    error InvalidProposalType();
    error InvalidTarget();
    error InvalidFunctionSelector();
    error InsufficientProposingPower();
    error QuorumNotMet();
    error ApprovalThresholdNotMet();
    error RewardsDistributorError();
    error TimelockTooShort();
    error TimelockTooLong();
    error EmptyDescription();
    error NoSnapshotForUser();
    error AlreadyFinalized();
    error ProposalExpired();
    error ExecutionGracePeriodExpired();
    error InvalidCalldataLength();

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant VOTING_PERIOD = 5 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD_BPS = 100; // 1% of total shares
    uint256 public constant MIN_QUORUM_BPS = 3000; // 30% quorum
    uint256 public constant EXECUTION_GRACE_PERIOD = 7 days; // 7 days after timelock to execute

    // Timelock bounds
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;

    // Proposal types
    uint8 public constant PROPOSAL_TYPE_TREASURY = 0;
    uint8 public constant PROPOSAL_TYPE_STRATEGIC = 1;
    uint8 public constant PROPOSAL_TYPE_LOCK_REDUCTION = 2;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 3;
    uint8 public constant PROPOSAL_TYPE_REWARDS_CLAIMER = 4;
    uint8 public constant PROPOSAL_TYPE_TIMELOCK_UPDATE = 5;

    // Proposal states
    uint8 public constant PROPOSAL_STATE_PENDING = 0;
    uint8 public constant PROPOSAL_STATE_ACTIVE = 1;
    uint8 public constant PROPOSAL_STATE_SUCCEEDED = 2;
    uint8 public constant PROPOSAL_STATE_DEFEATED = 3;
    uint8 public constant PROPOSAL_STATE_EXECUTED = 4;
    uint8 public constant PROPOSAL_STATE_CANCELLED = 5;
    uint8 public constant PROPOSAL_STATE_EXPIRED = 6;

    // =============================================================
    // Checkpoint System - Fixed (Explicit Checkpoint Struct)
    // =============================================================

    struct Checkpoint {
        uint256 snapshotId;
        uint256 balance;
        bool exists;
    }

    mapping(address => Checkpoint[]) public checkpoints; // user => checkpoints array
    mapping(address => uint256) public userLatestCheckpointId;
    uint256 public currentSnapshotId;

    // Proposal snapshot mapping
    mapping(uint256 => uint256) public proposalSnapshotId;
    mapping(uint256 => uint256) public proposalCreationBalance; // Store balance at proposal creation

    // =============================================================
    // Structs
    // =============================================================

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
        uint8 state;
        bool executed;
        bool cancelled;
        string description;
        uint256 snapshotId;
        uint256 creationBalance; // Balance snapshot at proposal creation
    }

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
        uint256 snapshotId;
        uint256 creationBalance;
    }

    struct Vote {
        bool supported;
        uint256 votingPower;
        bool cast;
    }

    // =============================================================
    // Selector Whitelists
    // =============================================================

    mapping(bytes4 => bool) public treasuryAllowedSelectors;
    mapping(bytes4 => bool) public strategicAllowedSelectors;
    mapping(bytes4 => bool) public rewardsAllowedSelectors;
    mapping(bytes4 => bool) public bootstrapperAllowedSelectors;
    mapping(bytes4 => bool) public governanceAllowedSelectors;

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
    mapping(uint256 => uint256) public proposalExecutionDeadline;

    // Timelock configuration
    uint256 public treasuryTimelock = 7 days;
    uint256 public strategicTimelock = 14 days;
    uint256 public lockReductionTimelock = 14 days;
    uint256 public emergencyTimelock = 2 days;
    uint256 public rewardsClaimerTimelock = 3 days;

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
        uint256 snapshotId,
        uint256 creationBalance,
        string description
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecution(uint256 indexed proposalId, address indexed executor);
    event ProposalFinalized(uint256 indexed proposalId, bool passed);
    event ProposalCancellation(uint256 indexed proposalId, address indexed canceller);
    event ProposalVetoed(uint256 indexed proposalId, address indexed creator);
    event GovernancePaused(address indexed executor);
    event GovernanceUnpaused(address indexed executor);
    event TimelockUpdated(uint8 indexed proposalType, uint256 newDuration);
    event RewardsDistributorSet(address indexed distributor);
    event SelectorWhitelisted(address indexed target, bytes4 selector, bool allowed);
    event GlobalSnapshotTaken(uint256 snapshotId, uint256 timestamp);

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
        currentSnapshotId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(EXECUTOR_ROLE, _factory);

        // Initialize whitelisted selectors
        treasuryAllowedSelectors[bytes4(keccak256("release(uint256,address)"))] = true;
        strategicAllowedSelectors[bytes4(keccak256("release(uint256,address)"))] = true;
        rewardsAllowedSelectors[bytes4(keccak256("addClaimer(address)"))] = true;
        rewardsAllowedSelectors[bytes4(keccak256("removeClaimer(address)"))] = true;
        bootstrapperAllowedSelectors[bytes4(keccak256("proposeRollOver(uint256)"))] = true;
        bootstrapperAllowedSelectors[bytes4(keccak256("emergencyPause()"))] = true;
        governanceAllowedSelectors[bytes4(keccak256("executeTimelockUpdate(uint8,uint256)"))] = true;
    }

    // =============================================================
    // Snapshot Management - Fixed
    // =============================================================

    function _takeSnapshot(address user, uint256 shareBalance) internal {
        Checkpoint[] storage userCheckpoints = checkpoints[user];

        // Only add checkpoint if balance changed or no checkpoints exist
        if (userCheckpoints.length == 0 || userCheckpoints[userCheckpoints.length - 1].balance != shareBalance) {
            userCheckpoints.push(Checkpoint({snapshotId: currentSnapshotId, balance: shareBalance, exists: true}));
        }
        userLatestCheckpointId[user] = currentSnapshotId;
    }

    function takeSnapshot(address user, uint256 shareBalance) external onlyBootstrapper {
        _takeSnapshot(user, shareBalance);
    }

    function takeGlobalSnapshot() external onlyBootstrapper {
        currentSnapshotId++;
        emit GlobalSnapshotTaken(currentSnapshotId, block.timestamp);
    }

    function getSnapshotShareBalance(address user, uint256 snapshotId) public view returns (uint256) {
        Checkpoint[] storage userCheckpoints = checkpoints[user];

        if (userCheckpoints.length == 0) return 0;

        // Binary search for the latest checkpoint <= snapshotId
        uint256 low = 0;
        uint256 high = userCheckpoints.length;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (userCheckpoints[mid].snapshotId <= snapshotId) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low == 0) return 0;
        return userCheckpoints[low - 1].balance;
    }

    // =============================================================
    // Selector Whitelist Management
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

    function propose(address target, bytes memory callData, uint8 proposalType, string memory description)
        public
        whenNotPaused
        returns (uint256 proposalId)
    {
        if (target == address(0)) revert InvalidTarget();
        if (bytes(description).length == 0) revert EmptyDescription();
        if (proposalType > 5) revert InvalidProposalType();

        bytes4 selector;

        assembly ("memory-safe") {
            // skip bytes length slot
            selector := mload(add(callData, 32))
        }

        // Validate timelock update proposals separately
        if (proposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) {
            _validateTimelockUpdate(target, selector, callData);
        }

        _validateFunctionSelector(target, proposalType, selector, callData);

        uint256 votingPower = IRevvFiBootstrapper(bootstrapper).shares(msg.sender);

        uint256 totalShares = IRevvFiBootstrapper(bootstrapper).totalShares();

        uint256 minThreshold = (totalShares * MIN_PROPOSAL_THRESHOLD_BPS) / BASIS_POINTS;

        if (votingPower < minThreshold) {
            revert InsufficientProposingPower();
        }

        // Increment snapshot before proposal creation
        currentSnapshotId++;

        proposalCounter++;
        uint256 snapshotId = currentSnapshotId;

        // Snapshot proposer balance
        _takeSnapshot(msg.sender, votingPower);

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
        newProposal.snapshotId = snapshotId;
        newProposal.creationBalance = votingPower;

        proposalSnapshotId[proposalCounter] = snapshotId;
        proposalCreationBalance[proposalCounter] = votingPower;

        emit ProposalCreated(
            proposalCounter,
            msg.sender,
            target,
            selector,
            proposalType,
            block.timestamp,
            block.timestamp + VOTING_PERIOD,
            snapshotId,
            votingPower,
            description
        );

        return proposalCounter;
    }

    function _validateFunctionSelector(address target, uint8 proposalType, bytes4 selector, bytes memory callData)
        internal
        view
    {
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
        } else if (proposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) {
            if (target != address(this)) revert InvalidTarget();
            if (!governanceAllowedSelectors[selector]) revert InvalidFunctionSelector();
        }
    }

    function castVote(uint256 proposalId, bool support) external whenNotPaused proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        if (block.timestamp < proposal.startTime) revert VotingNotStarted();
        if (block.timestamp > proposal.endTime) revert VotingEnded();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();
        if (votes[proposalId][msg.sender].cast) revert AlreadyVoted();

        uint256 votingPower = getSnapshotShareBalance(msg.sender, proposal.snapshotId);
        if (votingPower == 0) revert NoSnapshotForUser();

        votes[proposalId][msg.sender] = Vote({supported: support, votingPower: votingPower, cast: true});

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, support, votingPower);

        // Auto-finalize if voting period ended
        if (block.timestamp > proposal.endTime) {
            _finalizeProposal(proposalId);
        }
    }

    function finalizeProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp <= proposal.endTime) revert VotingNotEnded();
        if (proposal.state != PROPOSAL_STATE_ACTIVE) revert ProposalNotActive();

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
            uint256 timelockDuration = _getTimelockDuration(proposal.proposalType);
            proposalTimelock[proposalId] = block.timestamp + timelockDuration;
            proposalExecutionDeadline[proposalId] = proposalTimelock[proposalId] + EXECUTION_GRACE_PERIOD;
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
        if (block.timestamp > proposalExecutionDeadline[proposalId]) revert ExecutionGracePeriodExpired();

        proposal.executed = true;
        proposal.state = PROPOSAL_STATE_EXECUTED;

        // Use functionCall to get revert reason
        proposal.target.functionCall(proposal.callData);

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
    // Timelock Update Functions
    // =============================================================

    function proposeTimelockUpdate(uint8 proposalType, uint256 newDuration) external whenNotPaused returns (uint256) {
        if (newDuration < MIN_TIMELOCK) revert TimelockTooShort();
        if (newDuration > MAX_TIMELOCK) revert TimelockTooLong();
        if (proposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) revert InvalidProposalType(); // Prevent self-update

        bytes memory callData =
            abi.encodeWithSignature("executeTimelockUpdate(uint8,uint256)", proposalType, newDuration);

        uint256 proposalId = propose(
            address(this),
            callData,
            PROPOSAL_TYPE_TIMELOCK_UPDATE,
            string(
                abi.encodePacked(
                    "Update timelock for proposal type ", uintToString(proposalType), " to ", uintToString(newDuration)
                )
            )
        );

        return proposalId;
    }

    function executeTimelockUpdate(uint8 proposalType, uint256 newDuration) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        if (proposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) revert InvalidProposalType();

        if (proposalType == PROPOSAL_TYPE_TREASURY) treasuryTimelock = newDuration;
        else if (proposalType == PROPOSAL_TYPE_STRATEGIC) strategicTimelock = newDuration;
        else if (proposalType == PROPOSAL_TYPE_LOCK_REDUCTION) lockReductionTimelock = newDuration;
        else if (proposalType == PROPOSAL_TYPE_EMERGENCY) emergencyTimelock = newDuration;
        else if (proposalType == PROPOSAL_TYPE_REWARDS_CLAIMER) rewardsClaimerTimelock = newDuration;
        else revert InvalidProposalType();

        emit TimelockUpdated(proposalType, newDuration);
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
        if (proposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) return 6000;
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

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    function _validateTimelockUpdate(address target, bytes4 selector, bytes memory callData) internal view {
        if (target != address(this)) revert InvalidTarget();

        if (selector != this.executeTimelockUpdate.selector) {
            revert InvalidFunctionSelector();
        }

        if (callData.length != 68) {
            revert InvalidCalldataLength();
        }

        uint8 targetProposalType;

        assembly ("memory-safe") {
            targetProposalType := mload(add(callData, 36))
        }

        if (targetProposalType == PROPOSAL_TYPE_TIMELOCK_UPDATE) {
            revert InvalidProposalType();
        }
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
            description: p.description,
            snapshotId: p.snapshotId,
            creationBalance: p.creationBalance
        });
    }

    function getProposalState(uint256 proposalId) public view returns (uint8) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.cancelled) return PROPOSAL_STATE_CANCELLED;
        if (proposal.executed) return PROPOSAL_STATE_EXECUTED;
        if (proposal.state == PROPOSAL_STATE_SUCCEEDED) {
            if (block.timestamp > proposalExecutionDeadline[proposalId]) return PROPOSAL_STATE_EXPIRED;
            return PROPOSAL_STATE_SUCCEEDED;
        }
        if (proposal.state == PROPOSAL_STATE_DEFEATED) return PROPOSAL_STATE_DEFEATED;
        if (proposal.state != PROPOSAL_STATE_ACTIVE) return proposal.state;
        if (block.timestamp > proposal.endTime) return PROPOSAL_STATE_EXPIRED;
        if (block.timestamp < proposal.startTime) return PROPOSAL_STATE_PENDING;
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
        if (block.timestamp > proposalExecutionDeadline[proposalId]) return false;
        return true;
    }

    function getRemainingTimelock(uint256 proposalId) external view returns (uint256) {
        if (proposalTimelock[proposalId] == 0) return 0;
        if (block.timestamp >= proposalTimelock[proposalId]) return 0;
        return proposalTimelock[proposalId] - block.timestamp;
    }

    function getRemainingExecutionGracePeriod(uint256 proposalId) external view returns (uint256) {
        if (proposalExecutionDeadline[proposalId] == 0) return 0;
        if (block.timestamp >= proposalExecutionDeadline[proposalId]) return 0;
        return proposalExecutionDeadline[proposalId] - block.timestamp;
    }

    function getVotingPower(address lp) external view returns (uint256) {
        return IRevvFiBootstrapper(bootstrapper).shares(lp);
    }

    function getTotalVotingPower() external view returns (uint256) {
        return IRevvFiBootstrapper(bootstrapper).totalShares();
    }

    function getUserSnapshotBalance(address user, uint256 snapshotId) external view returns (uint256) {
        return getSnapshotShareBalance(user, snapshotId);
    }

    function getUserCheckpoints(address user) external view returns (Checkpoint[] memory) {
        return checkpoints[user];
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
        _takeSnapshot(lp, newShares);
    }
}
