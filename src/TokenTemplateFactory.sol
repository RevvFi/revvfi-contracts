// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TokenTemplateFactory
 * @notice Registry + deployment engine for token templates using EIP-1167 minimal proxies
 * @dev Uses Clone pattern for gas-efficient token deployment. Templates are stored by ID and can be added/updated by governance.
 *
 * Key Features:
 * - Template registry with governance control (add, remove, update)
 * - EIP-1167 minimal proxies (Clones) for low gas costs
 * - Future-proof with initData parameter for token configuration
 * - Extensible: Add ANY new template at any time without redeploying factory
 * - Compatible with all RevvFi token kit templates
 */
contract TokenTemplateFactory is ReentrancyGuard, AccessControl {
    // =============================================================
    // Custom Errors
    // =============================================================

    error ZeroAddress();
    error TemplateNotFound();
    error TemplateExists();
    error InvalidTemplateId();
    error DeploymentFailed();
    error InitializationFailed();
    error UnauthorizedCaller();
    error InvalidName();
    error InvalidSymbol();

    // =============================================================
    // Roles
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Template Registry
    // =============================================================

    // Template ID → Implementation address
    mapping(bytes32 => address) public templates;

    // =============================================================
    // Events
    // =============================================================

    event TokenDeployed(
        address indexed token,
        bytes32 indexed templateId,
        address indexed creator,
        string name,
        string symbol,
        uint256 totalSupply,
        address recipient
    );

    event TemplateAdded(bytes32 indexed templateId, address indexed implementation);
    event TemplateRemoved(bytes32 indexed templateId);
    event TemplateUpdated(
        bytes32 indexed templateId, address indexed oldImplementation, address indexed newImplementation
    );

    // =============================================================
    // Constructor
    // =============================================================

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DAO_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyDAO() {
        if (!hasRole(DAO_ROLE, msg.sender)) revert UnauthorizedCaller();
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert UnauthorizedCaller();
        _;
    }

    modifier templateExists(bytes32 templateId) {
        if (templates[templateId] == address(0)) revert TemplateNotFound();
        _;
    }

    // =============================================================
    // Template Management (DAO Only)
    // =============================================================

    /**
     * @dev Adds a new token template
     * @param templateId Template ID (bytes32) - can be any unique identifier
     * @param implementation Implementation contract address
     */
    function addTemplate(bytes32 templateId, address implementation) external onlyDAO {
        if (templateId == bytes32(0)) revert InvalidTemplateId();
        if (implementation == address(0)) revert ZeroAddress();
        if (templates[templateId] != address(0)) revert TemplateExists();

        templates[templateId] = implementation;

        emit TemplateAdded(templateId, implementation);
    }

    /**
     * @dev Removes an existing token template
     * @param templateId Template ID to remove
     */
    function removeTemplate(bytes32 templateId) external onlyDAO templateExists(templateId) {
        delete templates[templateId];
        emit TemplateRemoved(templateId);
    }

    /**
     * @dev Updates an existing token template to a new implementation
     * @param templateId Template ID to update
     * @param newImplementation New implementation contract address
     */
    function updateTemplate(bytes32 templateId, address newImplementation) external onlyDAO templateExists(templateId) {
        if (newImplementation == address(0)) revert ZeroAddress();

        address oldImplementation = templates[templateId];
        templates[templateId] = newImplementation;

        emit TemplateUpdated(templateId, oldImplementation, newImplementation);
    }

    // =============================================================
    // Internal Deployment Logic
    // =============================================================

    /**
     * @dev Internal function to deploy a token
     * @param name Token name
     * @param symbol Token symbol
     * @param totalSupply Total supply (minted to receiver)
     * @param templateId Template identifier for token contract
     * @param receiver Address receiving the total supply
     * @param initData Additional initialization data (future-proof)
     * @return token Address of the deployed token
     */
    function _deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes memory initData
    ) private returns (address token) {
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) revert InvalidSymbol();
        if (totalSupply == 0) revert InvalidTemplateId();
        if (receiver == address(0)) revert ZeroAddress();

        address implementation = templates[templateId];
        if (implementation == address(0)) revert TemplateNotFound();

        // Clone implementation using EIP-1167 minimal proxy
        token = Clones.clone(implementation);
        if (token == address(0)) revert DeploymentFailed();

        // Initialize the token
        (bool success, bytes memory returnData) = token.call(
            abi.encodeWithSignature(
                "initialize(string,string,uint256,address,bytes)", name, symbol, totalSupply, receiver, initData
            )
        );

        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    let returnData_size := mload(returnData)
                    revert(add(32, returnData), returnData_size)
                }
            }
            revert InitializationFailed();
        }

        emit TokenDeployed(token, templateId, msg.sender, name, symbol, totalSupply, receiver);
    }

    // =============================================================
    // Token Deployment (External)
    // =============================================================

    /**
     * @dev Deploys a new token using the specified template with custom initData
     * @param name Token name
     * @param symbol Token symbol
     * @param totalSupply Total supply (minted to receiver)
     * @param templateId Template identifier for token contract
     * @param receiver Address receiving the total supply
     * @param initData Additional initialization data (future-proof)
     * @return token Address of the deployed token
     */
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes calldata initData
    ) external nonReentrant returns (address token) {
        return _deployToken(name, symbol, totalSupply, templateId, receiver, initData);
    }

    /**
     * @dev Deploys a new token using the specified template (without initData)
     * @param name Token name
     * @param symbol Token symbol
     * @param totalSupply Total supply (minted to receiver)
     * @param templateId Template identifier for token contract
     * @param receiver Address receiving the total supply
     * @return token Address of the deployed token
     */
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver
    ) external nonReentrant returns (address token) {
        bytes memory emptyBytes;
        return _deployToken(name, symbol, totalSupply, templateId, receiver, emptyBytes);
    }

    // =============================================================
    // View Functions
    // =============================================================

    /**
     * @dev Returns whether a template exists
     * @param templateId Template ID to check
     * @return bool True if template exists
     */
    function isTemplateExists(bytes32 templateId) external view returns (bool) {
        return templates[templateId] != address(0);
    }

    /**
     * @dev Returns the implementation address for a template
     * @param templateId Template ID
     * @return address Implementation address
     */
    function getTemplate(bytes32 templateId) external view returns (address) {
        return templates[templateId];
    }

    // =============================================================
    // Guardian Functions
    // =============================================================

    /**
     * @dev Emergency rescue of tokens sent to factory by mistake
     */
    function rescueTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidTemplateId();

        (bool success,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, amount));
        if (!success) revert DeploymentFailed();
    }
}
