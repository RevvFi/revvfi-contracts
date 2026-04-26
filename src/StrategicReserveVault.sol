// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

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
    uint256 public constant APPROVAL_THRESHOLD = 6600;        // 66% (basis points)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TIMELOCK_DURATION = 14 days;
    uint256 public constant QUORUM_THRESHOLD = 3000;          // 30% of total voting power
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
        uint256 indexed proposalId,
        uint256 amount,
        address indexed recipient,
        address indexed executor
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
    // ========================================================= // =============================================================
====
    
    constructor(
        address    
    constructor(
        address _token,
        address _factory,
        address _platformFeeRec _token,
        address _factory,
        address _platformFeeRecipient
    ) {
       ipient
    ) {
        require(_token != require(_token != address(0), address(0), "StrategicReserve "StrategicReserveVaultVault: zero token");
: zero token");
        require(_factory != address(0), "StrategicReserveVault: zero factory");
        require(_platformFee        require(_factory != address(0), "StrategicReserveVault: zero factory");
        require(_platformFeeRecipient != address(0), "StrategicReserveVault: zero fee recipient");
        
        token = IERC20(_token);
Recipient != address(0), "StrategicReserveVault: zero fee recipient");
        
        token = IERC20(_token);
        factory        factory = _ = _factory;
        platformFeeRecfactory;
        platformFeeRecipient = _platformFeeRecipient = _platformFeeRecipient;
        emergencyPausedipient;
        emergencyPaused = false = false;
        proposalCounter = ;
        proposalCounter = 0;
        totalReleased = 0;
        initialBalance0;
        totalReleased = 0;
        initialBalance = 0;
 = 0;
        
               
        // Setup roles
        _ // Setup roles
        _grantRolegrantRole(DEFAULT_ADMIN(DEFAULT_ADMIN_ROLE_ROLE, _, _factory);
factory);
        _        _grantRolegrantRole(GUARDIAN_RO(GUARDIAN_ROLE, _factory);
       LE, _factory);
        _grant _grantRole(GRole(GUARUARDIANDIAN_ROLE_ROLE, _, _platformFeeRecipient);
   platformFeeRecipient);
    }
    
    // }
    
    // =============================================================
    // Initial =============================================================
    // Initialization Functionsization Functions
    // =========================================================
    // =====
============================================================
    
    /**
        
    /**
     * @ * @dev Initializes thedev Initializes the governance module governance module (called by factory)
     (called by factory)
     * @ * @param _governparam _governanceModule Address of RevvanceModule Address of RevvFiGovernFiGovernance contract
    ance contract
     */
    function initializeGovernance */
    function initializeGovernance(address _governanceModule(address _governanceModule) external) external onlyFactory onlyFactory {
        require(_governanceModule {
        require(_governanceModule != address != address(0(0), "), "StrategicResStrategicReserveVerveVault:ault: zero governance");
        zero governance");
        require(governanceModule require(governanceModule == address == address(0), "(0), "StrategicResStrategicReserveVault: already initializederveVault: already initialized");
        
        governanceModule =");
        
        governanceModule = _go _governancevernanceModule;
Module;
        _        _grantRolegrantRole(GOVERNANCE_ROLE(GOVERNANCE_ROLE, _, _governgovernanceModule);
        
anceModule);
        
        //        // Set initial balance and Set initial balance and start start first quarter
 first quarter
        initialBalance =        initial token.balanceOfBalance = token.b(address(thisalanceOf(address(this));
        _start));
       NewQuarter();
        
 _startNewQuarter        emit();
        
        emit GovernanceModuleUpdated(address GovernanceModuleUpdated(address(0), _(0), _governanceModule);
    }
    
    // =================================governanceModule);
    }
    
    // =============================================================
    // Proposal============================
    // Proposal Functions ( Functions (Called by Governance ModuleCalled by Governance Module)
   )
    // =============================================================
 // =============================================================
    
    /**
     * @    
    /**
     * @dev Creates a new release proposal (called by governance module)
     * @param proposerdev Creates a new release proposal (called by governance module)
     * @param proposer Address of Address of LP who created the proposal
     * @param amount Amount of tokens to release
     LP who created the proposal
     * @param amount Amount of tokens to release
     * @ * @param recipient Address receiving the tokens
     * @param totalVotingPower Total voting powerparam recipient Address receiving the tokens
     * @param totalVotingPower Total voting power at proposal at proposal creation
     * @return creation
     * @return proposalId proposalId ID of created proposal ID of created proposal
     */
    function create
     */
    function createProposalProposal(
        address proposer,
        uint256 amount,
        address recipient,
        uint256 totalVotingPower
   (
        address proposer,
        uint256 amount,
        address recipient,
        uint256 totalVotingPower
    ) external ) external onlyGovernance whenNotPaused returns (uint onlyGovernance whenNotPaused returns (uint256 proposal256 proposalId) {
        require(proposer != address(0), "StrategicResId) {
        require(proposer != address(0), "StrategicReserveVerveVault:ault: zero proposer");
        require zero proposer");
        require(amount(amount >  > 0,0, " "StrategicStrategicReserveVaultReserveVault: zero amount");
: zero amount");
        require(recip        requireient != address((recipient !=0), address(0), "StrategicReserve "StrategicReserveVaultVault: zero: zero recipient");
 recipient");
        
               
        // Check quarterly limit // Check quarterly limit
        uint256
        uint256 quarterLimit quarterLimit = get = getCurrentQuarterLimit();
        uint256 currentQuarterReleasedCurrentQuarterLimit();
        uint256 currentQuarterReleased = getCurrentQuarterReleased = getCurrentQuarterReleased();
        require(amount <= quarterLimit - currentQuarterReleased,();
        require(amount <= quarterLimit - currentQuarterReleased, 
            "StrategicReserveVault 
            "StrategicReserveVault: exceeds: exceeds quarterly limit");
        
 quarterly limit");
        
        // Check contract balance
        require        // Check contract balance
        require(amount <= token(amount <= token.balanceOf(address(this)),.balanceOf(address(this)), 
            
            "Strategic "StrategicReserveVault: insufficientReserveVault: insufficient balance");
        
        proposalCounter balance");
        
        proposalCounter++;
        
++;
        
        proposals[proposalCounter] =        proposals[proposalCounter] = ReleasePro ReleaseProposal({
posal({
            id            id: proposal: proposalCounter,
            proposerCounter,
            proposer:: proposer,
            proposer,
            amount: amount: amount,
 amount,
            recipient            recipient: recipient: recipient,
           ,
            createdAt: createdAt: block.t block.timestamp,
            executedimestamp,
            executedAt:At: 0 0,
            executed:,
            executed: false,
 false,
            cancelled            cancelled: false: false,
           ,
            forV forVotes: 0,
            againstVotes: 0,
            totalVotingPowerAtProposal: totalVotes: 0,
            againstVotes: 0,
            totalVotingPowerAtProposal: totalVotingPower
        });
        
        emitotingPower
        });
        
        emit ProposalCreated(proposalCounter ProposalCreated(proposalCounter, proposer, amount,, proposer, amount, recipient, totalVotingPower recipient, totalVotingPower);
        
);
        
        return proposalCounter;
           return proposalCounter;
    }
    
    /**
     * }
    
    /**
     * @dev Casts vote on a proposal (called by governance module)
     * @param proposalId ID of proposal
     * @param voter Address @dev Casts vote on a proposal (called by governance module)
     * @param proposalId ID of proposal
     * @param voter Address of LP of LP voting
     * @param voting
     * @param support True support True = for, False = for, False = against = against
    
     * @ * @param votingparam votingPower VotingPower Voting power of power of the LP the LP
     */
    function castVote(
        uint256
     */
    function castVote(
        uint256 proposalId proposalId,
       ,
        address voter address voter,
        bool support,
       ,
        bool support,
        uint256 votingPower uint256 votingPower
    ) external
    onlyGovernance proposalExists( ) external onlyGovernance proposalproposalId)Exists(proposalId) proposalNot proposalNotExecuted(proposalIdExecuted(proposalId) {
        require) {
        require(voter(voter != address(0), " != address(0), "StrategicResStrategicReserveVault: zero votererveVault: zero voter");
        require(v");
        require(votingPowerotingPower >  > 0,0, "StrategicReserveVault: zero voting power");
        
        Release "StrategicReserveVault: zero voting power");
        
        ReleaseProposalProposal storage proposal = proposals[pro storage proposal = proposals[proposalIdposalId];
        
        if];
        
        if (support (support) {
            proposal) {
            proposal.forVotes +=.forVotes += votingPower votingPower;
       ;
        } else {
            } else {
            proposal. proposal.againstVotes += votingPoweragainstVotes += votingPower;
       ;
        }
    }
    }
    
    /**
 }
    
    /**
     * @dev     * Executes @dev a proposal after tim Executes a proposalelock after timelock (called by anyone)
     * @param proposalId ID of proposal to execute
     (called by anyone)
     * @param proposalId ID of proposal to execute
     */
    */
    function executeProposal(uint256 function executeProposal(uint256 proposalId) 
 proposalId) 
        external        external 
        nonRe 
        nonReentrantentrant 
        
        whenNot whenNotPaused 
       Paused 
        proposalExists proposalExists(proposalId) 
        proposalNotExec(proposalId) 
        proposalNotExecuted(uted(proposalId)proposalId) 
    {
        
    {
        ReleasePro ReleaseProposal storage proposal =posal storage proposal = proposals[proposal proposals[proposalId];
Id];
        
               
        // Check timelock
 // Check timelock
        require        require(block.timestamp(block.timestamp >= proposal.createdAt >= proposal.createdAt + TIM + TIMELOCK_DURELOCK_DURATION,ATION, 
            "StrategicReserveVault: timelock 
            "StrategicReserveVault: timelock not expired not expired");
        
        //");
        
        // Check approval Check approval threshold (66%)
        uint threshold (66%)
        uint256 totalVotes = proposal.forV256 totalVotes = proposalotes +.forVotes + proposal. proposal.againstVotes;
        requireagainstVotes;
        require(totalV(totalVotes > 0, "otes > 0, "StrategicReserveVStrategicReserveVault:ault: no votes cast");
        
        uint256 approvalPercentage no votes cast");
        
        uint256 approvalPercentage = ( = (proposal.forVotes *proposal.forVotes * BASIS_POINTS) / totalV BASIS_POINTS) / totalVotes;
        require(approotes;
        require(approvalPercentage >= APPROVAL_THvalPercentage >= APPROVAL_THRESHOLD, 
           RESHOLD, 
            "Strategic "StrategicReserveVault: insufficient approval (ReserveVault: insufficient approval (need 66%)");
        
        //need 66%)");
        
        // Check quorum (30% Check quorum (30% of total of total voting power voting power)
        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        require(totalVotes >= quorum)
        uint256 quorumThresholdAmount = (proposal.totalVotingPowerAtProposal * QUORUM_THRESHOLD) / BASIS_POINTS;
        require(totalVotes >= quorumThresholdAmount, "StrategicResThresholdAmount, "StrategicReserveVault: quorumerveVault: quorum not met");
        
 not met");
        
        // Verify quarterly limit still        // Verify quarterly limit still applies (amount might have been partially used applies (amount might have been partially used)
        uint256 quarterLimit)
        uint256 quarterLimit = getCurrentQuarterLimit();
 = getCurrentQuarterLimit();
        uint256 currentQuarterReleased        uint256 currentQuarterReleased = getCurrentQuarter = getCurrentQuarterReleased();
        requireReleased();
        require(pro(proposal.amount <= quarterLimit - currentQuarterReleasedposal.amount <= quarterLimit - currentQuarterReleased, 
            ", 
            "StrategicReserveVStrategicReserveVault:ault: quarterly limit exceeded");
 quarterly limit exceeded");
        
               
        // Execute // Execute release
 release
        uint256 amount        uint256 amount = proposal = proposal.amount;
       .amount;
        address recipient = proposal.recipient;
 address recipient = proposal.recipient;
        
               
        proposal.executed = proposal.executed = true;
        proposal.executedAt = block.t true;
        proposal.executedAt = block.timestamp;
imestamp;
        totalReleased +=        totalReleased += amount;
 amount;
        
        // Update        
        // Update quarterly release tracking
 quarterly release tracking
        _        _updateQuarterlyReleaseupdateQuarterlyRelease(amount(amount);
        
);
        
        token.safeTransfer(recipient, amount);
        
        token.safeTransfer(recipient, amount);
        
        emit ProposalExec        emit ProposalExecuted(proposalId, amount,uted(proposalId, amount recipient, msg.sender);
        emit, recipient, msg.sender);
        emit TokensReleased(amount, TokensReleased(amount, recipient, totalReleased, 
 recipient, totalReleased, 
            currentQuarterReleased + amount, quarterLimit);
    }
    
    /**
     * @dev Cancels a proposal (only if            currentQuarterReleased + amount, quarterLimit);
    }
    
    /**
     * @dev Cancels a proposal (only if not passed and not executed)
 not passed and not executed)
     * @param proposalId ID of     * @param proposalId ID of proposal to cancel
     */
 proposal to cancel
     */
    function cancelProposal(uint    function cancelProposal(uint256 proposalId) 
       256 proposalId) 
        external 
        proposalExists(proposalId) 
        proposalNotExecuted(proposalId) 
    {
        ReleaseProposal storage proposal = proposals[proposalId];
        
        // Only proposer or guardian can cancel
        require(msg.sender == proposal.pro external 
        proposalExists(proposalId) 
        proposalNotExecuted(proposalId) 
    {
        ReleaseProposal storage proposal = proposals[proposalId];
        
        // Only proposer or guardian can cancel
        require(msg.sender == proposal.proposer || hasRole(GUposer || hasRole(GUARDIAN_ROARDIAN_ROLE, msg.sender),
            "StrategicResLE, msg.sender),
            "StrategicReserveVerveVault: not authorized");
        
        //ault: not authorized");
        
        Cannot cancel if proposal // Cannot cancel already passed timel if proposal already passedock
 timelock
        require        require(block(block.t.timestampimestamp < proposal.createdAt + TIM < proposal.createdAt + TIMELOCK_DELOCK_DURATION,
            "URATION,
            "StrategicReserveVault: proposal in timelock");
StrategicReserveVault: proposal in timelock");
        
        proposal.cancelled        
        proposal.cancelled = true = true;
       ;
        emit Proposal emit ProposalCancelled(proposalIdCancelled(proposalId, msg, msg.sender.sender);
   );
    }
    
    // }
    
    // =============================================================
    // Quarterly =============================================================
    // Quarterly Limit Limit Functions
    Functions
    // = // =====================================================================================================================
====
    
       
    /**
     /**
     * @ * @dev Starts a new quarterly tracking period
dev Starts a new quarterly tracking period
     */
    function _start     */
    function _startNewQuarterNewQuarter() internal {
        uint256() internal {
        uint256 quarterStart = (block.t quarterStart = (block.timestamp / QUARimestamp / QUARTER_SECONDS)TER_SECONDS) * QUARTER_SECONDS * QUARTER_SECONDS;
        
        //;
        
        // Check if we already have a quarter for this period
        Check if we already have a quarter for this period
        if ( if (quarterlyquarterlyReleasesReleases.length ==.length == 0 0 || 
 || 
            quarterly            quarterlyReleasesReleases[quarterlyRe[quarterlyReleases.lengthleases.length - 1]. - 1].quarterStartquarterStart != quarter != quarterStart) {
            quarterlyReStart) {
            quarterlyReleases.pushleases.push(Quarter(QuarterlyRelease({
                quarterStartlyRelease({
                quarterStart: quarterStart,
                amount: quarterStart,
                amountReleased:Released: 0
            }));
            
 0
            }));
            
            emit            emit QuarterlyReset QuarterlyReset(quarterStart,(quarterStart, 0 0);
       );
        }
    }
    }
    
    /**
 }
    
    /**
     * @dev Updates     * @dev Updates quarterly quarterly release amount release amount
     * @param amount Amount released in current
     * @param amount Amount released in current quarter
 quarter
     */
     */
    function    function _updateQuarterly _updateQuarterlyRelease(uint256 amountRelease(uint256 amount) internal {
        uint256 currentQuarter = (block.timestamp / QUAR) internal {
        uint256 currentQuarter = (block.timestamp / QUARTER_SECTER_SECONDS)ONDS) * QUARTER * QUARTER_SECONDS;
        
        // Check if_SECONDS;
        
        // Check if we need to start a new we need to start a new quarter
        if quarter
        if (quarter (quarterlyRelyReleases.length == 0 || 
            quarterlyReleasesleases.length == 0 || 
            quarterlyReleases[quarterlyReleases.length - 1[quarterlyReleases.length - 1].quarter].quarterStart !=Start != currentQuarter) {
 currentQuarter) {
            quarterly            quarterlyReleasesReleases.push(QuarterlyRelease({
                quarter.push(QuarterlyRelease({
                quarterStart:Start: currentQuarter currentQuarter,
               ,
                amountReleased:  amountReleased: 0
0
            }));
            emit QuarterlyReset            }));
            emit QuarterlyReset(currentQuarter, 0);
        }
        
(currentQuarter, 0);
        quarterlyReleases[quarterlyReleases        }
        
        quarterlyReleases[quarterlyReleases.length -.length - 1 1].amountReleased += amount;
    }
    
    /**
     * @dev Gets current quarter's release].amountReleased += amount;
    }
    
    /**
     * @dev Gets current quarter's release limit ( limit (2525% of initial balance% of initial balance)
     * @return limit)
     * @return limit Maximum tokens that can be released Maximum tokens that can be released this quarter this quarter
    
     */
    function get */
    function getCurrentQuarterCurrentQuarterLimit()Limit() public view public view returns ( returns (uint256uint256) {
) {
        return (initialBalance        return (initialBalance * QUARTER * QUARTERLY_RELY_RELEASE_LLEASE_LIMITIMIT_BPS) / BASIS_POINTS_BPS) / BASIS_POINTS;
   ;
    }
    
 }
    
    /**
     * @dev Gets current quarter's    /**
     * @dev Gets current quarter's released amount released amount
     * @return released
     * @return released Amount released Amount released this quarter
 this quarter
     */
    function     */
    function getCurrent getCurrentQuarterReleased() public view returnsQuarterReleased() public view returns (uint256) {
        (uint256) {
        uint256 currentQuarter uint256 currentQuarter = ( = (block.tblock.timestamp / QUARimestamp / QUARTER_SECTER_SECONDS) * QUARTERONDS) * QUARTER_SECONDS;
        
        if_SECONDS;
        
        if (quarter (quarterlyRelyReleases.length == 0)leases.length == 0) {
            {
            return 0;
 return 0;
        }
        }
        
               
        QuarterlyRelease memory latest = quarterly QuarterlyRelease memory latest = quarterlyReleases[quarterReleases[quarterlyRelyReleases.length - 1];
        if (latestleases.length - 1];
        if (latest.quarterStart == currentQuarter.quarterStart == currentQuarter) {
            return) {
            return latest.amountReleased;
        }
        
        return 0;
    }
    
    /**
     * @dev Gets remaining quarterly allowance
     * @return remaining Tokens that can still be released latest.amountReleased;
        }
        
        return 0;
    }
    
    /**
     * @dev Gets remaining quarterly allowance
     * @return remaining Tokens that can still be released this quarter
     */
    function getRemainingQuarterlyAllowance() public view returns this quarter
     */
    function getRemainingQuarterlyAllowance() public view returns (uint (uint256)256) {
        uint256 limit = getCurrent {
        uint256 limit =QuarterLimit();
        uint256 released = getCurrentQuarterReleased();
        
        if (released >= limit) {
            return 0;
 getCurrentQuarterLimit();
        uint256 released = getCurrentQuarterReleased();
        
        if (released >= limit) {
            return 0;
        }
        }
        
        return limit - released;
           
        return limit - released;
    }
    
    /**
     * @dev Forces }
    
    /**
     * @dev Forces a new quarter (guardian only, for testing a new quarter (guardian only, for testing/emergency)
     */
    function forceNewQuarter() external onlyGuardian {
/emergency)
     */
    function forceNewQuarter() external onlyGuardian {
        _        _startNewstartNewQuarter();
    }
    
Quarter();
    }
    
    //    // =============================================================
    =============================================================
    // Emergency Functions ( // Emergency Functions (GuardianGuardian Only)
 Only)
    // =================================    // =========================================================================================
    
    /**

    
    /**
     *     * @dev P @dev Pausesauses all releases (emerg all releases (emergency onlyency only)
    )
     */
    */
    function pause() external function pause() external onlyGuardian {
 onlyGuardian {
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender);
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender);
    }
    
    /**
     * @dev Unpauses releases
    }
    
    /**
     * @dev Unpauses releases
     */
    function unpause() external onlyGuard     */
    function unpause() external onlyGuardian {
ian {
        emergency        emergencyPaused = false;
        emit EmergencyPaused = false;
        emit EmergencyUnpaused(msg.sender);
    }
    
    /**
     * @devUnpaused(msg.sender);
    }
    
    /**
     * @dev Recovers Recovers any tokens sent to any tokens sent to this contract this contract by mistake (guardian only)
     * Cannot by mistake (guardian only)
     * Cannot recover the governed recover the governed strategic reserve tokens strategic reserve tokens
     *
     * @param _ @param _token Token address totoken Token address to recover
 recover
     * @param     * @param amount Amount amount Amount to recover to recover
     * @param recipient Recipient address
     */

     * @param recipient Recipient address
     */
    function    function recoverTokens(address _ recoverTokens(address _token,token, uint256 uint256 amount, address recipient amount, address recipient) external onlyGuardian {
) external onlyGuardian {
        require(_token != address        require(_token != address(0), "StrategicReserveVault: zero token(0), "StrategicReserveVault: zero token");
       ");
        require(recipient != address(0), "StrategicReserveVault: zero recipient require(recipient != address(0), "StrategicReserveVault: zero recipient");
        require(amount >");
        require(amount > 0, "StrategicRes 0, "StrategicReserveVault: zero amount");
        
erveVault: zero amount");
        
        // Cannot recover the governed token
        if (_token == address(token)) {
            revert("StrategicRes        // Cannot recover the governed token
        if (_token == address(token)) {
            revert("StrategicReserveVault:erveVault: cannot recover governed token");
        }
        
        IERC20(_token).safeTransfer(recipient, amount cannot recover governed token");
        }
        
        IERC20(_token).safeTransfer(recipient, amount);
        emit Tok);
        emit TokensRecensRecovered(_token, amountovered(_token, amount, recipient);
   , recipient);
    }
    
 }
    
    /**
     * @dev Updates governance module address (guardian only)
     * @param newGovernanceModule New governance module address
    /**
     * @dev Updates governance module address (guardian only)
     * @param newGovernanceModule New governance module address
     */
    function updateGovernanceModule(address newGovernance     */
    function updateGovernanceModule(address newGovernanceModule) external onlyModule) external onlyGuardian {
        require(newGuardian {
        require(newGovernanceModule != address(0),GovernanceModule != address(0), "StrategicReserveVault: zero "StrategicReserveVault: zero address");
        
        address old address");
        
        address oldModule = governanceModule;
        
Module = governanceModule;
        
        if (oldModule !=        if (oldModule != address(0)) {
            address(0)) {
            _rev _revokeRole(GOVERNANCEokeRole(GOVERNANCE_ROLE, old_ROLE, oldModule);
Module);
        }
        }
        
        governanceModule        
        governanceModule = newGovernance = newGovernanceModule;
Module;
        _        _grantRolegrantRole(GOV(GOVERNANCEERNANCE_ROLE, newGovernanceModule);
        
        emit GovernanceModuleUpdated(oldModule, newGovernanceModule);
_ROLE, newGovernanceModule);
        
        emit GovernanceModuleUpdated(oldModule, newGovernanceModule);
    }
    
       }
    
    // = // =====================================================================================================================
====
    // View    // View Functions Functions
   
    // ========================================================= // =============================================================
====
    
       
    /**
     /**
     * @dev Returns * @dev Returns total token total token balance balance in vault
 in vault
     */
     */
    function getV    function getVaultBalance() external view returnsaultBalance() external view returns (uint (uint256)256) {
        return token {
        return token.balanceOf(address.balanceOf(address(this));
    }
(this));
    }
    
    /**
     * @    
    /**
     * @dev Returns available tokens (notdev Returns available tokens (not locked by quarterly limit locked by quarterly limit)
    )
     */
    function getAvailableBalance() external view returns (uint256) {
        return getRemainingQuarterlyAllowance */
    function getAvailableBalance() external view returns (uint256) {
        return getRemainingQuarterlyAllowance();
    }
    
    /**
     *();
    }
    
    /**
     * @dev Returns proposal details
 @dev Returns proposal details
     */
    function getPro     */
    function getProposal(uint256 proposalId)posal(uint256 proposalId) external view returns (ReleaseProposal memory external view returns (ReleaseProposal memory) {
        return proposals[proposal) {
        return proposals[proposalId];
    }
Id];
    }
    
       
    /**
     * @dev Returns if proposal can be executed
     */
    function canExecuteProposal(uint256 proposalId) external /**
     * @dev Returns if proposal can be executed
     */
    function canExecuteProposal(uint256 proposalId) external view view returns (bool returns (bool) {
) {
        Release        ReleaseProposal storage proposal = proposalsProposal storage proposal = proposals[pro[proposalId];
        if (posalId];
        if (proposal.createdAtproposal.createdAt ==  == 0 || proposal.executed || proposal.cancelled)0 || proposal.executed || proposal.cancelled) {
 {
            return            return false;
        }
 false;
        }
        
        if (        
        if (block.timestamp < proposal.createdAt + TIMELOCK_Dblock.timestamp < proposal.createdAt + TIMELOCK_DURATION) {
URATION) {
            return false;
        }
        
        uint256 totalVotes = proposal.forVotes + proposal.against            return false;
        }
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVVotes;
        if (totalVotes ==otes == 0) {
            return 0) {
            return false;
        }
 false;
        }
        
               
        uint256 approvalPercentage uint256 approvalPercentage = ( = (proposalproposal.forV.forVotes * BASIS_POINTS) / totalVotes * BASIS_POINTS) / totalVotes;
otes;
        if        if (appro (approvalPercentagevalPercentage < APPROVAL_TH < APPROVAL_THRESHRESHOLD) {
           OLD) {
            return false return false;
        }
        
;
        }
        
        uint256 qu        uint256 quorumThresholdAmountorumThresholdAmount = = (pro (proposal.totalVotingposal.totalVotingPowerAtProposal * QUORUMPowerAtProposal * QUORUM_THRES_THRESHOLDHOLD) / BASIS_P) / BASIS_POINTS;
        if (OINTS;
        if (totalVtotalVotes < quorumotes < quorumThresholdAmount) {
ThresholdAmount) {
            return            return false;
        }
        
        false;
        }
        
        // Check // Check quarterly limit
        quarterly limit
        uint256 uint256 quarterLimit = getCurrentQuarterLimit();
        quarterLimit = getCurrentQuarterLimit();
        uint256 uint256 currentQuarterReleased = currentQuarterReleased = getCurrent getCurrentQuarterReleasedQuarterReleased();
       ();
        if ( if (proposal.amount > quarterproposal.amount > quarterLimit -Limit - currentQuarterReleased) currentQuarterReleased) {
            {
            return false;
        }
        
 return false;
        }
        
        return        return true;
    }
    
    true;
    }
    
    /**
     /**
     * @ * @dev Returnsdev Returns voting results for a voting results for a proposal
 proposal
     */
    function     */
    function getV getVoteResults(uint256 proposalIdoteResults(uint256 proposalId) external) external view returns (
        uint256 view returns (
        uint256 forVotes,
        uint forVotes,
        uint256 against256 againstVotesVotes,
       ,
        uint256 totalV uint256 totalVotes,
        uintotes,
        uint256 approvalPercentage,
256 approvalPercentage,
        bool        bool meetsThreshold
    meetsThreshold
    ) {
 ) {
        Release        ReleaseProposal storage proposalProposal storage proposal = proposals[proposalId = proposals[proposalId];
        forVotes = proposal.forVotes];
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        totalVotes;
        againstVotes = proposal.againstVotes;
        totalVotes = forVotes + = forVotes + againstVotes againstVotes;
        
        if;
        
        if (total (totalVotes == 0) {
            approvalPercentage = 0;
            meetsThreshold =Votes == 0) {
            approvalPercentage = 0;
            meetsThreshold = false;
 false;
        } else {
            approval        } else {
            approvalPercentage = (forVotesPercentage = (forVotes * BASIS_POINTS) / totalVotes * BASIS_POINTS) / totalVotes;
           ;
            meetsThreshold meetsThreshold = approvalPercentage >= APPROVAL = approvalPercentage >= APPROVAL_THRES_THRESHOLDHOLD;
        }
    }
    
;
        }
    }
    
    /**
     * @dev    /**
     * @dev Returns total tokens released Returns total tokens released so far so far
    
     */
    */
    function get function getTotalReleasedTotalReleased() external() external view returns (uint view returns (uint256)256) {
        {
        return totalReleased;
    }
    
    /**
     return totalReleased;
    }
    
    /**
     * @dev Returns initial balance and percentage remaining
 * @dev Returns initial balance and percentage remaining
     */
    function getReserveStatus() external view returns (
        uint256 initial,
        uint     */
    function getReserveStatus() external view returns (
        uint256 initial,
        uint256 remaining,
        uint256256 remaining,
        uint256 percentageRemaining
    ) percentageRemaining
    ) {
        initial = {
        initial = initialBalance;
        remaining = initialBalance;
        remaining = token.balanceOf token.balanceOf(address(this));
        if (initial > 0(address(this));
        if (initial > 0) {
            percentage) {
            percentageRemaining = (remaining *Remaining = (remaining * BASIS_POINTS) / BASIS_POINTS) / initial;
        }
 initial;
        }
    }
    
    /**
     * @dev Returns quarterly release history
        }
    
    /**
     * @dev Returns quarterly release history
     */
    */
    function get function getQuarterlyQuarterlyReleaseReleaseHistory()History() external view returns (Quarterly external view returns (QuarterlyRelease[]Release[] memory) {
        return quarterlyReleases memory) {
        return quarterlyReleases;
   ;
    }
}

// =============================================================
// Interface for Factory Integration
// = }
}

// =============================================================
// Interface for Factory Integration
// =============================================================

interface IStrategicRes============================================================

interface IStrategicReserveVault {
erveVault {
    function initializeGovernance(address governanceModule) external;
    function create    function initializeGovernance(address governanceModule) external;
    function createProposalProposal(
       (
        address propos address proposer,
er,
        uint256 amount,
        address recipient,
        uint256        uint256 amount,
        address recipient,
        uint256 totalVotingPower totalVotingPower
   
    ) external ) external returns ( returns (uint256uint256);
    function cast);
    function castVoteVote(uint256 proposalId, address(uint256 proposalId, address voter, bool support, uint256 voting voter, bool support, uint256 votingPower) external;
    functionPower) external;
    function executeProposal(uint256 proposal executeProposal(uint256 proposalId) external;
    function cancelProId) external;
    function cancelProposal(uint256 proposalposal(uint256 proposalId) external;
    function getId) external;
    function getVaultBalance() external view returnsVaultBalance() external view returns (uint256);
 (uint256);
    function getAvailableBalance()    function getAvailableBalance() external view returns ( external view returns (uint256uint256);
    function get);
    function getCurrentQuarterCurrentQuarterLimit() external viewLimit() external view returns (uint256 returns (uint256);
   );
    function getCurrentQuarter function getCurrentQuarterReleased() external viewReleased() returns ( external view returns (uint256);
   uint256);
    function get function getRemainingRemainingQuarterlyAllowance() externalQuarterlyAllowance() external view returns view returns (uint256);
 (uint256);
    function pause()    function pause() external;
 external;
    function unp    functionause() external;
}
 unpause() external;
}