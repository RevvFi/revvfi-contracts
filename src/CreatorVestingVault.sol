// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICentralAuthority.sol";

contract CreatorVestingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error NotFactory();
    error NotBeneficiary();
    error NotAuthorized();
    error EmergencyPaused();
    error AlreadyInitialized();
    error InvalidDuration();
    error InvalidAmount();
    error NothingToRelease();
    error NotInitialized();
    error InsufficientBalance();
    error CannotRecoverOwedTokens();

    // =============================================================
    // Structs
    // =============================================================

    struct VestingSchedule {
        address token;
        address beneficiary;
        uint256 cliffDuration;
        uint256 vestingDuration;
        uint256 startTime;
        uint256 totalAmount;
        uint256 releasedAmount;
        bool initialized;
    }

    // =============================================================
    // Role Constants
    // =============================================================

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // State Variables
    // =============================================================

    VestingSchedule private _vestingSchedule;
    address public immutable factory;
    address public immutable centralAuthority;
    bool public emergencyPaused;

    // =============================================================
    // Events
    // =============================================================

    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 startTime
    );

    event TokensReleased(
        address indexed beneficiary, uint256 amountReleased, uint256 totalReleasedSoFar, uint256 remainingAmount
    );

    event VestingPaused(address indexed executor);
    event VestingUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyBeneficiary() {
        if (msg.sender != _vestingSchedule.beneficiary) revert NotBeneficiary();
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

    // =============================================================
    // Constructor
    // =============================================================

    constructor(address _factory, address _centralAuthority) {
        if (_factory == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        factory = _factory;
        centralAuthority = _centralAuthority;
        emergencyPaused = false;
    }

    // =============================================================
    // Initialization Functions
    // =============================================================

    function initializeVesting(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 startTime
    ) external onlyFactory {
        if (_vestingSchedule.initialized) revert AlreadyInitialized();
        if (token == address(0)) revert ZeroAddress();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert InvalidAmount();
        if (vestingDuration == 0) revert InvalidDuration();
        if (startTime == 0) revert ZeroAddress();
        if (cliffDuration > vestingDuration) revert InvalidDuration();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < totalAmount) revert InsufficientBalance();

        _vestingSchedule = VestingSchedule({
            token: token,
            beneficiary: beneficiary,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            startTime: startTime,
            totalAmount: totalAmount,
            releasedAmount: 0,
            initialized: true
        });

        emit VestingInitialized(token, beneficiary, totalAmount, cliffDuration, vestingDuration, startTime);
    }

    // =============================================================
    // Core Functions
    // =============================================================

    function release() external nonReentrant onlyBeneficiary whenNotPaused returns (uint256 amount) {
        if (!_vestingSchedule.initialized) revert NotInitialized();

        uint256 claimableAmount = getClaimableAmount();
        if (claimableAmount == 0) revert NothingToRelease();

        _vestingSchedule.releasedAmount += claimableAmount;

        IERC20 token = IERC20(_vestingSchedule.token);
        token.safeTransfer(_vestingSchedule.beneficiary, claimableAmount);

        emit TokensReleased(
            _vestingSchedule.beneficiary,
            claimableAmount,
            _vestingSchedule.releasedAmount,
            _vestingSchedule.totalAmount - _vestingSchedule.releasedAmount
        );

        return claimableAmount;
    }

    function getClaimableAmount() public view returns (uint256 amount) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }

        VestingSchedule memory schedule = _vestingSchedule;

        if (block.timestamp < schedule.startTime) {
            return 0;
        }

        uint256 totalElapsed = block.timestamp - schedule.startTime;

        if (totalElapsed < schedule.cliffDuration) {
            return 0;
        }

        if (totalElapsed >= schedule.vestingDuration) {
            return schedule.totalAmount - schedule.releasedAmount;
        }

        uint256 vestedTotal = (schedule.totalAmount * totalElapsed) / schedule.vestingDuration;

        if (vestedTotal > schedule.releasedAmount) {
            return vestedTotal - schedule.releasedAmount;
        }

        return 0;
    }

    function getTotalVested() public view returns (uint256 totalVested) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }

        VestingSchedule memory schedule = _vestingSchedule;

        if (block.timestamp < schedule.startTime) {
            return 0;
        }

        uint256 totalElapsed = block.timestamp - schedule.startTime;

        if (totalElapsed >= schedule.vestingDuration) {
            return schedule.totalAmount;
        }

        if (totalElapsed < schedule.cliffDuration) {
            return 0;
        }

        return (schedule.totalAmount * totalElapsed) / schedule.vestingDuration;
    }

    function getRemainingLocked() public view returns (uint256 remaining) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }
        return _vestingSchedule.totalAmount - getTotalVested();
    }

    /**
     * @dev Returns total amount that is OWED to beneficiary (including vested but unclaimed)
     */
    function getOwedAmount() public view returns (uint256 owed) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }
        return _vestingSchedule.totalAmount - _vestingSchedule.releasedAmount;
    }

    // =============================================================
    // Emergency Functions (Guardian Only)
    // =============================================================

    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit VestingPaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit VestingUnpaused(msg.sender);
    }

    /**
     * @dev Recovers any tokens sent to this contract by mistake (guardian only)
     * CRITICAL: Cannot recover tokens that are OWED to beneficiary (including vested but unclaimed)
     * Only excess tokens beyond the total owed amount can be recovered
     */
    function recoverTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == _vestingSchedule.token) {
            uint256 owedAmount = getOwedAmount();
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            uint256 recoverable = contractBalance - owedAmount;
            if (amount > recoverable) revert CannotRecoverOwedTokens();
        }

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRecovered(token, amount, recipient);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function getVestingSchedule()
        external
        view
        returns (
            address token,
            address beneficiary,
            uint256 cliffDuration,
            uint256 vestingDuration,
            uint256 startTime,
            uint256 totalAmount,
            uint256 releasedAmount,
            bool initialized
        )
    {
        VestingSchedule memory schedule = _vestingSchedule;
        return (
            schedule.token,
            schedule.beneficiary,
            schedule.cliffDuration,
            schedule.vestingDuration,
            schedule.startTime,
            schedule.totalAmount,
            schedule.releasedAmount,
            schedule.initialized
        );
    }

    function getContractBalance() external view returns (uint256) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }
        return IERC20(_vestingSchedule.token).balanceOf(address(this));
    }

    function isFullyVested() external view returns (bool) {
        if (!_vestingSchedule.initialized) {
            return false;
        }
        return block.timestamp >= _vestingSchedule.startTime + _vestingSchedule.vestingDuration;
    }

    function isInCliff() external view returns (bool) {
        if (!_vestingSchedule.initialized) {
            return false;
        }
        return block.timestamp < _vestingSchedule.startTime + _vestingSchedule.cliffDuration;
    }
}
