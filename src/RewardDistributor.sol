// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RewardsDistributor
 * @dev Emits community rewards according to a linear distribution schedule.
 * @dev Tokens are emitted continuously over a predefined duration.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
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

    struct ClaimerInfo {
        uint256 lastClaimTime; // Last timestamp claimer claimed rewards
        uint256 pendingRewards; // Rewards accrued but not claimed
        bool active; // Whether claimer is approved
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

    // Claimer tracking
    mapping(address => ClaimerInfo) public claimers;
    address[] public activeClaimers;
    uint256 public totalActiveClaimers;

    // Emission rate (tokens per second)
    uint256 public currentEmissionRate;

    // Last time distribution was updated
    uint256 public lastDistributionUpdate;

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

    event DistributionUpdated(uint256 distributedSinceLastUpdate, uint256 cumulativeDistributed);

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
        lastDistributionUpdate = 0;

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
        lastDistributionUpdate = startTime;
        scheduleInitialized = true;

        emit ScheduleInitialized(startTime, endTime, totalAllocation, emissionRate);
    }

    // =============================================================
    // Claimer Management (Governance)
    // =============================================================

    /**
     * @dev Adds a new claimer (governance only)
     * @param claimer Address to add
     */
    function addClaimer(address claimer) external onlyGovernance whenNotPaused {
        require(claimer != address(0), "RewardsDistributor: zero address");
        require(!claimers[claimer].active, "RewardsDistributor: already active");

        if (claimers[claimer].lastClaimTime == 0) {
            claimers[claimer] = ClaimerInfo({lastClaimTime: block.timestamp, pendingRewards: 0, active: true});
            activeClaimers.push(claimer);
            totalActiveClaimers++;
        } else {
            claimers[claimer].active = true;
        }

        emit ClaimerAdded(claimer);
        emit ClaimerActivated(claimer);
    }

    /**
     * @dev Adds multiple claimers in batch (governance only)
     * @param claimersList Array of addresses to add
     */
    function addClaimers(address[] calldata claimersList) external onlyGovernance whenNotPaused {
        for (uint256 i = 0; i < claimersList.length; i++) {
            addClaimer(claimersList[i]);
        }
    }

    /**
     * @dev Removes a claimer (governance only)
     * @param claimer Address to remove
     */
    function removeClaimer(address claimer) external onlyGovernance {
        require(claimers[claimer].active, "RewardsDistributor: not active");

        // Update pending rewards before removing
        _updateDistribution();

        if (claimers[claimer].pendingRewards > 0) {
            // Transfer pending rewards before deactivating
            uint256 pending = claimers[claimer].pendingRewards;
            claimers[claimer].pendingRewards = 0;
            claimers[claimer].active = false;
            claimers[claimer].lastClaimTime = block.timestamp;

            token.safeTransfer(claimer, pending);
            cumulativeDistributed += pending;

            emit RewardsClaimed(claimer, pending, cumulativeDistributed);
        } else {
            claimers[claimer].active = false;
            claimers[claimer].lastClaimTime = block.timestamp;
        }

        emit ClaimerRemoved(claimer);
        emit ClaimerDeactivated(claimer);
    }

    // =============================================================
    // Distribution & Claims
    // =============================================================

    /**
     * @dev Updates distribution state (accrues rewards to claimers)
     */
    function _updateDistribution() internal {
        if (!scheduleInitialized) return;
        if (block.timestamp <= lastDistributionUpdate) return;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return;

        uint256 currentTime = block.timestamp;
        uint256 endTime = schedule.endTime;

        // Calculate distribution cut-off time
        uint256 distributionEndTime = currentTime > endTime ? endTime : currentTime;

        // Calculate time elapsed since last update
        uint256 timeElapsed = distributionEndTime - lastDistributionUpdate;

        if (timeElapsed > 0 && totalActiveClaimers > 0) {
            // Calculate rewards to distribute
            uint256 rewardsToDistribute = timeElapsed * currentEmissionRate;

            // Cap at remaining allocation
            uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            if (rewardsToDistribute > remainingAllocation) {
                rewardsToDistribute = remainingAllocation;
            }

            if (rewardsToDistribute > 0) {
                // Distribute proportionally to all active claimers
                uint256 rewardsPerClaimer = rewardsToDistribute / totalActiveClaimers;
                uint256 remainder = rewardsToDistribute % totalActiveClaimers;

                // Update pending rewards for each active claimer
                for (uint256 i = 0; i < activeClaimers.length; i++) {
                    address claimer = activeClaimers[i];
                    if (claimers[claimer].active) {
                        claimers[claimer].pendingRewards += rewardsPerClaimer;
                    }
                }

                // Add remainder to first claimer
                if (remainder > 0 && activeClaimers.length > 0) {
                    address firstClaimer = activeClaimers[0];
                    if (claimers[firstClaimer].active) {
                        claimers[firstClaimer].pendingRewards += remainder;
                    }
                }

                schedule.distributedSoFar += rewardsToDistribute;
                cumulativeDistributed += rewardsToDistribute;

                emit DistributionUpdated(rewardsToDistribute, cumulativeDistributed);
            }
        }

        lastDistributionUpdate = distributionEndTime;
    }

    /**
     * @dev Claims rewards for the caller
     * @return amount Amount of rewards claimed
     */
    function claimRewards() external nonReentrant whenNotPaused onlyClaimer returns (uint256 amount) {
        _updateDistribution();

        amount = claimers[msg.sender].pendingRewards;
        require(amount > 0, "RewardsDistributor: no rewards to claim");

        claimers[msg.sender].pendingRewards = 0;
        claimers[msg.sender].lastClaimTime = block.timestamp;

        token.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount, cumulativeDistributed);

        return amount;
    }

    /**
     * @dev Returns claimable rewards for a specific claimer
     * @param claimer Address of claimer
     * @return amount Claimable rewards
     */
    function getClaimableRewards(address claimer) public view returns (uint256 amount) {
        if (!scheduleInitialized) return 0;
        if (!claimers[claimer].active) return claimers[claimer].pendingRewards;

        uint256 pending = claimers[claimer].pendingRewards;

        if (block.timestamp <= lastDistributionUpdate) return pending;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return pending;

        uint256 currentTime = block.timestamp;
        uint256 endTime = schedule.endTime;
        uint256 distributionEndTime = currentTime > endTime ? endTime : currentTime;
        uint256 timeElapsed = distributionEndTime - lastDistributionUpdate;

        if (timeElapsed > 0 && totalActiveClaimers > 0) {
            uint256 rewardsToDistribute = timeElapsed * currentEmissionRate;
            uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            if (rewardsToDistribute > remainingAllocation) {
                rewardsToDistribute = remainingAllocation;
            }

            uint256 rewardsPerClaimer = rewardsToDistribute / totalActiveClaimers;
            uint256 remainder = rewardsToDistribute % totalActiveClaimers;

            pending += rewardsPerClaimer;

            // Add remainder if this is the first claimer
            if (activeClaimers.length > 0 && activeClaimers[0] == claimer) {
                pending += remainder;
            }
        }

        return pending;
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

        // Update distribution before changing rate
        _updateDistribution();

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

        if (projectedDistribution > remainingAllocation) {
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

        // Update distribution before changing schedule
        _updateDistribution();

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
        currentEmissionRate = remainingAllocation / remainingTime;

        emit ScheduleExtended(oldEndTime, newEndTime, schedule.totalAllocation);
        emit RewardsDeposited(additionalTokens);
    }

    /**
     * @dev Adds extra rewards without extending schedule (governance only)
     * @param additionalTokens Additional tokens to add
     */
    function addRewards(uint256 additionalTokens) external onlyGovernance scheduleExists whenNotPaused {
        require(additionalTokens > 0, "RewardsDistributor: zero additional tokens");

        // Update distribution before adding rewards
        _updateDistribution();

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
            uint256 recoverable = currentBalance - requiredBalance;
            require(amount <= recoverable, "RewardsDistributor: cannot recover allocated rewards");
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    /**
     * @dev Force updates distribution (guardian only, for manual trigger)
     */
    function forceUpdateDistribution() external onlyGuardian {
        _updateDistribution();
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
        returns (uint256 lastClaimTime, uint256 pendingRewards, bool active)
    {
        return (claimers[claimer].lastClaimTime, getClaimableRewards(claimer), claimers[claimer].active);
    }

    /**
     * @dev Returns all active claimers
     */
    function getAllActiveClaimers() external view returns (address[] memory) {
        return activeClaimers;
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
}

// =============================================================
// Interface for Factory Integration
// =============================================================

interface IRewardsDistributor {
    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external;
    function addClaimer(address claimer) external;
    function addClaimers(address[] calldata claimers) external;
    function removeClaimer(address claimer) external;
    function claimRewards() external returns (uint256);
    function getClaimableRewards(address claimer) external view returns (uint256);
    function updateEmissionRate(uint256 newEmissionRate) external;
    function extendSchedule(uint256 newEndTime, uint256 additionalTokens) external;
    function addRewards(uint256 additionalTokens) external;
    function pause() external;
    function unpause() external;
}
