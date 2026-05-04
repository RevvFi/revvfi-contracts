// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ICentralAuthority {
    // Role constants
    function DAO_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function OPS_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function FACTORY_ROLE() external view returns (bytes32);
    function BOOTSTRAPPER_ROLE() external view returns (bytes32);
    function GOVERNANCE_MODULE_ROLE() external view returns (bytes32);
    function VAULT_ROLE() external view returns (bytes32);
    function REWARDS_DISTRIBUTOR_ROLE() external view returns (bytes32);

    // Role management
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hasAnyRole(bytes32[] calldata roles, address account) external view returns (bool);
    function hasAllRoles(bytes32[] calldata roles, address account) external view returns (bool);
    function isAuthorized(address account, bytes32 role) external view returns (bool);

    // Role checks with reverts
    function checkRole(bytes32 role, address account) external view;
    function checkAnyRole(bytes32[] calldata roles, address account) external view;

    // Contract authorization
    function authorizeContract(address contractAddress, bytes32 role) external;
    function deauthorizeContract(address contractAddress, bytes32 role) external;

    // Role granting (only DEFAULT_ADMIN_ROLE)
    function grantRoleToContract(bytes32 role, address contractAddress, string calldata description) external;
    function revokeRoleFromContract(bytes32 role, address contractAddress) external;

    // Contract registration
    function setFactory(address factory) external;
    function setGovernanceModule(address governanceModule) external;
    function setVault(address vault) external;
    function setRewardsDistributor(address rewardsDistributor) external;
}
