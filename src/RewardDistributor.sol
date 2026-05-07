// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RewardsDistributor
 * @dev Emits community rewards according to a linear distribution schedule.
 * @dev Uses MasterChef-style reward accounting with scaled precision.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract RewardsDistributor is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================
    // Roles
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_EMISSION_RATE_CHANGE = 1000; // 10% max change per update
    uint256 public constant PRECISION = 1e18; // For reward accumulation

    // =============================================================
    // Structs
    // =============================================================

    struct DistributionSchedule {
        uint256 startTime;
        uint256 endTime;
        uint256 totalAllocation;
        uint256 distributedSoFar;
        bool active;
    }

    /**
     * @dev ClaimerInfo using reward debt pattern (MasterChef style)
     * No mixing of timestamps and reward units
     */
    struct ClaimerInfo {
        uint256 rewardDebt; // Amount of rewards already accounted for this claimer (scaled)
        uint256 pendingRewards; // Rewards accrued but not claimed
        bool active;
    }

    struct GlobalRewardState {
        uint256 lastUpdateTime;
        uint256 accRewardsPerShare; // Scaled by PRECISION
        uint256 totalActiveClaimers;
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;

    DistributionSchedule public schedule;
    bool public scheduleInitialized;

    mapping(address => ClaimerInfo) public claimers;
    uint256 public totalActiveClaimers;

    GlobalRewardState public globalState;

    uint256 public currentEmissionRate;
    uint256 public cumulativeAccrued; // Total rewards accrued (not distributed)
    uint256 public cumulativeDistributed; // Total rewards actually transferred

    bool public emergencyPaused;

    // Track undistributed dust
    uint256 public undistributedDust;

    // =============================================================
    // Events
    // =============================================================

    event ScheduleInitialized(uint256 startTime, uint256 endTime, uint256 totalAllocation, uint256 emissionRate);
    event ClaimerAdded(address indexed claimer);
    event ClaimerRemoved(address indexed claimer);
    event RewardsClaimed(address indexed claimer, uint256 amount, uint256 totalClaimed);
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate, address indexed updater);
    event ScheduleExtended(uint256 oldEndTime, uint256 newEndTime, uint256 additionalTokens);
    event GlobalStateUpdated(uint256 lastUpdateTime, uint256 accRewardsPerShare, uint256 totalActiveClaimers);
    event DustRecovered(uint256 amount, address indexed recipient);
    event EmergencyPaused(address indexed executor);
    event EmergencyUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);
    event RewardsDeposited(uint256 amount);
    event RewardsAccrued(uint256 amount, uint256 rewardsPerShareDelta);

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

    modifier onlyActiveClaimer() {
        require(claimers[msg.sender].active, "RewardsDistributor: not active claimer");
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

    modifier distributionActive() {
        require(scheduleInitialized && schedule.active, "RewardsDistributor: distribution not active");
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
        cumulativeAccrued = 0;
        cumulativeDistributed = 0;
        currentEmissionRate = 0;
        undistributedDust = 0;

        globalState = GlobalRewardState({lastUpdateTime: 0, accRewardsPerShare: 0, totalActiveClaimers: 0});

        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _platformFeeRecipient);
        _grantRole(GOVERNANCE_ROLE, _factory);
    }

    // =============================================================
    // Initialization
    // =============================================================

    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external onlyFactory {
        require(!scheduleInitialized, "RewardsDistributor: already initialized");
        require(startTime > block.timestamp, "RewardsDistributor: start time must be in future");
        require(endTime > startTime, "RewardsDistributor: end time must be after start");
        require(totalAllocation > 0, "RewardsDistributor: zero allocation");

        uint256 balance = token.balanceOf(address(this));
        require(balance >= totalAllocation, "RewardsDistributor: insufficient token balance");

        uint256 duration = endTime - startTime;
        uint256 emissionRate = totalAllocation / duration;
        require(emissionRate > 0, "RewardsDistributor: emission rate too low");

        schedule = DistributionSchedule({
            startTime: startTime, endTime: endTime, totalAllocation: totalAllocation, distributedSoFar: 0, active: true
        });

        currentEmissionRate = emissionRate;
        scheduleInitialized = true;

        globalState.lastUpdateTime = startTime;
        globalState.accRewardsPerShare = 0;
        globalState.totalActiveClaimers = 0;

        emit ScheduleInitialized(startTime, endTime, totalAllocation, emissionRate);
    }

    // =============================================================
    // Claimer Management - NO LOOPS
    // =============================================================

    function addClaimer(address claimer) external onlyGovernance whenNotPaused distributionActive {
        require(claimer != address(0), "RewardsDistributor: zero address");
        require(!claimers[claimer].active, "RewardsDistributor: already active");

        // Update global state first
        _updateGlobalState();

        ClaimerInfo storage info = claimers[claimer];

        if (info.rewardDebt == 0 && info.pendingRewards == 0) {
            // New claimer - initialize with current reward debt
            info.rewardDebt = globalState.accRewardsPerShare;
            info.pendingRewards = 0;
            info.active = true;
        } else {
            // Reactivating existing claimer
            info.active = true;
            info.rewardDebt = globalState.accRewardsPerShare;
        }

        totalActiveClaimers++;
        globalState.totalActiveClaimers = totalActiveClaimers;

        emit ClaimerAdded(claimer);
    }

    function removeClaimer(address claimer) external onlyGovernance {
        require(claimers[claimer].active, "RewardsDistributor: not active");

        _updateGlobalState();

        ClaimerInfo storage info = claimers[claimer];

        // Calculate pending rewards using proper reward debt
        uint256 pending = _calculateRewards(claimer);

        if (pending > 0) {
            info.pendingRewards = 0;
            info.rewardDebt = globalState.accRewardsPerShare;

            // Transfer immediately
            token.safeTransfer(claimer, pending);
            cumulativeDistributed += pending;
            emit RewardsClaimed(claimer, pending, cumulativeDistributed);
        }

        info.active = false;
        totalActiveClaimers--;
        globalState.totalActiveClaimers = totalActiveClaimers;

        emit ClaimerRemoved(claimer);
    }

    // =============================================================
    // Core Accounting - MasterChef Style
    // =============================================================

    /**
     * @dev Updates global accumulated rewards - DOES NOT skip time when no claimers
     */
    function _updateGlobalState() internal {
        if (!scheduleInitialized || !schedule.active) return;
        require(block.timestamp >= schedule.startTime, "RewardsDistributor: distribution not started");

        if (block.timestamp <= globalState.lastUpdateTime) return;
        if (schedule.distributedSoFar >= schedule.totalAllocation) {
            schedule.active = false;
            return;
        }

        uint256 currentTime = block.timestamp;
        uint256 endTime = schedule.endTime;
        uint256 updateEndTime = currentTime > endTime ? endTime : currentTime;
        uint256 timeElapsed = updateEndTime - globalState.lastUpdateTime;

        if (timeElapsed > 0) {
            // Calculate rewards for this period - even if no claimers
            uint256 rewardsThisPeriod = timeElapsed * currentEmissionRate;

            uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            if (rewardsThisPeriod > remainingAllocation) {
                rewardsThisPeriod = remainingAllocation;
            }

            if (rewardsThisPeriod > 0) {
                // Track rewards even when no claimers exist (carry forward)
                if (globalState.totalActiveClaimers > 0) {
                    // Scale by PRECISION to avoid dust loss
                    uint256 rewardsPerShareDelta = (rewardsThisPeriod * PRECISION) / globalState.totalActiveClaimers;
                    globalState.accRewardsPerShare += rewardsPerShareDelta;

                    // Track remaining dust
                    uint256 accountedRewards = (rewardsPerShareDelta * globalState.totalActiveClaimers) / PRECISION;
                    if (accountedRewards < rewardsThisPeriod) {
                        undistributedDust += rewardsThisPeriod - accountedRewards;
                    }
                } else {
                    // No claimers - rewards accumulate for future claimers
                    // They will be accounted when claimers are added
                    uint256 pendingRewards = rewardsThisPeriod;
                    // Store in a way that can be distributed when claimers join
                    // For simplicity, we track undistributedDust
                    undistributedDust += pendingRewards;
                }

                schedule.distributedSoFar += rewardsThisPeriod;
                cumulativeAccrued += rewardsThisPeriod;

                emit RewardsAccrued(rewardsThisPeriod, globalState.accRewardsPerShare);

                if (schedule.distributedSoFar >= schedule.totalAllocation) {
                    schedule.active = false;
                }
            }
        }

        globalState.lastUpdateTime = updateEndTime;
        emit GlobalStateUpdated(updateEndTime, globalState.accRewardsPerShare, globalState.totalActiveClaimers);
    }

    /**
     * @dev Calculates pending rewards for a claimer
     */
    function _calculateRewards(address claimer) internal view returns (uint256) {
        ClaimerInfo memory info = claimers[claimer];
        if (!info.active) return 0;
        if (globalState.accRewardsPerShare <= info.rewardDebt) return info.pendingRewards;

        uint256 earned = (globalState.accRewardsPerShare - info.rewardDebt) / PRECISION;
        return info.pendingRewards + earned;
    }

    /**
     * @dev Claims rewards for the caller
     */
    function claimRewards() external nonReentrant whenNotPaused onlyActiveClaimer returns (uint256 amount) {
        require(block.timestamp >= schedule.startTime, "RewardsDistributor: distribution not started");

        _updateGlobalState();

        amount = _calculateRewards(msg.sender);
        require(amount > 0, "RewardsDistributor: no rewards to claim");

        ClaimerInfo storage info = claimers[msg.sender];
        info.pendingRewards = 0;
        info.rewardDebt = globalState.accRewardsPerShare;

        token.safeTransfer(msg.sender, amount);
        cumulativeDistributed += amount;

        emit RewardsClaimed(msg.sender, amount, cumulativeDistributed);

        return amount;
    }

    /**
     * @dev Returns claimable rewards (view)
     */
    function getClaimableRewards(address claimer) public view returns (uint256) {
        if (!scheduleInitialized || !schedule.active) return 0;
        if (!claimers[claimer].active) return 0;

        uint256 accRewardsPerShare = globalState.accRewardsPerShare;

        // Calculate pending additional rewards if not updated
        if (block.timestamp > globalState.lastUpdateTime && schedule.distributedSoFar < schedule.totalAllocation) {
            uint256 currentTime = block.timestamp;
            uint256 endTime = schedule.endTime;
            uint256 calcEndTime = currentTime > endTime ? endTime : currentTime;
            uint256 timeElapsed = calcEndTime - globalState.lastUpdateTime;

            if (timeElapsed > 0) {
                uint256 additionalRewards = timeElapsed * currentEmissionRate;
                uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
                if (additionalRewards > remainingAllocation) {
                    additionalRewards = remainingAllocation;
                }
                if (additionalRewards > 0 && globalState.totalActiveClaimers > 0) {
                    accRewardsPerShare += (additionalRewards * PRECISION) / globalState.totalActiveClaimers;
                }
            }
        }

        ClaimerInfo memory info = claimers[claimer];
        uint256 earned = 0;
        if (accRewardsPerShare > info.rewardDebt) {
            earned = (accRewardsPerShare - info.rewardDebt) / PRECISION;
        }
        return info.pendingRewards + earned;
    }

    // =============================================================
    // Governance Functions
    // =============================================================

    function updateEmissionRate(uint256 newEmissionRate) external onlyGovernance scheduleExists whenNotPaused {
        require(newEmissionRate > 0, "RewardsDistributor: zero rate");

        _updateGlobalState();

        uint256 maxIncrease = currentEmissionRate + (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);
        uint256 maxDecrease = currentEmissionRate - (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);

        require(
            newEmissionRate <= maxIncrease && newEmissionRate >= maxDecrease,
            "RewardsDistributor: rate change exceeds 10%"
        );

        uint256 remainingTime = _getRemainingDistributionTime();
        uint256 remainingAllocation = getRemainingTokens();
        uint256 projectedDistribution = newEmissionRate * remainingTime;

        if (projectedDistribution > remainingAllocation && remainingTime > 0) {
            newEmissionRate = remainingAllocation / remainingTime;
            require(newEmissionRate > 0, "RewardsDistributor: rate too low");
        }

        uint256 oldRate = currentEmissionRate;
        currentEmissionRate = newEmissionRate;

        emit EmissionRateUpdated(oldRate, newEmissionRate, msg.sender);
    }

    function extendSchedule(uint256 newEndTime, uint256 additionalTokens)
        external
        onlyGovernance
        scheduleExists
        whenNotPaused
    {
        require(newEndTime > schedule.endTime, "RewardsDistributor: end time must be later");

        _updateGlobalState();

        uint256 requiredBalance = getRemainingTokens() + additionalTokens;
        require(token.balanceOf(address(this)) >= requiredBalance, "RewardsDistributor: insufficient token balance");

        schedule.endTime = newEndTime;
        schedule.totalAllocation += additionalTokens;
        schedule.active = true;

        uint256 remainingTime = newEndTime - block.timestamp;
        uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
        if (remainingTime > 0) {
            currentEmissionRate = remainingAllocation / remainingTime;
            require(currentEmissionRate > 0, "RewardsDistributor: rate too low");
        }

        emit ScheduleExtended(schedule.endTime, newEndTime, additionalTokens);
        emit RewardsDeposited(additionalTokens);
    }

    function addRewards(uint256 additionalTokens) external onlyGovernance scheduleExists whenNotPaused {
        require(additionalTokens > 0, "RewardsDistributor: zero additional tokens");

        _updateGlobalState();

        uint256 remainingAllocation = getRemainingTokens();
        require(
            token.balanceOf(address(this)) >= remainingAllocation + additionalTokens,
            "RewardsDistributor: insufficient token balance"
        );

        schedule.totalAllocation += additionalTokens;
        schedule.active = true;

        uint256 remainingTime = _getRemainingDistributionTime();
        if (remainingTime > 0) {
            uint256 newRemainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            currentEmissionRate = newRemainingAllocation / remainingTime;
        }

        emit RewardsDeposited(additionalTokens);
    }

    function recoverDust(uint256 amount, address recipient) external onlyGuardian {
        require(recipient != address(0), "RewardsDistributor: zero recipient");
        require(amount > 0 && amount <= undistributedDust, "RewardsDistributor: invalid amount");

        undistributedDust -= amount;
        token.safeTransfer(recipient, amount);
        emit DustRecovered(amount, recipient);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getCurrentDistributionRate() public view returns (uint256) {
        if (!scheduleInitialized || !schedule.active) return 0;
        if (block.timestamp >= schedule.endTime) return 0;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return 0;
        return currentEmissionRate;
    }

    function _getRemainingDistributionTime() internal view returns (uint256) {
        if (!scheduleInitialized) return 0;
        if (block.timestamp >= schedule.endTime) return 0;
        if (schedule.distributedSoFar >= schedule.totalAllocation) return 0;
        return schedule.endTime - block.timestamp;
    }

    function getRemainingDistributionTime() external view returns (uint256) {
        return _getRemainingDistributionTime();
    }

    function getRemainingTokens() public view returns (uint256) {
        if (!scheduleInitialized) return 0;
        return schedule.totalAllocation - schedule.distributedSoFar;
    }

    function getDistributionSchedule()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 totalAllocation,
            uint256 distributedSoFar,
            uint256 remainingAllocation,
            bool active
        )
    {
        return (
            schedule.startTime,
            schedule.endTime,
            schedule.totalAllocation,
            schedule.distributedSoFar,
            schedule.totalAllocation - schedule.distributedSoFar,
            schedule.active
        );
    }

    function getClaimerInfo(address claimer)
        external
        view
        returns (uint256 rewardDebt, uint256 pendingRewards, bool active, uint256 claimable)
    {
        ClaimerInfo memory info = claimers[claimer];
        return (info.rewardDebt, info.pendingRewards, info.active, getClaimableRewards(claimer));
    }

    function getTotalActiveClaimers() external view returns (uint256) {
        return totalActiveClaimers;
    }

    function getDistributionProgress() external view returns (uint256 percentage) {
        if (!scheduleInitialized) return 0;
        if (schedule.totalAllocation == 0) return 0;
        return (schedule.distributedSoFar * BASIS_POINTS) / schedule.totalAllocation;
    }

    function getGlobalState()
        external
        view
        returns (uint256 lastUpdateTime, uint256 accRewardsPerShare, uint256 totalActiveClaimers)
    {
        return (globalState.lastUpdateTime, globalState.accRewardsPerShare, globalState.totalActiveClaimers);
    }

    // =============================================================
    // Emergency Functions
    // =============================================================

    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        require(_token != address(0), "RewardsDistributor: zero token");
        require(recipient != address(0), "RewardsDistributor: zero recipient");
        require(amount > 0, "RewardsDistributor: zero amount");

        if (_token == address(token) && scheduleInitialized && schedule.active) {
            uint256 requiredBalance = getRemainingTokens();
            uint256 currentBalance = token.balanceOf(address(this));
            require(amount <= currentBalance - requiredBalance, "RewardsDistributor: cannot recover allocated rewards");
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    function forceUpdateGlobalState() external onlyGuardian {
        _updateGlobalState();
    }

    function reactivateSchedule() external onlyGuardian {
        require(scheduleInitialized, "RewardsDistributor: schedule not initialized");
        if (schedule.distributedSoFar < schedule.totalAllocation && block.timestamp < schedule.endTime) {
            schedule.active = true;
        }
    }
}
