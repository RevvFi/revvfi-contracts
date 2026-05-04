// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IStrategicReserveVault.sol";

/**
 * @title StrategicReserveVault
 * @dev Holds strategic reserve tokens with stricter governance controls.
 * @dev Creator has ZERO access. Releases require LP vote with higher threshold.
 * @dev Features: 66% approval threshold, 14-day timelock, quarterly release limits.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract StrategicReserveVault is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant APPROVAL_THRESHOLD = 6600; // 66% (basis points)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TIMELOCK_DURATION = 14 days;
    uint256 public constant QUORUM_THRESHOLD = 3000; // 30% of total voting power
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
    }

    struct QuarterlyRelease {
        uint256 quarterStart;
        uint256 amountReleased;
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;

    // Governance module address
    address public governanceModule;

    // Proposal tracking
    uint256 public proposalCounter;
    mapping(uint256 => ReleaseProposal) public proposals;

    // Release tracking
    uint256 public totalReleased;
    QuarterlyRelease[] public quarterlyReleases;
    uint256 public initialBalance;

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

    event ProposalExecuted(
        uint256 indexed proposalId, uint256 amount, address indexed recipient, address indexed executor
    );

    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);

    event TokensReleased(
        uint256 amount,
        address indexed recipient,
        uint256 totalReleasedSoFar,
        uint256 quarterReleased,
        uint256 quarterLimit
    );

    event GovernanceModuleUpdated(address indexed oldModule, address indexed newModule);
    event EmergencyPaused(address indexed executor);
    event EmergencyUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);
    event QuarterlyReset(uint256 indexed quarterStart, uint256 amountReleased);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyFactory() {
        require(msg.sender == factory, "StrategicReserveVault: not factory");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governanceModule, "StrategicReserveVault: not governance");
        _;
    }

    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "StrategicReserveVault: not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "StrategicReserveVault: emergency paused");
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        require(proposals[proposalId].createdAt > 0, "StrategicReserveVault: proposal not found");
        _;
    }

    modifier proposalNotExecuted(uint256 proposalId) {
        require(!proposals[proposalId].executed, "StrategicReserveVault: proposal already executed");
        require(!proposals[proposalId].cancelled, "StrategicReserveVault: proposal cancelled");
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor(address _token, address _factory, address _platformFeeRecipient) {
        require(_token != address(0), "StrategicReserveVault: zero token");
        require(_factory != address(0), "StrategicReserveVault: zero factory");
        require(_platformFeeRecipient != address(0), "StrategicReserveVault: zero fee recipient");

        token = IERC20(_token);
        factory = _factory;
        platformFeeRecipient = _platformFeeRecipient;
        emergencyPaused = false;
        proposalCounter = 0;
        totalReleased = 0;
        initialBalance = 0;

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
        require(_governanceModule != address(0), "StrategicReserveVault: zero governance");
        require(governanceModule == address(0), "StrategicReserveVault: already initialized");

        governanceModule = _governanceModule;
        _grantRole(GOVERNANCE_ROLE, _governanceModule);

        // Set initial balance and start first quarter
        initialBalance = token.balanceOf(address(this));
        _startNewQuarter();

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
        require(proposer != address(0), "StrategicReserveVault: zero proposer");
        require(amount > 0, "StrategicReserveVault: zero amount");
        require(recipient != address(0), "StrategicReserveVault: zero recipient");

        // Check quarterly limit
        uint256 quarterLimit = getCurrentQuarterLimit();
        uint256 currentQuarterReleased = getCurrentQuarterReleased();
        require(amount <= quarterLimit - currentQuarterReleased, "StrategicReserveVault: exceeds quarterly limit");

        // Check contract balance
        require(amount <= token.balanceOf(address(this)), "StrategicReserveVault: insufficient balance");

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
        require(voter != address(0), "StrategicReserveVault: zero voter");
        require(votingPower > 0, "StrategicReserveVault: zero voting power");

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
        require(
            block.timestamp >= proposal.createdAt + TIMELOCK_DURATION, "StrategicReserveVault: timelock not expired"
        );

        // Check approval threshold (66%)
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes > 0, "StrategicReserveVault: no votes cast");

        uint256 approvalPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        require(approvalPercentage >= APPROVAL_THRESHOLD, "StrategicReserveVault: insufficient approval (need 66%)");

        // Check quorum (30% of total voting power)
        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        require(totalVotes >= quorumThresholdAmount, "StrategicReserveVault: quorum not met");

        // Verify quarterly limit still applies (amount might have been partially used)
        uint256 quarterLimit = getCurrentQuarterLimit();
        uint256 currentQuarterReleased = getCurrentQuarterReleased();
        require(
            proposal.amount <= quarterLimit - currentQuarterReleased, "StrategicReserveVault: quarterly limit exceeded"
        );

        // Execute release
        uint256 amount = proposal.amount;
        address recipient = proposal.recipient;

        proposal.executed = true;
        proposal.executedAt = block.timestamp;
        totalReleased += amount;

        // Update quarterly release tracking
        _updateQuarterlyRelease(amount);

        token.safeTransfer(recipient, amount);

        emit ProposalExecuted(proposalId, amount, recipient, msg.sender);
        emit TokensReleased(amount, recipient, totalReleased, currentQuarterReleased + amount, quarterLimit);
    }

    /**
     * @dev Cancels a proposal (only if not passed and not executed)
     * @param proposalId ID of proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) proposalNotExecuted(proposalId) {
        ReleaseProposal storage proposal = proposals[proposalId];

        // Only proposer or guardian can cancel
        require(
            msg.sender == proposal.proposer || hasRole(GUARDIAN_ROLE, msg.sender),
            "StrategicReserveVault: not authorized"
        );

        // Cannot cancel if proposal already passed timelock
        require(block.timestamp < proposal.createdAt + TIMELOCK_DURATION, "StrategicReserveVault: proposal in timelock");

        proposal.cancelled = true;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // =============================================================
    // Quarterly Limit Functions
    // =============================================================

    /**
     * @dev Starts a new quarterly tracking period
     */
    function _startNewQuarter() internal {
        uint256 quarterStart = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;

        // Check if we already have a quarter for this period
        if (
            quarterlyReleases.length == 0
                || quarterlyReleases[quarterlyReleases.length - 1].quarterStart != quarterStart
        ) {
            quarterlyReleases.push(QuarterlyRelease({quarterStart: quarterStart, amountReleased: 0}));

            emit QuarterlyReset(quarterStart, 0);
        }
    }

    /**
     * @dev Updates quarterly release amount
     * @param amount Amount released in current quarter
     */
    function _updateQuarterlyRelease(uint256 amount) internal {
        uint256 currentQuarter = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;

        // Check if we need to start a new quarter
        if (
            quarterlyReleases.length == 0
                || quarterlyReleases[quarterlyReleases.length - 1].quarterStart != currentQuarter
        ) {
            quarterlyReleases.push(QuarterlyRelease({quarterStart: currentQuarter, amountReleased: 0}));
            emit QuarterlyReset(currentQuarter, 0);
        }

        quarterlyReleases[quarterlyReleases.length - 1].amountReleased += amount;
    }

    /**
     * @dev Gets current quarter's release limit (25% of initial balance)
     * @return limit Maximum tokens that can be released this quarter
     */
    function getCurrentQuarterLimit() public view returns (uint256) {
        return (initialBalance * QUARTERLY_RELEASE_LIMIT_BPS) / BASIS_POINTS;
    }

    /**
     * @dev Gets current quarter's released amount
     * @return released Amount released this quarter
     */
    function getCurrentQuarterReleased() public view returns (uint256) {
        uint256 currentQuarter = (block.timestamp / QUARTER_SECONDS) * QUARTER_SECONDS;

        if (quarterlyReleases.length == 0) {
            return 0;
        }

        QuarterlyRelease memory latest = quarterlyReleases[quarterlyReleases.length - 1];
        if (latest.quarterStart == currentQuarter) {
            return latest.amountReleased;
        }

        return 0;
    }

    /**
     * @dev Gets remaining quarterly allowance
     * @return remaining Tokens that can still be released this quarter
     */
    function getRemainingQuarterlyAllowance() public view returns (uint256) {
        uint256 limit = getCurrentQuarterLimit();
        uint256 released = getCurrentQuarterReleased();

        if (released >= limit) {
            return 0;
        }

        return limit - released;
    }

    /**
     * @dev Forces a new quarter (guardian only, for testing/emergency)
     */
    function forceNewQuarter() external onlyGuardian {
        _startNewQuarter();
    }

    // =============================================================
    // Emergency Functions (Guardian Only)
    // =============================================================

    /**
     * @dev Pauses all releases (emergency only)
     */
    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Unpauses releases
     */
    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    /**
     * @dev Recovers any tokens sent to this contract by mistake (guardian only)
     * Cannot recover the governed strategic reserve tokens
     * @param _token Token address to recover
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        require(_token != address(0), "StrategicReserveVault: zero token");
        require(recipient != address(0), "StrategicReserveVault: zero recipient");
        require(amount > 0, "StrategicReserveVault: zero amount");

        // Cannot recover the governed token
        if (_token == address(token)) {
            revert("StrategicReserveVault: cannot recover governed token");
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    /**
     * @dev Updates governance module address (guardian only)
     * @param newGovernanceModule New governance module address
     */
    function updateGovernanceModule(address newGovernanceModule) external onlyGuardian {
        require(newGovernanceModule != address(0), "StrategicReserveVault: zero address");

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
     * @dev Returns available tokens (not locked by quarterly limit)
     */
    function getAvailableBalance() external view returns (uint256) {
        return getRemainingQuarterlyAllowance();
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

        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        if (totalVotes < quorumThresholdAmount) {
            return false;
        }

        // Check quarterly limit
        uint256 quarterLimit = getCurrentQuarterLimit();
        uint256 currentQuarterReleased = getCurrentQuarterReleased();
        if (proposal.amount > quarterLimit - currentQuarterReleased) {
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

    /**
     * @dev Returns initial balance and percentage remaining
     */
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

    /**
     * @dev Returns quarterly release history
     */
    function getQuarterlyReleaseHistory() external view returns (QuarterlyRelease[] memory) {
        return quarterlyReleases;
    }
}
