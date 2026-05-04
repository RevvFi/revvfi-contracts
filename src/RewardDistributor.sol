// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RewardsDistributor
 * @dev Emits community rewards according to a linear distribution schedule.
 * @dev Tokens are emitted continuously over a predefined duration.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 * @dev NO ARRAYS and NO LOOPS - only mappings for gas efficiency.
 *      Each claimer independently tracks their rewards using a checkpoint system.
 */
contract RewardsDistributor is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_EMISSION_RATE_CHANGE = 1000; // 10% max change per update

    // =============================================================
    // Structs
    // =============================================================

    struct DistributionSchedule {
        uint256 startTime; // When distribution begins
        uint256 endTime; // When distribution ends
        uint256 totalAllocation; // Total tokens to distribute
        uint256 distributedSoFar; // Tokens already distributed
    }

    /**
     * @dev ClaimerInfo using checkpoint pattern - NO ARRAYS
     * Each claimer independently calculates their rewards using global state
     */
    struct ClaimerInfo {
        uint256 checkpointTime; // Last time rewards were calculated for this claimer
        uint256 claimedAmount; // Total rewards already claimed by this claimer
        bool active; // Whether claimer is approved
    }

    /**
     * @dev Global reward state for checkpoint calculations
     */
    struct GlobalRewardState {
        uint256 lastUpdateTime; // Last time global rewards were updated
        uint256 accumulatedRewards; // Total rewards accumulated so far (per share basis)
        uint256 totalActiveClaimers; // Number of active claimers
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;

    // Distribution schedule
    DistributionSchedule public schedule;
    bool public scheduleInitialized;

    // Claimer tracking - ONLY MAPPINGS, NO ARRAYS
    mapping(address => ClaimerInfo) public claimers;
    uint256 public totalActiveClaimers; // Tracks count without array

    // Global reward state for checkpoint calculations
    GlobalRewardState public globalState;

    // Emission rate (tokens per second)
    uint256 public currentEmissionRate;

    // Cumulative distributed amount (for external queries)
    uint256 public cumulativeDistributed;

    // Emergency flag
    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event ScheduleInitialized(uint256 startTime, uint256 endTime, uint256 totalAllocation, uint256 emissionRate);

    event ClaimerAdded(address indexed claimer);
    event ClaimerRemoved(address indexed claimer);
    event ClaimerActivated(address indexed claimer);
    event ClaimerDeactivated(address indexed claimer);

    event RewardsClaimed(address indexed claimer, uint256 amount, uint256 cumulativeDistributed);

    event EmissionRateUpdated(uint256 oldRate, uint256 newRate, address indexed updater);

    event ScheduleExtended(uint256 oldEndTime, uint256 newEndTime, uint256 newTotalAllocation);

    event GlobalStateUpdated(uint256 lastUpdateTime, uint256 accumulatedRewards, uint256 totalActiveClaimers);

    event EmergencyPaused(address indexed executor);
    event EmergencyUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);
    event RewardsDeposited(uint256 amount);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyFactory() {
        require(msg.sender == factory, "RewardsDistributor: not factory");
        _;
    }

    modifier onlyGovernance() {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "RewardsDistributor: not governance");
        _;
    }

    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "RewardsDistributor: not guardian");
        _;
    }

    modifier onlyClaimer() {
        require(claimers[msg.sender].active, "RewardsDistributor: not an active claimer");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "RewardsDistributor: emergency paused");
        _;
    }

    modifier scheduleExists() {
        require(scheduleInitialized, "RewardsDistributor: schedule not initialized");
        _;
    }

    // =============================================================
    // Constructor
    // =============================================================

    constructor(address _token, address _factory, address _platformFeeRecipient) {
        require(_token != address(0), "RewardsDistributor: zero token");
        require(_factory != address(0), "RewardsDistributor: zero factory");
        require(_platformFeeRecipient != address(0), "RewardsDistributor: zero fee recipient");

        token = IERC20(_token);
        factory = _factory;
        platformFeeRecipient = _platformFeeRecipient;

        emergencyPaused = false;
        scheduleInitialized = false;
        totalActiveClaimers = 0;
        cumulativeDistributed = 0;
        currentEmissionRate = 0;

        globalState = GlobalRewardState({lastUpdateTime: 0, accumulatedRewards: 0, totalActiveClaimers: 0});

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _platformFeeRecipient);
        _grantRole(GOVERNANCE_ROLE, _factory);
    }

    // =============================================================
    // Initialization Functions
    // =============================================================

    /**
     * @dev Initializes the distribution schedule (called by factory)
     * @param startTime Timestamp when distribution begins
     * @param endTime Timestamp when distribution ends
     * @param totalAllocation Total tokens to distribute
     */
    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external onlyFactory {
        require(!scheduleInitialized, "RewardsDistributor: already initialized");
        require(startTime > block.timestamp, "RewardsDistributor: start time must be in future");
        require(endTime > startTime, "RewardsDistributor: end time must be after start");
        require(totalAllocation > 0, "RewardsDistributor: zero allocation");

        // Verify tokens are already in this contract
        uint256 balance = token.balanceOf(address(this));
        require(balance >= totalAllocation, "RewardsDistributor: insufficient token balance");

        uint256 emissionRate = totalAllocation / (endTime - startTime);

        schedule = DistributionSchedule({
            startTime: startTime, endTime: endTime, totalAllocation: totalAllocation, distributedSoFar: 0
        });

        currentEmissionRate = emissionRate;
        cumulativeDistributed = 0;
        scheduleInitialized = true;

        // Initialize global state
        globalState.lastUpdateTime = startTime;
        globalState.accumulatedRewards = 0;
        globalState.totalActiveClaimers = 0;

        emit ScheduleInitialized(startTime, endTime, totalAllocation, emissionRate);
    }

    // =============================================================
    // Claimer Management (Governance) - NO LOOPS, ONLY MAPPINGS
    // =============================================================

    /**
     * @dev Adds a new claimer (governance only) - NO LOOP
     * @param claimer Address to add
     */
    function addClaimer(address claimer) external onlyGovernance whenNotPaused {
        require(claimer != address(0), "RewardsDistributor: zero address");
        require(!claimers[claimer].active, "RewardsDistributor: already active");
        require(scheduleInitialized, "RewardsDistributor: schedule not initialized");

        // Update global state before adding new claimer
        _updateGlobalState();

        if (claimers[claimer].checkpointTime == 0) {
            // New claimer - initialize with current global state
            claimers[claimer] = ClaimerInfo({checkpointTime: block.timestamp, claimedAmount: 0, active: true});
        } else {
            claimers[claimer].active = true;
            claimers[claimer].checkpointTime = block.timestamp;
        }

        totalActiveClaimers++;
        globalState.totalActiveClaimers = totalActiveClaimers;

        emit ClaimerAdded(claimer);
        emit ClaimerActivated(claimer);
    }

    /**
     * @dev Removes a claimer (governance only) - NO LOOP
     * @param claimer Address to remove
     */
    function removeClaimer(address claimer) external onlyGovernance {
        require(claimers[claimer].active, "RewardsDistributor: not active");

        // Update global state before removing
        _updateGlobalState();

        // Calculate pending rewards for the claimer being removed
        uint256 pendingRewards = _calculateClaimerRewards(claimer);

        if (pendingRewards > 0) {
            claimers[claimer].claimedAmount += pendingRewards;
            token.safeTransfer(claimer, pendingRewards);
            cumulativeDistributed += pendingRewards;
            emit RewardsClaimed(claimer, pendingRewards, cumulativeDistributed);
        }

        claimers[claimer].active = false;
        claimers[claimer].checkpointTime = block.timestamp;

        totalActiveClaimers--;
        globalState.totalActiveClaimers = totalActiveClaimers;

        emit ClaimerRemoved(claimer);
        emit ClaimerDeactivated(claimer);
    }

    // =============================================================
    // Global State Management - NO LOOPS
    // =============================================================

    /**
     * @dev Updates global accumulated rewards based on elapsed time
     */
    function _updateGlobalState() internal {
        if (!scheduleInitialized) return;
        if (block.timestamp <= globalState.lastUpdateTime) return;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return;

        uint256 currentTime = block.timestamp;
        uint256 endTime = schedule.endTime;
        uint256 updateEndTime = currentTime > endTime ? endTime : currentTime;

        uint256 timeElapsed = updateEndTime - globalState.lastUpdateTime;

        if (timeElapsed > 0 && globalState.totalActiveClaimers > 0) {
            // Calculate rewards accumulated during this period
            uint256 rewardsThisPeriod = timeElapsed * currentEmissionRate;

            // Cap at remaining allocation
            uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            if (rewardsThisPeriod > remainingAllocation) {
                rewardsThisPeriod = remainingAllocation;
            }

            if (rewardsThisPeriod > 0) {
                // Increase accumulated rewards (per claimer basis)
                globalState.accumulatedRewards += rewardsThisPeriod / globalState.totalActiveClaimers;
                schedule.distributedSoFar += rewardsThisPeriod;
                cumulativeDistributed += rewardsThisPeriod;

                emit GlobalStateUpdated(updateEndTime, globalState.accumulatedRewards, globalState.totalActiveClaimers);
            }
        }

        globalState.lastUpdateTime = updateEndTime;
    }

    /**
     * @dev Calculates pending rewards for a specific claimer - NO LOOP
     * @param claimer Address of claimer
     * @return pending Amount of claimable rewards
     */
    function _calculateClaimerRewards(address claimer) internal view returns (uint256 pending) {
        ClaimerInfo memory claimerInfo = claimers[claimer];
        if (!claimerInfo.active) return 0;

        // Get current accumulated rewards (use latest global state)
        uint256 currentAccumulated = globalState.accumulatedRewards;

        // If there's been a recent update that hasn't been checkpointed
        if (
            block.timestamp > globalState.lastUpdateTime && scheduleInitialized
                && schedule.distributedSoFar < schedule.totalAllocation
        ) {
            // Calculate additional rewards since last update
            uint256 currentTime = block.timestamp;
            uint256 endTime = schedule.endTime;
            uint256 calcEndTime = currentTime > endTime ? endTime : currentTime;
            uint256 timeElapsed = calcEndTime - globalState.lastUpdateTime;

            if (timeElapsed > 0 && globalState.totalActiveClaimers > 0) {
                uint256 additionalRewards = timeElapsed * currentEmissionRate;
                uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
                if (additionalRewards > remainingAllocation) {
                    additionalRewards = remainingAllocation;
                }
                if (additionalRewards > 0) {
                    currentAccumulated += additionalRewards / globalState.totalActiveClaimers;
                }
            }
        }

        // Calculate claimable = (currentAccumulated - checkpointAccumulated) * (no multiplier since 1 share per claimer)
        // Since each claimer gets equal share, the difference in accumulated rewards directly gives the claimable amount
        uint256 accrued = currentAccumulated - claimerInfo.checkpointTime;

        return accrued;
    }

    // =============================================================
    // Distribution & Claims - NO LOOPS
    // =============================================================

    /**
     * @dev Claims rewards for the caller
     * @return amount Amount of rewards claimed
     */
    function claimRewards() external nonReentrant whenNotPaused onlyClaimer returns (uint256 amount) {
        // Update global state to latest
        _updateGlobalState();

        // Calculate pending rewards
        amount = _calculateClaimerRewards(msg.sender);
        require(amount > 0, "RewardsDistributor: no rewards to claim");

        // Update claimer's checkpoint to current accumulated rewards
        claimers[msg.sender].checkpointTime = globalState.accumulatedRewards;
        claimers[msg.sender].claimedAmount += amount;

        // Transfer tokens
        token.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount, cumulativeDistributed);

        return amount;
    }

    /**
     * @dev Returns claimable rewards for a specific claimer - NO LOOP
     * @param claimer Address of claimer
     * @return amount Claimable rewards
     */
    function getClaimableRewards(address claimer) public view returns (uint256 amount) {
        if (!scheduleInitialized) return 0;
        if (!claimers[claimer].active) return 0;

        uint256 currentAccumulated = globalState.accumulatedRewards;

        // Calculate additional rewards since last update
        if (block.timestamp > globalState.lastUpdateTime && schedule.distributedSoFar < schedule.totalAllocation) {
            uint256 currentTime = block.timestamp;
            uint256 endTime = schedule.endTime;
            uint256 calcEndTime = currentTime > endTime ? endTime : currentTime;
            uint256 timeElapsed = calcEndTime - globalState.lastUpdateTime;

            if (timeElapsed > 0 && globalState.totalActiveClaimers > 0) {
                uint256 additionalRewards = timeElapsed * currentEmissionRate;
                uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
                if (additionalRewards > remainingAllocation) {
                    additionalRewards = remainingAllocation;
                }
                if (additionalRewards > 0) {
                    currentAccumulated += additionalRewards / globalState.totalActiveClaimers;
                }
            }
        }

        uint256 accrued = currentAccumulated - claimers[claimer].checkpointTime;
        return accrued;
    }

    /**
     * @dev Returns the current distribution rate (tokens per second)
     */
    function getCurrentDistributionRate() public view returns (uint256) {
        if (!scheduleInitialized) return 0;
        if (block.timestamp >= schedule.endTime) return 0;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return 0;

        return currentEmissionRate;
    }

    /**
     * @dev Returns the remaining distribution time
     */
    function getRemainingDistributionTime() public view returns (uint256) {
        if (!scheduleInitialized) return 0;
        if (block.timestamp >= schedule.endTime) return 0;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return 0;

        return schedule.endTime - block.timestamp;
    }

    /**
     * @dev Returns the remaining tokens to distribute
     */
    function getRemainingTokens() public view returns (uint256) {
        if (!scheduleInitialized) return 0;
        return schedule.totalAllocation - schedule.distributedSoFar;
    }

    // =============================================================
    // Governance Functions
    // =============================================================

    /**
     * @dev Updates emission rate (governance only)
     * @param newEmissionRate New emission rate (tokens per second)
     */
    function updateEmissionRate(uint256 newEmissionRate) external onlyGovernance scheduleExists whenNotPaused {
        require(newEmissionRate > 0, "RewardsDistributor: zero rate");

        // Update global state before changing rate
        _updateGlobalState();

        // Calculate maximum allowed change (10% up or down)
        uint256 maxIncrease = currentEmissionRate + (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);
        uint256 maxDecrease = currentEmissionRate - (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);

        require(
            newEmissionRate <= maxIncrease && newEmissionRate >= maxDecrease,
            "RewardsDistributor: rate change exceeds 10%"
        );

        // Verify new rate won't exceed remaining allocation
        uint256 remainingTime = getRemainingDistributionTime();
        uint256 remainingAllocation = getRemainingTokens();
        uint256 projectedDistribution = newEmissionRate * remainingTime;

        if (projectedDistribution > remainingAllocation && remainingTime > 0) {
            // Adjust rate to exactly match remaining allocation
            newEmissionRate = remainingAllocation / remainingTime;
            require(newEmissionRate > 0, "RewardsDistributor: rate too low");
        }

        uint256 oldRate = currentEmissionRate;
        currentEmissionRate = newEmissionRate;

        emit EmissionRateUpdated(oldRate, newEmissionRate, msg.sender);
    }

    /**
     * @dev Extends distribution schedule (governance only)
     * @param newEndTime New end time for distribution
     * @param additionalTokens Additional tokens to add to allocation
     */
    function extendSchedule(uint256 newEndTime, uint256 additionalTokens)
        external
        onlyGovernance
        scheduleExists
        whenNotPaused
    {
        require(newEndTime > schedule.endTime, "RewardsDistributor: end time must be later");
        require(additionalTokens > 0, "RewardsDistributor: zero additional tokens");

        // Update global state before changing schedule
        _updateGlobalState();

        // Verify additional tokens are available
        require(
            token.balanceOf(address(this)) >= getRemainingTokens() + additionalTokens,
            "RewardsDistributor: insufficient token balance"
        );

        uint256 oldEndTime = schedule.endTime;
        uint256 oldTotalAllocation = schedule.totalAllocation;

        schedule.endTime = newEndTime;
        schedule.totalAllocation += additionalTokens;

        // Recalculate emission rate
        uint256 remainingTime = newEndTime - block.timestamp;
        uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
        if (remainingTime > 0) {
            currentEmissionRate = remainingAllocation / remainingTime;
        }

        emit ScheduleExtended(oldEndTime, newEndTime, schedule.totalAllocation);
        emit RewardsDeposited(additionalTokens);
    }

    /**
     * @dev Adds extra rewards without extending schedule (governance only)
     * @param additionalTokens Additional tokens to add
     */
    function addRewards(uint256 additionalTokens) external onlyGovernance scheduleExists whenNotPaused {
        require(additionalTokens > 0, "RewardsDistributor: zero additional tokens");

        // Update global state before adding rewards
        _updateGlobalState();

        // Verify additional tokens are available
        require(
            token.balanceOf(address(this)) >= getRemainingTokens() + additionalTokens,
            "RewardsDistributor: insufficient token balance"
        );

        schedule.totalAllocation += additionalTokens;

        // Recalculate emission rate
        uint256 remainingTime = schedule.endTime - block.timestamp;
        uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
        if (remainingTime > 0) {
            currentEmissionRate = remainingAllocation / remainingTime;
        }

        emit RewardsDeposited(additionalTokens);
    }

    // =============================================================
    // Emergency Functions (Guardian Only)
    // =============================================================

    /**
     * @dev Pauses all claims (emergency only)
     */
    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Unpauses claims
     */
    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    /**
     * @dev Recovers any tokens sent to this contract by mistake (guardian only)
     * Cannot recover the governed reward tokens that are part of active distribution
     * @param _token Token address to recover
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        require(_token != address(0), "RewardsDistributor: zero token");
        require(recipient != address(0), "RewardsDistributor: zero recipient");
        require(amount > 0, "RewardsDistributor: zero amount");

        // Cannot recover the governed token if it's still needed for distribution
        if (_token == address(token) && scheduleInitialized) {
            uint256 requiredBalance = getRemainingTokens();
            uint256 currentBalance = token.balanceOf(address(this));
            require(amount <= currentBalance - requiredBalance, "RewardsDistributor: cannot recover allocated rewards");
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    /**
     * @dev Force updates global state (guardian only, for manual trigger)
     */
    function forceUpdateGlobalState() external onlyGuardian {
        _updateGlobalState();
    }

    // =============================================================
    // View Functions
    // =============================================================

    /**
     * @dev Returns distribution schedule details
     */
    function getDistributionSchedule()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 totalAllocation,
            uint256 distributedSoFar,
            uint256 remainingAllocation
        )
    {
        return (
            schedule.startTime,
            schedule.endTime,
            schedule.totalAllocation,
            schedule.distributedSoFar,
            schedule.totalAllocation - schedule.distributedSoFar
        );
    }

    /**
     * @dev Returns claimer info
     */
    function getClaimerInfo(address claimer)
        external
        view
        returns (uint256 checkpointTime, uint256 claimedAmount, bool active, uint256 pendingRewards)
    {
        ClaimerInfo memory info = claimers[claimer];
        return (info.checkpointTime, info.claimedAmount, info.active, getClaimableRewards(claimer));
    }

    /**
     * @dev Returns total active claimers count
     */
    function getTotalActiveClaimers() external view returns (uint256) {
        return totalActiveClaimers;
    }

    /**
     * @dev Returns distribution progress percentage
     */
    function getDistributionProgress() external view returns (uint256 percentage) {
        if (!scheduleInitialized) return 0;
        if (schedule.totalAllocation == 0) return 0;
        return (schedule.distributedSoFar * BASIS_POINTS) / schedule.totalAllocation;
    }

    /**
     * @dev Returns global state
     */
    function getGlobalState()
        external
        view
        returns (uint256 lastUpdateTime, uint256 accumulatedRewards, uint256 totalActive)
    {
        return (globalState.lastUpdateTime, globalState.accumulatedRewards, globalState.totalActiveClaimers);
    }
}

