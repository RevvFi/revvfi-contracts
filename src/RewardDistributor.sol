// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title RewardsDistributor
 * @dev Emits community rewards according to a linear distribution schedule.
 * @dev Uses MasterChef-style reward accounting with weighted shares.
 * @dev All role checks delegate to CentralAuthority
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 */
contract RewardsDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    // Role Constants (for CentralAuthority lookups)
    // =============================================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("DAO_ROLE"); // DAO_ROLE from CentralAuthority
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    // =============================================================
    // Custom Errors
    // =============================================================
    error ZeroAddress();
    error UnauthorizedCaller();
    error AlreadyInitialized();
    error InvalidSchedule();
    error InsufficientBalance();
    error ZeroEmissionRate();
    error NotActive();
    error NotActiveClaimer();
    error NoRewards();
    error RateChangeExceedsLimit();
    error CentralAuthorityNotSet();

    // =============================================================
    // Constants
    // =============================================================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_EMISSION_RATE_CHANGE = 1000; // 10% max change per update
    uint256 public constant PRECISION = 1e18;

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

    struct ClaimerInfo {
        uint256 amount;
        uint256 rewardDebt;
        bool active;
    }

    struct GlobalRewardState {
        uint256 lastUpdateTime;
        uint256 accRewardsPerShare;
        uint256 totalActiveClaimerWeight;
        uint256 totalPendingGlobalRewards;
    }

    // =============================================================
    // State Variables
    // =============================================================

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;
    address public centralAuthority;

    DistributionSchedule public schedule;
    bool public scheduleInitialized;

    mapping(address => ClaimerInfo) public claimers;

    GlobalRewardState public globalState;

    uint256 public currentEmissionRate;
    uint256 public cumulativeAccrued;
    uint256 public cumulativeDistributed;
    uint256 public totalActiveClaimerWeight;

    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event ScheduleInitialized(uint256 startTime, uint256 endTime, uint256 totalAllocation, uint256 emissionRate);
    event ClaimerAdded(address indexed claimer, uint256 amount);
    event ClaimerRemoved(address indexed claimer, uint256 amount);
    event RewardsClaimed(address indexed claimer, uint256 amount, uint256 totalClaimed);
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);
    event ScheduleExtended(uint256 oldEndTime, uint256 newEndTime, uint256 additionalTokens);
    event EmergencyPaused(address indexed executor);
    event EmergencyUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);
    event RewardsDeposited(uint256 amount);
    event RewardsAccrued(uint256 amount, uint256 accRewardsPerShare);
    event CentralAuthorityUpdated(address indexed oldAuthority, address indexed newAuthority);

    // =============================================================
    // Modifiers (using CentralAuthority)
    // =============================================================

    modifier onlyFactory() {
        if (centralAuthority == address(0)) revert CentralAuthorityNotSet();
        if (!ICentralAuthority(centralAuthority).hasRole(FACTORY_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyGovernance() {
        if (centralAuthority == address(0)) revert CentralAuthorityNotSet();
        if (!ICentralAuthority(centralAuthority).hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier onlyGuardian() {
        if (centralAuthority == address(0)) revert CentralAuthorityNotSet();
        if (!ICentralAuthority(centralAuthority).hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
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
        scheduleInitialized = false;
        totalActiveClaimerWeight = 0;
        cumulativeAccrued = 0;
        cumulativeDistributed = 0;
        currentEmissionRate = 0;

        globalState = GlobalRewardState({
            lastUpdateTime: 0, accRewardsPerShare: 0, totalActiveClaimerWeight: 0, totalPendingGlobalRewards: 0
        });
    }

    // =============================================================
    // Initialization
    // =============================================================

    function initializeSchedule(uint256 startTime, uint256 endTime, uint256 totalAllocation) external onlyFactory {
        if (scheduleInitialized) revert AlreadyInitialized();
        if (startTime <= block.timestamp) revert InvalidSchedule();
        if (endTime <= startTime) revert InvalidSchedule();
        if (totalAllocation == 0) revert InvalidSchedule();

        uint256 balance = token.balanceOf(address(this));
        if (balance < totalAllocation) revert InsufficientBalance();

        uint256 duration = endTime - startTime;
        uint256 emissionRate = totalAllocation / duration;
        if (emissionRate == 0) revert ZeroEmissionRate();

        uint256 remainder = totalAllocation - (emissionRate * duration);

        schedule = DistributionSchedule({
            startTime: startTime, endTime: endTime, totalAllocation: totalAllocation, distributedSoFar: 0, active: true
        });

        currentEmissionRate = emissionRate;
        scheduleInitialized = true;

        globalState.lastUpdateTime = startTime;
        globalState.totalPendingGlobalRewards = remainder;

        emit ScheduleInitialized(startTime, endTime, totalAllocation, emissionRate);
    }

    // =============================================================
    // Claimer Management
    // =============================================================

    function addClaimer(address claimer, uint256 amount) external onlyGovernance whenNotPaused scheduleExists {
        if (claimer == address(0)) revert ZeroAddress();
        if (claimers[claimer].active) revert UnauthorizedCaller();
        if (amount == 0) revert InvalidSchedule();

        _updateGlobalState();

        ClaimerInfo storage info = claimers[claimer];

        if (info.amount == 0 && info.rewardDebt == 0) {
            info.amount = amount;
            info.rewardDebt = (amount * globalState.accRewardsPerShare) / PRECISION;
            info.active = true;
        } else if (!info.active) {
            info.active = true;
            info.rewardDebt = (info.amount * globalState.accRewardsPerShare) / PRECISION;
        } else {
            revert UnauthorizedCaller();
        }

        totalActiveClaimerWeight += amount;
        globalState.totalActiveClaimerWeight = totalActiveClaimerWeight;

        emit ClaimerAdded(claimer, amount);
    }

    function removeClaimer(address claimer) external onlyGovernance {
        if (!claimers[claimer].active) revert NotActiveClaimer();

        _updateGlobalState();

        ClaimerInfo storage info = claimers[claimer];

        uint256 pending = (info.amount * globalState.accRewardsPerShare) / PRECISION - info.rewardDebt;

        if (pending > 0) {
            info.rewardDebt = 0;
            info.active = false;
            totalActiveClaimerWeight -= info.amount;
            globalState.totalActiveClaimerWeight = totalActiveClaimerWeight;

            token.safeTransfer(claimer, pending);
            cumulativeDistributed += pending;
            emit RewardsClaimed(claimer, pending, cumulativeDistributed);
        } else {
            info.active = false;
            totalActiveClaimerWeight -= info.amount;
            globalState.totalActiveClaimerWeight = totalActiveClaimerWeight;
        }

        emit ClaimerRemoved(claimer, info.amount);
    }

    // =============================================================
    // Core Accounting
    // =============================================================

    function _updateGlobalState() internal {
        if (!scheduleInitialized || !schedule.active) return;
        if (block.timestamp < schedule.startTime) return;
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
            uint256 rewardsThisPeriod = timeElapsed * currentEmissionRate;
            uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;

            if (rewardsThisPeriod > remainingAllocation) {
                rewardsThisPeriod = remainingAllocation;
            }

            if (rewardsThisPeriod > 0) {
                if (totalActiveClaimerWeight > 0) {
                    uint256 rewardsPerShareDelta = (rewardsThisPeriod * PRECISION) / totalActiveClaimerWeight;
                    globalState.accRewardsPerShare += rewardsPerShareDelta;
                } else {
                    globalState.totalPendingGlobalRewards += rewardsThisPeriod;
                }

                schedule.distributedSoFar += rewardsThisPeriod;
                cumulativeAccrued += rewardsThisPeriod;

                emit RewardsAccrued(rewardsThisPeriod, globalState.accRewardsPerShare);

                if (schedule.distributedSoFar >= schedule.totalAllocation) {
                    schedule.active = false;
                }
            }
        }

        if (globalState.totalPendingGlobalRewards > 0 && totalActiveClaimerWeight > 0) {
            uint256 pendingRewardsPerShare =
                (globalState.totalPendingGlobalRewards * PRECISION) / totalActiveClaimerWeight;
            globalState.accRewardsPerShare += pendingRewardsPerShare;
            globalState.totalPendingGlobalRewards = 0;
        }

        globalState.lastUpdateTime = updateEndTime;
        globalState.totalActiveClaimerWeight = totalActiveClaimerWeight;
    }

    function _calculateRewards(address claimer) internal view returns (uint256) {
        ClaimerInfo memory info = claimers[claimer];
        if (!info.active) return 0;

        uint256 earned = (info.amount * globalState.accRewardsPerShare) / PRECISION;
        if (earned <= info.rewardDebt) return 0;
        return earned - info.rewardDebt;
    }

    function claimRewards() external nonReentrant whenNotPaused returns (uint256 amount) {
        if (!scheduleInitialized) revert NotActive();

        if (block.timestamp < schedule.startTime) {
            if (!claimers[msg.sender].active) revert NotActiveClaimer();
            return 0;
        }

        if (!schedule.active) revert NotActive();

        _updateGlobalState();

        amount = _calculateRewards(msg.sender);
        if (amount == 0) revert NoRewards();

        ClaimerInfo storage info = claimers[msg.sender];
        info.rewardDebt = (info.amount * globalState.accRewardsPerShare) / PRECISION;

        token.safeTransfer(msg.sender, amount);
        cumulativeDistributed += amount;

        emit RewardsClaimed(msg.sender, amount, cumulativeDistributed);

        return amount;
    }

    function getClaimableRewards(address claimer) public view returns (uint256) {
        if (!scheduleInitialized || !schedule.active) return 0;
        if (!claimers[claimer].active) return 0;
        if (block.timestamp < schedule.startTime) return 0;

        uint256 accRewardsPerShare = globalState.accRewardsPerShare;
        uint256 localTotalActiveWeight = totalActiveClaimerWeight;
        uint256 localDistributedSoFar = schedule.distributedSoFar;

        if (block.timestamp > globalState.lastUpdateTime && localDistributedSoFar < schedule.totalAllocation) {
            uint256 currentTime = block.timestamp;
            uint256 endTime = schedule.endTime;
            uint256 calcEndTime = currentTime > endTime ? endTime : currentTime;
            uint256 timeElapsed = calcEndTime - globalState.lastUpdateTime;

            if (timeElapsed > 0 && localTotalActiveWeight > 0) {
                uint256 additionalRewards = timeElapsed * currentEmissionRate;
                uint256 remainingAllocation = schedule.totalAllocation - localDistributedSoFar;
                if (additionalRewards > remainingAllocation) {
                    additionalRewards = remainingAllocation;
                }
                if (additionalRewards > 0) {
                    accRewardsPerShare += (additionalRewards * PRECISION) / localTotalActiveWeight;
                }
            }
        }

        ClaimerInfo memory info = claimers[claimer];
        uint256 earned = (info.amount * accRewardsPerShare) / PRECISION;

        if (earned <= info.rewardDebt) return 0;
        return earned - info.rewardDebt;
    }

    // =============================================================
    // Governance Functions
    // =============================================================

    function updateEmissionRate(uint256 newEmissionRate) external onlyGovernance scheduleExists whenNotPaused {
        if (newEmissionRate == 0) revert ZeroEmissionRate();

        _updateGlobalState();

        uint256 maxIncrease = currentEmissionRate + (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);
        uint256 maxDecrease = currentEmissionRate - (currentEmissionRate * MAX_EMISSION_RATE_CHANGE / BASIS_POINTS);

        if (newEmissionRate > maxIncrease || newEmissionRate < maxDecrease) {
            revert RateChangeExceedsLimit();
        }

        uint256 remainingTime = _getRemainingDistributionTime();
        uint256 remainingAllocation = getRemainingTokens();
        uint256 projectedDistribution = newEmissionRate * remainingTime;

        if (projectedDistribution > remainingAllocation && remainingTime > 0) {
            newEmissionRate = remainingAllocation / remainingTime;
            if (newEmissionRate == 0) revert ZeroEmissionRate();
        }

        uint256 oldRate = currentEmissionRate;
        currentEmissionRate = newEmissionRate;

        emit EmissionRateUpdated(oldRate, newEmissionRate);
    }

    function extendSchedule(uint256 newEndTime, uint256 additionalTokens)
        external
        onlyGovernance
        scheduleExists
        whenNotPaused
    {
        if (newEndTime <= schedule.endTime) revert InvalidSchedule();

        _updateGlobalState();

        uint256 requiredBalance = getRemainingTokens() + additionalTokens;
        if (token.balanceOf(address(this)) < requiredBalance) revert InsufficientBalance();

        uint256 oldEndTime = schedule.endTime;

        schedule.endTime = newEndTime;
        schedule.totalAllocation += additionalTokens;
        schedule.active = true;

        uint256 remainingTime = newEndTime - block.timestamp;
        uint256 remainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
        if (remainingTime > 0) {
            currentEmissionRate = remainingAllocation / remainingTime;
            if (currentEmissionRate == 0) revert ZeroEmissionRate();
        }

        emit ScheduleExtended(oldEndTime, newEndTime, additionalTokens);
        emit RewardsDeposited(additionalTokens);
    }

    function addRewards(uint256 additionalTokens) external onlyGovernance scheduleExists whenNotPaused {
        if (additionalTokens == 0) revert InvalidSchedule();

        _updateGlobalState();

        uint256 remainingAllocation = getRemainingTokens();
        if (token.balanceOf(address(this)) < remainingAllocation + additionalTokens) {
            revert InsufficientBalance();
        }

        schedule.totalAllocation += additionalTokens;
        schedule.active = true;

        uint256 remainingTime = _getRemainingDistributionTime();
        if (remainingTime > 0) {
            uint256 newRemainingAllocation = schedule.totalAllocation - schedule.distributedSoFar;
            currentEmissionRate = newRemainingAllocation / remainingTime;
        }

        emit RewardsDeposited(additionalTokens);
    }

    function setCentralAuthority(address newAuthority) external onlyGuardian {
        if (newAuthority == address(0)) revert ZeroAddress();
        emit CentralAuthorityUpdated(centralAuthority, newAuthority);
        centralAuthority = newAuthority;
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
        returns (uint256 amount, uint256 rewardDebt, bool active, uint256 claimable)
    {
        ClaimerInfo memory info = claimers[claimer];
        return (info.amount, info.rewardDebt, info.active, getClaimableRewards(claimer));
    }

    function getTotalActiveClaimerWeight() external view returns (uint256) {
        return totalActiveClaimerWeight;
    }

    function getDistributionProgress() external view returns (uint256 percentage) {
        if (!scheduleInitialized) return 0;
        if (schedule.totalAllocation == 0) return 0;
        return (schedule.distributedSoFar * BASIS_POINTS) / schedule.totalAllocation;
    }

    function getGlobalState()
        external
        view
        returns (uint256 lastUpdateTime, uint256 accRewardsPerShare, uint256 totalWeight, uint256 pendingGlobalRewards)
    {
        return (
            globalState.lastUpdateTime,
            globalState.accRewardsPerShare,
            globalState.totalActiveClaimerWeight,
            globalState.totalPendingGlobalRewards
        );
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
        if (_token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidSchedule();

        if (_token == address(token) && scheduleInitialized && schedule.active) {
            uint256 requiredBalance = getRemainingTokens();
            uint256 currentBalance = token.balanceOf(address(this));
            if (amount > currentBalance - requiredBalance) revert InsufficientBalance();
        }

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    function forceUpdateGlobalState() external onlyGuardian {
        _updateGlobalState();
    }

    function reactivateSchedule() external onlyGuardian {
        if (!scheduleInitialized) revert NotActive();
        if (schedule.distributedSoFar < schedule.totalAllocation && block.timestamp < schedule.endTime) {
            schedule.active = true;
        }
    }
}
