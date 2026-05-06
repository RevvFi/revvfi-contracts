// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICentralAuthority.sol";

/**
 * @title CreatorVestingVault
 * @dev Holds creator's allocated tokens and releases them according to cliff + linear vesting schedule.
 * @dev This contract is NON-UPGRADEABLE by design for maximum trust.
 * @dev Creator cannot access tokens before cliff. After cliff, tokens unlock linearly over vesting period.
 */
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

    // =============================================================
    // Structs
    // =============================================================

    /**
     * @dev Vesting schedule configuration
     */
    struct VestingSchedule {
        address token; // Token being vested
        address beneficiary; // Creator address receiving tokens
        uint256 cliffDuration; // Seconds until first release
        uint256 vestingDuration; // Total vesting period after cliff (seconds)
        uint256 startTime; // Timestamp when vesting begins (launch time)
        uint256 totalAmount; // Total tokens allocated to creator
        uint256 releasedAmount; // Tokens already claimed
        bool initialized; // Whether schedule is initialized
    }

    // =============================================================
    // Role Constants
    // =============================================================

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =============================================================
    // State Variables
    // =============================================================

    VestingSchedule private _vestingSchedule;

    // Address that can update vesting parameters (factory/guardian)
    address public immutable factory;

    // Central authority for role management
    address public immutable centralAuthority;

    // Platform fee recipient for potential clawback (emergency only)
    address public immutable platformFeeRecipient;

    // Emergency flag - if true, vesting can be paused (only by guardian in extreme cases)
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

    constructor(address _factory, address _platformFeeRecipient, address _centralAuthority) {
        if (_factory == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_centralAuthority == address(0)) revert ZeroAddress();

        factory = _factory;
        platformFeeRecipient = _platformFeeRecipient;
        centralAuthority = _centralAuthority;
        emergencyPaused = false;
    }

    // =============================================================
    // Initialization Functions
    // =============================================================

    /**
     * @dev Initializes vesting schedule (called by factory)
     * @param token Token address
     * @param beneficiary Creator address
     * @param totalAmount Total tokens to vest
     * @param cliffDuration Cliff duration in seconds
     * @param vestingDuration Vesting duration in seconds
     * @param startTime Start time (launch timestamp)
     */
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

        // Transfer tokens to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

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

    /**
     * @dev Releases claimable tokens to beneficiary
     * @return amount Amount of tokens released
     */
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

    /**
     * @dev Gets currently claimable amount
     * @return amount Claimable tokens
     */
    function getClaimableAmount() public view returns (uint256 amount) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }

        VestingSchedule memory schedule = _vestingSchedule;

        // Before cliff: nothing claimable
        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }

        // After full vesting: claim all remaining
        if (block.timestamp >= schedule.startTime + schedule.cliffDuration + schedule.vestingDuration) {
            return schedule.totalAmount - schedule.releasedAmount;
        }

        // During vesting: calculate linear release
        uint256 elapsed = block.timestamp - (schedule.startTime + schedule.cliffDuration);
        uint256 vestedTotal = (schedule.totalAmount * elapsed) / schedule.vestingDuration;

        // Subtract already released
        if (vestedTotal > schedule.releasedAmount) {
            return vestedTotal - schedule.releasedAmount;
        }

        return 0;
    }

    /**
     * @dev Returns total vested amount at current time
     * @return totalVested Total tokens vested so far
     */
    function getTotalVested() public view returns (uint256 totalVested) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }

        VestingSchedule memory schedule = _vestingSchedule;

        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }

        if (block.timestamp >= schedule.startTime + schedule.cliffDuration + schedule.vestingDuration) {
            return schedule.totalAmount;
        }

        uint256 elapsed = block.timestamp - (schedule.startTime + schedule.cliffDuration);
        return (schedule.totalAmount * elapsed) / schedule.vestingDuration;
    }

    /**
     * @dev Returns remaining locked tokens
     * @return remaining Tokens still locked
     */
    function getRemainingLocked() public view returns (uint256 remaining) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }

        return _vestingSchedule.totalAmount - getTotalVested();
    }

    // =============================================================
    // Emergency Functions (Guardian Only)
    // =============================================================

    /**
     * @dev Pauses vesting releases (emergency only)
     */
    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit VestingPaused(msg.sender);
    }

    /**
     * @dev Unpauses vesting releases
     */
    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit VestingUnpaused(msg.sender);
    }

    /**
     * @dev Recovers any tokens sent to this contract by mistake (guardian only)
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function recoverTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // Cannot recover the vested token if it's still locked
        if (token == _vestingSchedule.token) {
            uint256 remainingLocked = getRemainingLocked();
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            uint256 recoverable = contractBalance - remainingLocked;
            if (amount > recoverable) revert InvalidAmount();
        }

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRecovered(token, amount, recipient);
    }

    // =============================================================
    // View Functions
    // =============================================================

    /**
     * @dev Returns vesting schedule details
     */
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

    /**
     * @dev Returns contract balance of vested token
     */
    function getContractBalance() external view returns (uint256) {
        if (!_vestingSchedule.initialized) {
            return 0;
        }
        return IERC20(_vestingSchedule.token).balanceOf(address(this));
    }

    /**
     * @dev Checks if vesting is fully completed
     */
    function isFullyVested() external view returns (bool) {
        if (!_vestingSchedule.initialized) {
            return false;
        }
        return block.timestamp
            >= _vestingSchedule.startTime + _vestingSchedule.cliffDuration + _vestingSchedule.vestingDuration;
    }

    /**
     * @dev Checks if vesting is still in cliff period
     */
    function isInCliff() external view returns (bool) {
        if (!_vestingSchedule.initialized) {
            return false;
        }
        return block.timestamp < _vestingSchedule.startTime + _vestingSchedule.cliffDuration;
    }
}
// Interface moved to interfaces/ICreatorVestingVault.sol
