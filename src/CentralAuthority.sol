// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title CentralAuthority
 * @notice Central role management contract for the entire RevvFi ecosystem
 * @dev All contracts delegate role checks to this central authority
 * @dev DAO_ROLE is the primary governance root - DEFAULT_ADMIN_ROLE only for bootstrap
 */
contract CentralAuthority is Initializable, AccessControlUpgradeable {
    // =============================================================
    // Roles
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant BOOTSTRAPPER_ROLE = keccak256("BOOTSTRAPPER_ROLE");
    bytes32 public constant GOVERNANCE_MODULE_ROLE = keccak256("GOVERNANCE_MODULE_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");

    // =============================================================
    // Whitelisted roles for factory authorization (prevents privilege escalation)
    // =============================================================

    bytes32[] public factoryAuthorizedRoles;
    mapping(bytes32 => bool) public isFactoryAuthorizedRole;

    // =============================================================
    // Events
    // =============================================================

    event RoleGrantedToContract(bytes32 indexed role, address indexed contractAddress, string description);
    event RoleRevokedFromContract(bytes32 indexed role, address indexed contractAddress);
    event ContractAuthorized(address indexed contractAddress, bytes32 role);
    event ContractDeauthorized(address indexed contractAddress, bytes32 role);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event FactoryAuthorizedRoleAdded(bytes32 indexed role);
    event FactoryAuthorizedRoleRemoved(bytes32 indexed role);

    // =============================================================
    // Errors
    // =============================================================

    error ZeroAddress();
    error UnauthorizedRole();

    // =============================================================
    // Initialize
    // =============================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(address _dao, address _guardian, address _ops, address _upgrader) external initializer {
        if (_dao == address(0) || _guardian == address(0) || _ops == address(0) || _upgrader == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();

        // DAO_ROLE is the primary governance root
        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(GUARDIAN_ROLE, _guardian);
        _grantRole(OPS_ROLE, _ops);
        _grantRole(UPGRADER_ROLE, _upgrader);

        // Initialize factory authorized roles (only safe roles)
        _addFactoryAuthorizedRole(VAULT_ROLE);
        _addFactoryAuthorizedRole(GOVERNANCE_MODULE_ROLE);
        _addFactoryAuthorizedRole(REWARDS_DISTRIBUTOR_ROLE);
        _addFactoryAuthorizedRole(BOOTSTRAPPER_ROLE);
    }

    // =============================================================
    // Role Management (Admin functions use DAO_ROLE as primary)
    // =============================================================

    function grantRoleToContract(bytes32 role, address contractAddress, string calldata description)
        external
        onlyRole(DAO_ROLE)
    {
        if (contractAddress == address(0)) revert ZeroAddress();
        _grantRole(role, contractAddress);
        emit RoleGrantedToContract(role, contractAddress, description);
    }

    function revokeRoleFromContract(bytes32 role, address contractAddress) external onlyRole(DAO_ROLE) {
        _revokeRole(role, contractAddress);
        emit RoleRevokedFromContract(role, contractAddress);
    }

    /**
     * @dev Authorize a contract - can be called by DAO OR Factory (for deployment-time authorization)
     * Factory can ONLY grant whitelisted roles to prevent privilege escalation
     */
    function authorizeContract(address contractAddress, bytes32 role) external {
        if (contractAddress == address(0)) revert ZeroAddress();
        
        bool isDAO = hasRole(DAO_ROLE, msg.sender);
        bool isFactory = hasRole(FACTORY_ROLE, msg.sender);
        
        if (!isDAO && !isFactory) revert UnauthorizedRole();
        
        // If called by factory, restrict to whitelisted roles
        if (isFactory && !isDAO) {
            if (!isFactoryAuthorizedRole[role]) revert UnauthorizedRole();
        }
        
        _grantRole(role, contractAddress);
        emit ContractAuthorized(contractAddress, role);
    }

    /**
     * @dev Deauthorize a contract - Factory can only revoke whitelisted roles
     */
    function deauthorizeContract(address contractAddress, bytes32 role) external {
        bool isDAO = hasRole(DAO_ROLE, msg.sender);
        bool isFactory = hasRole(FACTORY_ROLE, msg.sender);
        
        if (!isDAO && !isFactory) revert UnauthorizedRole();
        
        // If called by factory, restrict to whitelisted roles (same as authorization)
        if (isFactory && !isDAO) {
            if (!isFactoryAuthorizedRole[role]) revert UnauthorizedRole();
        }
        
        _revokeRole(role, contractAddress);
        emit ContractDeauthorized(contractAddress, role);
    }

    // =============================================================
    // Factory Management (with revocation)
    // =============================================================

    address public currentFactory;

    function setFactory(address newFactory) external onlyRole(DAO_ROLE) {
        if (newFactory == address(0)) revert ZeroAddress();
        
        address oldFactory = currentFactory;
        
        // Revoke old factory role if exists
        if (oldFactory != address(0)) {
            _revokeRole(FACTORY_ROLE, oldFactory);
        }
        
        currentFactory = newFactory;
        _grantRole(FACTORY_ROLE, newFactory);
        
        emit FactoryUpdated(oldFactory, newFactory);
    }

    // =============================================================
    // Factory Authorized Roles Management
    // =============================================================

    function addFactoryAuthorizedRole(bytes32 role) external onlyRole(DAO_ROLE) {
        _addFactoryAuthorizedRole(role);
    }

    function _addFactoryAuthorizedRole(bytes32 role) internal {
        if (!isFactoryAuthorizedRole[role]) {
            isFactoryAuthorizedRole[role] = true;
            factoryAuthorizedRoles.push(role);
            emit FactoryAuthorizedRoleAdded(role);
        }
    }

    function removeFactoryAuthorizedRole(bytes32 role) external onlyRole(DAO_ROLE) {
        if (isFactoryAuthorizedRole[role]) {
            isFactoryAuthorizedRole[role] = false;
            
            // Remove from array (inefficient but admin function, called rarely)
            for (uint256 i = 0; i < factoryAuthorizedRoles.length; i++) {
                if (factoryAuthorizedRoles[i] == role) {
                    factoryAuthorizedRoles[i] = factoryAuthorizedRoles[factoryAuthorizedRoles.length - 1];
                    factoryAuthorizedRoles.pop();
                    break;
                }
            }
            
            emit FactoryAuthorizedRoleRemoved(role);
        }
    }

    function getFactoryAuthorizedRoles() external view returns (bytes32[] memory) {
        return factoryAuthorizedRoles;
    }

    // =============================================================
    // Role Checks (For other contracts to call)
    // =============================================================

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return super.hasRole(role, account);
    }

    function hasAnyRole(bytes32[] calldata roles, address account) external view returns (bool) {
        for (uint256 i = 0; i < roles.length; i++) {
            if (super.hasRole(roles[i], account)) {
                return true;
            }
        }
        return false;
    }

    function hasAllRoles(bytes32[] calldata roles, address account) external view returns (bool) {
        for (uint256 i = 0; i < roles.length; i++) {
            if (!super.hasRole(roles[i], account)) {
                return false;
            }
        }
        return true;
    }

    function isAuthorized(address account, bytes32 role) external view returns (bool) {
        return super.hasRole(role, account);
    }

    // =============================================================
    // Modifiers for other contracts to use via interface
    // =============================================================

    function checkRole(bytes32 role, address account) external view {
        if (!super.hasRole(role, account)) {
            revert UnauthorizedRole();
        }
    }

    function checkAnyRole(bytes32[] calldata roles, address account) external view {
        for (uint256 i = 0; i < roles.length; i++) {
            if (super.hasRole(roles[i], account)) {
                return;
            }
        }
        revert UnauthorizedRole();
    }

    // =============================================================
    // Contract Management
    // =============================================================

    function setGovernanceModule(address governanceModule) external onlyRole(DAO_ROLE) {
        if (governanceModule == address(0)) revert ZeroAddress();
        _grantRole(GOVERNANCE_MODULE_ROLE, governanceModule);
    }

    function setVault(address vault) external onlyRole(DAO_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        _grantRole(VAULT_ROLE, vault);
    }

    function setRewardsDistributor(address rewardsDistributor) external onlyRole(DAO_ROLE) {
        if (rewardsDistributor == address(0)) revert ZeroAddress();
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, rewardsDistributor);
    }

    uint256[49] private __gap;
}