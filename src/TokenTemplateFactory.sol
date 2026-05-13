// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

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
 * - Deterministic deployment support via CREATE2
 * - Pausable emergency stop
 * - On-chain token registry for verification
 */
contract TokenTemplateFactory is ReentrancyGuard, AccessControl, Pausable {
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
    error ZeroSupply();
    error ZeroAmount();
    error NotPaused();

    // =============================================================
    // Roles
    // =============================================================

    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Structs
    // =============================================================

    struct TemplateInfo {
        address implementation;
        bool active;
        uint64 version;
        string metadataURI;
        bytes32 auditHash;
        uint256 addedAt;
    }

    // =============================================================
    // Template Registry
    // =============================================================

    // Template ID → TemplateInfo
    mapping(bytes32 => TemplateInfo) public templates;
    
    // Deployed token registry
    mapping(address => bool) public isFactoryToken;
    mapping(address => bytes32) public tokenTemplate;
    
    // Template list for iteration (optional, for frontend)
    bytes32[] public templateIds;

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

    event TemplateAdded(
        bytes32 indexed templateId, 
        address indexed implementation, 
        uint64 version,
        string metadataURI,
        bytes32 auditHash
    );
    
    event TemplateRemoved(bytes32 indexed templateId);
    event TemplateUpdated(
        bytes32 indexed templateId, 
        address indexed oldImplementation, 
        address indexed newImplementation,
        uint64 newVersion
    );
    
    event TemplateActivated(bytes32 indexed templateId);
    event TemplateDeactivated(bytes32 indexed templateId);
    event FactoryPaused(address indexed executor);
    event FactoryUnpaused(address indexed executor);

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
        if (templates[templateId].implementation == address(0)) revert TemplateNotFound();
        _;
    }
    
    modifier templateActive(bytes32 templateId) {
        if (!templates[templateId].active) revert TemplateNotFound();
        _;
    }

    // =============================================================
    // Template Management (DAO Only)
    // =============================================================

    /**
     * @dev Adds a new token template
     * @param templateId Template ID (bytes32) - can be any unique identifier
     * @param implementation Implementation contract address (must have _disableInitializers in constructor)
     * @param version Template version
     * @param metadataURI IPFS or Arweave URI with template metadata
     * @param auditHash Hash of audit report for verification
     */
    function addTemplate(
        bytes32 templateId, 
        address implementation, 
        uint64 version,
        string calldata metadataURI,
        bytes32 auditHash
    ) public onlyDAO {
        if (templateId == bytes32(0)) revert InvalidTemplateId();
        if (implementation == address(0)) revert ZeroAddress();
        if (templates[templateId].implementation != address(0)) revert TemplateExists();

        templates[templateId] = TemplateInfo({
            implementation: implementation,
            active: true,
            version: version,
            metadataURI: metadataURI,
            auditHash: auditHash,
            addedAt: block.timestamp
        });
        
        templateIds.push(templateId);

        emit TemplateAdded(templateId, implementation, version, metadataURI, auditHash);
    }

    /**
     * @dev Removes an existing token template
     * @param templateId Template ID to remove
     */
    function removeTemplate(bytes32 templateId) external onlyDAO templateExists(templateId) {
        // Don't delete, just deactivate
        templates[templateId].active = false;
        
        // Remove from templateIds array (inefficient but acceptable for governance operations)
        for (uint256 i = 0; i < templateIds.length; i++) {
            if (templateIds[i] == templateId) {
                templateIds[i] = templateIds[templateIds.length - 1];
                templateIds.pop();
                break;
            }
        }
        
        emit TemplateRemoved(templateId);
    }

    /**
     * @dev Updates an existing token template to a new implementation
     * @param templateId Template ID to update
     * @param newImplementation New implementation contract address
     * @param newVersion New version number
     * @param newMetadataURI New metadata URI (optional, can be empty)
     * @param newAuditHash New audit hash (optional, can be empty)
     */
    function updateTemplate(
        bytes32 templateId, 
        address newImplementation, 
        uint64 newVersion,
        string calldata newMetadataURI,
        bytes32 newAuditHash
    ) external onlyDAO templateExists(templateId) {
        if (newImplementation == address(0)) revert ZeroAddress();

        address oldImplementation = templates[templateId].implementation;
        
        templates[templateId].implementation = newImplementation;
        templates[templateId].version = newVersion;
        if (bytes(newMetadataURI).length > 0) {
            templates[templateId].metadataURI = newMetadataURI;
        }
        if (newAuditHash != bytes32(0)) {
            templates[templateId].auditHash = newAuditHash;
        }

        emit TemplateUpdated(templateId, oldImplementation, newImplementation, newVersion);
    }
    
    /**
     * @dev Activates or deactivates a template
     * @param templateId Template ID
     * @param active Active status
     */
    function setTemplateActive(bytes32 templateId, bool active) external onlyDAO templateExists(templateId) {
        templates[templateId].active = active;
        if (active) {
            emit TemplateActivated(templateId);
        } else {
            emit TemplateDeactivated(templateId);
        }
    }

    // =============================================================
    // Internal Deployment Logic
    // =============================================================

    /**
     * @dev Internal function to deploy a token using minimal proxy
     */
    function _deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes memory initData,
        bytes32 salt
    ) private returns (address token) {
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) revert InvalidSymbol();
        if (totalSupply == 0) revert ZeroSupply();
        if (receiver == address(0)) revert ZeroAddress();

        TemplateInfo memory template = templates[templateId];
        if (template.implementation == address(0)) revert TemplateNotFound();
        if (!template.active) revert TemplateNotFound();

        // Clone implementation using EIP-1167 minimal proxy
        if (salt == bytes32(0)) {
            token = Clones.clone(template.implementation);
        } else {
            token = Clones.cloneDeterministic(template.implementation, salt);
        }
        
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

        // Register deployed token
        isFactoryToken[token] = true;
        tokenTemplate[token] = templateId;

        emit TokenDeployed(token, templateId, msg.sender, name, symbol, totalSupply, receiver);
    }

    // =============================================================
    // Token Deployment (External)
    // =============================================================

    /**
     * @dev Deploys a new token using the specified template
     */
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes calldata initData
    ) external nonReentrant whenNotPaused returns (address token) {
        bytes32 emptySalt;
        return _deployToken(name, symbol, totalSupply, templateId, receiver, initData, emptySalt);
    }

    /**
     * @dev Deploys a new token using the specified template (without initData)
     */
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver
    ) external nonReentrant whenNotPaused returns (address token) {
        bytes memory emptyBytes;
        bytes32 emptySalt;
        return _deployToken(name, symbol, totalSupply, templateId, receiver, emptyBytes, emptySalt);
    }
    
    /**
     * @dev Deploys a token with deterministic address using CREATE2
     * @param salt Salt for CREATE2 address calculation
     */
    function deployTokenDeterministic(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes calldata initData,
        bytes32 salt
    ) external nonReentrant whenNotPaused returns (address token) {
        return _deployToken(name, symbol, totalSupply, templateId, receiver, initData, salt);
    }
    
    /**
     * @dev Predicts deterministic token address before deployment
     */
    function predictDeterministicAddress(
        bytes32 templateId,
        bytes32 salt,
        address deployer
    ) external view returns (address) {
        address implementation = templates[templateId].implementation;
        if (implementation == address(0)) revert TemplateNotFound();
        return Clones.predictDeterministicAddress(implementation, salt, deployer);
    }

    // =============================================================
    // View Functions
    // =============================================================

    /**
     * @dev Returns whether a template exists and is active
     */
    function isTemplateExists(bytes32 templateId) external view returns (bool) {
        return templates[templateId].implementation != address(0) && templates[templateId].active;
    }
    
    /**
     * @dev Returns whether a token was deployed by this factory
     */
    function isOfficialToken(address token) external view returns (bool) {
        return isFactoryToken[token];
    }
    
    /**
     * @dev Returns template ID for a token
     */
    function getTokenTemplate(address token) external view returns (bytes32) {
        return tokenTemplate[token];
    }

    /**
     * @dev Returns implementation address for a template
     */
    function getTemplate(bytes32 templateId) external view returns (TemplateInfo memory) {
        return templates[templateId];
    }
    
    /**
     * @dev Returns all template IDs
     */
    function getAllTemplateIds() external view returns (bytes32[] memory) {
        return templateIds;
    }
    
    /**
     * @dev Returns number of templates
     */
    function getTemplateCount() external view returns (uint256) {
        return templateIds.length;
    }

    // =============================================================
    // Guardian Functions
    // =============================================================

    /**
     * @dev Emergency pause for token deployment
     */
    function pause() external onlyGuardian {
        _pause();
        emit FactoryPaused(msg.sender);
    }
    
    /**
     * @dev Unpause deployment
     */
    function unpause() external onlyGuardian {
        _unpause();
        emit FactoryUnpaused(msg.sender);
    }

    /**
     * @dev Emergency rescue of tokens sent to factory by mistake (uses SafeERC20 pattern)
     * @param token Token address to rescue
     * @param amount Amount to rescue
     * @param recipient Recipient address
     */
    function rescueTokens(address token, uint256 amount, address recipient) external onlyGuardian {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", recipient, amount)
        );
        
        // Handle different ERC20 return value formats
        if (!success) revert DeploymentFailed();
        if (data.length > 0) {
            bool result = abi.decode(data, (bool));
            if (!result) revert DeploymentFailed();
        }
    }
    
    /**
     * @dev Batch add multiple templates at once
     */
    function batchAddTemplates(
        bytes32[] calldata templateIds,
        address[] calldata implementations,
        uint64[] calldata versions,
        string[] calldata metadataURIs,
        bytes32[] calldata auditHashes
    ) external onlyDAO {
        if (templateIds.length != implementations.length) revert InvalidTemplateId();
        if (templateIds.length != versions.length) revert InvalidTemplateId();
        
        for (uint256 i = 0; i < templateIds.length; i++) {
            addTemplate(templateIds[i], implementations[i], versions[i], metadataURIs[i], auditHashes[i]);
        }
    }
}
