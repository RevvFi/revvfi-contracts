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
 * @dev Releases are executed DIRECTLY by RevvFiGovernance via executeProposal()
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
    error InvalidAmount();
    error InsufficientBalance();
    error AlreadyInitialized();
    error TransferFailed();
    error InvalidRecipient();
    error ZeroAmount();

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_RELEASE_PERCENTAGE = 2500; // 25% max per release

    IERC20 public immutable token;
    address public immutable factory;
    address public immutable platformFeeRecipient;
    address public immutable centralAuthority;

    address public governanceModule;
    uint256 public totalReleased;
    bool public emergencyPaused;

    // Events
    event TokensReleased(uint256 amount, address indexed recipient, address indexed executor, uint256 totalReleasedSoFar);
    event GovernanceModuleUpdated(address indexed oldModule, address indexed newModule);
    event TreasuryPaused(address indexed executor);
    event TreasuryUnpaused(address indexed executor);
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);

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
        totalReleased = 0;

        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _factory);
        _grantRole(GUARDIAN_ROLE, _platformFeeRecipient);
    }

    function initializeGovernance(address _governanceModule) external onlyFactory {
        if (_governanceModule == address(0)) revert ZeroAddress();
        if (governanceModule != address(0)) revert AlreadyInitialized();

        governanceModule = _governanceModule;
        _grantRole(GOVERNANCE_ROLE, _governanceModule);

        emit GovernanceModuleUpdated(address(0), _governanceModule);
    }

    function release(uint256 amount, address recipient) external onlyGovernance whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        
        uint256 balance = token.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        
        // Rate limiting: max 25% of remaining balance per release
        uint256 maxAmount = (balance * MAX_RELEASE_PERCENTAGE) / BASIS_POINTS;
        if (amount > maxAmount) revert InvalidAmount();
        
        totalReleased += amount;
        
        emit TokensReleased(amount, recipient, msg.sender, totalReleased);
        
        token.safeTransfer(recipient, amount);
    }

    function batchRelease(address[] calldata recipients, uint256[] calldata amounts) external onlyGovernance whenNotPaused {
        if (recipients.length != amounts.length) revert InvalidAmount();
        if (recipients.length == 0) revert InvalidAmount();
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (recipients[i] == address(0)) revert InvalidRecipient();
            totalAmount += amounts[i];
        }
        
        uint256 balance = token.balanceOf(address(this));
        uint256 maxAmount = (balance * MAX_RELEASE_PERCENTAGE) / BASIS_POINTS;
        if (totalAmount > maxAmount) revert InvalidAmount();
        
        totalReleased += totalAmount;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            token.safeTransfer(recipients[i], amounts[i]);
            emit TokensReleased(amounts[i], recipients[i], msg.sender, totalReleased);
        }
    }

    function pause() external onlyGuardian {
        emergencyPaused = true;
        emit TreasuryPaused(msg.sender);
    }

    function unpause() external onlyGuardian {
        emergencyPaused = false;
        emit TreasuryUnpaused(msg.sender);
    }

    function recoverTokens(address _token, uint256 amount, address recipient) external onlyGuardian {
        if (_token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (_token == address(token)) revert InvalidAmount();

        IERC20(_token).safeTransfer(recipient, amount);
        emit TokensRecovered(_token, amount, recipient);
    }

    function updateGovernanceModule(address newGovernanceModule) external onlyGuardian {
        if (newGovernanceModule == address(0)) revert ZeroAddress();
        
        address oldModule = governanceModule;

        if (oldModule != address(0)) {
            _revokeRole(GOVERNANCE_ROLE, oldModule);
        }

        governanceModule = newGovernanceModule;
        _grantRole(GOVERNANCE_ROLE, newGovernanceModule);

        emit GovernanceModuleUpdated(oldModule, newGovernanceModule);
    }

    function getVaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getAvailableBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getTotalReleased() external view returns (uint256) {
        return totalReleased;
    }
    
    function getMaxReleaseAmount() external view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return (balance * MAX_RELEASE_PERCENTAGE) / BASIS_POINTS;
    }
}
