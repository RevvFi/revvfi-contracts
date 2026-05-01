// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title CentralAuthority
 * @notice Central role management contract for the entire RevvFi ecosystem
 * @dev All contracts delegate role checks to this central authority
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
    // Events
    // =============================================================
    
    event RoleGrantedToContract(bytes32 indexed role, address indexed contractAddress, string description);
    event RoleRevokedFromContract(bytes32 indexed role, address indexed contractAddress);
    event ContractAuthorized(address indexed contractAddress, bytes32 role);
    event ContractDeauthorized(address indexed contractAddress, bytes32 role);

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
        
        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(GUARDIAN_ROLE, _guardian);
        _grantRole(OPS_ROLE, _ops);
        _grantRole(UPGRADER_ROLE, _upgrader);
    }

    // =============================================================
    // Role Management
    // =============================================================
    
    function grantRoleToContract(bytes32 role, address contractAddress, string calldata description) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (contractAddress == address(0)) revert ZeroAddress();
        _grantRole(role, contractAddress);
        emit RoleGrantedToContract(role, contractAddress, description);
    }
    
    function revokeRoleFromContract(bytes32 role, address contractAddress) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        _revokeRole(role, contractAddress);
        emit RoleRevokedFromContract(role, contractAddress);
    }
    
    function authorizeContract(address contractAddress, bytes32 role) external onlyRole(DAO_ROLE) {
        if (contractAddress == address(0)) revert ZeroAddress();
        _grantRole(role, contractAddress);
        emit ContractAuthorized(contractAddress, role);
    }
    
    function deauthorizeContract(address contractAddress, bytes32 role) external onlyRole(DAO_ROLE) {
        _revokeRole(role, contractAddress);
        emit ContractDeauthorized(contractAddress, role);
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
        if (!super.hasRole(role, account)) revert UnauthorizedRole();
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
    
    function setFactory(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (factory == address(0)) revert ZeroAddress();
        _grantRole(FACTORY_ROLE, factory);
    }
    
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

    uint256[50] private __gap;
}