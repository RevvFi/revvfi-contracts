// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title TreasuryVault
 * @dev Holds governance-controlled treasury tokens. Creator has ZERO access.
 * @dev Releases require LP vote via RevvFiGovernance and timelock execution.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract TreasuryVault is ReentrancyGuard, AccessControl {
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

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant APPROVAL_THRESHOLD = 6000; // 60% (basis points: 6000 = 60%)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TIMELOCK_DURATION = 7 days;

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
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;
    address public immutable centralAuthority;

    // Governance module address
    address public governanceModule;

    // Proposal tracking
    uint256 public proposalCounter;
    mapping(uint256 => ReleaseProposal) public proposals;

    // Total tokens released so far
    uint256 public totalReleased;

    // Emergency flag
    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint256 amount,
        address indexed recipient,
        uint256 totalVotingPower
    );

    event ProposalRelease(
        uint256 indexed proposalId, uint256 amount, address indexed recipient, address indexed executor
    );

    event ProposalCancellationRequested(uint256 indexed proposalId, address indexed canceller);

    event TokensReleased(uint256 amount, address indexed recipient, uint256 totalReleasedSoFar);

    event GovernanceModuleUpdated(address indexed oldModule, address indexed newModule);
    event TreasuryPaused(address indexed executor);
    event TreasuryUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);

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
        totalReleased = 0;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _platformFeeRecipient);
    }

    // =============================================================
    // Initialization Functions
    // =============================================================

    /**
     * @dev Initializes the governance module (called by factory)
     * @param _governanceModule Address of RevvFiGovernance contract
     */
    function initializeGovernance(address _governanceModule) external onlyFactory {
        if (_governanceModule == address(0)) revert ZeroAddress();
        if (governanceModule != address(0)) revert AlreadyInitialized();

        governanceModule = _governanceModule;
        _grantRole(GOVERNANCE_ROLE, _governanceModule);

        emit GovernanceModuleUpdated(address(0), _governanceModule);
    }

    // =============================================================
    // Proposal Functions (Called by Governance Module)
    // =============================================================

    /**
     * @dev Creates a new release proposal (called by governance module)
     * @param proposer Address of LP who created the proposal
     * @param amount Amount of tokens to release
     * @param recipient Address receiving the tokens
     * @param totalVotingPower Total voting power at proposal creation
     * @return proposalId ID of created proposal
     */
    function createProposal(address proposer, uint256 amount, address recipient, uint256 totalVotingPower)
        external
        onlyGovernance
        whenNotPaused
        returns (uint256 proposalId)
    {
        if (proposer == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > token.balanceOf(address(this))) revert InsufficientBalance();

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
            totalVotingPowerAtProposal: totalVotingPower
        });

        emit ProposalCreated(proposalCounter, proposer, amount, recipient, totalVotingPower);

        return proposalCounter;
    }

    /**
     * @dev Casts vote on a proposal (called by governance module)
     * @param proposalId ID of proposal
     * @param voter Address of LP voting
     * @param support True = for, False = against
     * @param votingPower Voting power of the LP
     */
    function castVote(uint256 proposalId, address voter, bool support, uint256 votingPower)
        external
        onlyGovernance
        proposalExists(proposalId)
        proposalNotExecuted(proposalId)
    {
        if (voter == address(0)) revert ZeroAddress();
        if (votingPower == 0) revert InvalidAmount();

        ReleaseProposal storage proposal = proposals[proposalId];

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }
    }

    /**
     * @dev Executes a proposal after timelock (called by anyone)
     * @param proposalId ID of proposal to execute
     */
    function executeProposal(uint256 proposalId)
        external
        nonReentrant
        whenNotPaused
        proposalExists(proposalId)
        proposalNotExecuted(proposalId)
    {
        ReleaseProposal storage proposal = proposals[proposalId];

        // Check timelock
        if (block.timestamp < proposal.createdAt + TIMELOCK_DURATION) revert InvalidAmount();

        // Check approval threshold
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes == 0) revert InvalidAmount();

        uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        if (approvalPercentage < APPROVAL_THRESHOLD) revert InvalidAmount();

        // Also check against total voting power (quorum)
        // Require at least 30% of total voting power participated
        uint256 quorumThreshold = (proposal.totalVotingPowerAtProposal * 3000) / BASIS_POINTS; // 30%
        if (totalVotes < quorumThreshold) revert InvalidAmount();

        // Execute release
        uint256 amount = proposal.amount;
        address recipient = proposal.recipient;

        proposal.executed = true;
        proposal.executedAt = block.timestamp;
        totalReleased += amount;

        token.safeTransfer(recipient, amount);

        emit ProposalRelease(proposalId, amount, recipient, msg.sender);
        emit TokensReleased(amount, recipient, totalReleased);
    }

    /**
     * @dev Cancels a proposal (only if not passed and not executed)
     * @param proposalId ID of proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) proposalNotExecuted(proposalId) {
        ReleaseProposal storage proposal = proposals[proposalId];

        // Only proposer or guardian can cancel
        if (msg.sender != proposal.proposer && !ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // Cannot cancel if proposal already passed timelock
        if (block.timestamp >= proposal.createdAt + TIMELOCK_DURATION) revert InvalidAmount();

        proposal.cancelled = true;
        emit ProposalCancellationRequested(proposalId, msg.sender);
    }

    // =============================================================
    // Emergency Functions (Guardian Only)
    // =============================================================

    /**
     * @dev Pauses all releases (emergency only)
     */
    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit TreasuryPaused(msg.sender);
    }

    /**
     * @dev Unpauses releases
     */
    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit TreasuryUnpaused(msg.sender);
    }

    /**
     * @dev Recovers any tokens sent to this contract by mistake (guardian only)
     * @param _token Token address to recover
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        if (_token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // Cannot recover the governed token (only mistakenly sent other tokens)
        if (_token == address(token)) {
            revert InvalidAmount();
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    /**
     * @dev Updates governance module address (emergency only)
     * @param newGovernanceModule New governance module address
     */
    function updateGovernanceModule(address newGovernanceModule) external onlyGuardian {
        if (newGovernanceModule == address(0)) revert ZeroAddress();
        if (governanceModule != address(0)) revert AlreadyInitialized();

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

    /**
     * @dev Returns total token balance in vault
     */
    function getVaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Returns available tokens (not locked by pending proposals)
     * For v1, all tokens are available since proposals don't lock tokens
     */
    function getAvailableBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Returns proposal details
     */
    function getProposal(uint256 proposalId) external view returns (ReleaseProposal memory) {
        return proposals[proposalId];
    }

    /**
     * @dev Returns if proposal can be executed
     */
    function canExecuteProposal(uint256 proposalId) external view returns (bool) {
        ReleaseProposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0 || proposal.executed || proposal.cancelled) {
            return false;
        }

        if (block.timestamp < proposal.createdAt + TIMELOCK_DURATION) {
            return false;
        }

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes == 0) {
            return false;
        }

        uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        if (approvalPercentage < APPROVAL_THRESHOLD) {
            return false;
        }

        uint256 quorumThreshold = (proposal.totalVotingPowerAtProposal * 3000) / BASIS_POINTS;
        if (totalVotes < quorumThreshold) {
            return false;
        }

        return true;
    }

    /**
     * @dev Returns voting results for a proposal
     */
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

    /**
     * @dev Returns total tokens released so far
     */
    function getTotalReleased() external view returns (uint256) {
        return totalReleased;
    }
}
