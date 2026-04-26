// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./tokens/CommunityToken.sol";
import "./tokens/UtilityToken.sol";
import "./tokens/MemeToken.sol";

contract TokenTemplateFactory is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    // =============================================================
    // Roles
    // =============================================================

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =============================================================
    // Template IDs
    // =============================================================

    uint8 public constant TEMPLATE_COMMUNITY = 0;
    uint8 public constant TEMPLATE_UTILITY = 1;
    uint8 public constant TEMPLATE_MEME = 2;

    // =============================================================
    // Storage
    // =============================================================

    mapping(address => bool) public deployedTokens;
    mapping(uint8 => address) public templateImplementations;

    uint256 public totalTokensDeployed;

    // =============================================================
    // Events
    // =============================================================

    event TokenDeployed(
        uint256 indexed tokenId,
        address indexed tokenAddress,
        address indexed recipient,
        uint8 templateId,
        string name,
        string symbol,
        uint256 totalSupply
    );

    event TemplateAdded(uint8 indexed templateId, address implementation);

    // =============================================================
    // Constructor
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initializer
    // =============================================================

    function initialize() external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        totalTokensDeployed = 0;
    }

    // =============================================================
    // Core Factory Logic
    // =============================================================

    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint8 templateId,
        address initialRecipient
    ) external whenNotPaused returns (address tokenAddress) {
        require(bytes(name).length > 0, "Invalid name");
        require(bytes(symbol).length > 0, "Invalid symbol");
        require(totalSupply > 0, "Zero supply");
        require(initialRecipient != address(0), "Zero recipient");

        require(
            templateId == TEMPLATE_COMMUNITY ||
                templateId == TEMPLATE_UTILITY ||
                templateId == TEMPLATE_MEME,
            "Invalid template"
        );

        if (templateId == TEMPLATE_COMMUNITY) {
            tokenAddress = address(
                new CommunityToken(
                    name,
                    symbol,
                    totalSupply,
                    initialRecipient
                )
            );
        } else if (templateId == TEMPLATE_UTILITY) {
            tokenAddress = address(
                new UtilityToken(
                    name,
                    symbol,
                    totalSupply,
                    initialRecipient
                )
            );
        } else {
            tokenAddress = address(
                new MemeToken(
                    name,
                    symbol,
                    totalSupply,
                    initialRecipient
                )
            );
        }

        deployedTokens[tokenAddress] = true;
        totalTokensDeployed++;

        emit TokenDeployed(
            totalTokensDeployed,
            tokenAddress,
            initialRecipient,
            templateId,
            name,
            symbol,
            totalSupply
        );
    }

    function isRevvFiToken(address token) external view returns (bool) {
        return deployedTokens[token];
    }

    // =============================================================
    // Template Registry
    // =============================================================

    function addTemplate(
        uint8 templateId,
        address implementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(implementation != address(0), "Zero implementation");
        require(
            templateImplementations[templateId] == address(0),
            "Already exists"
        );

        templateImplementations[templateId] = implementation;

        emit TemplateAdded(templateId, implementation);
    }

    // =============================================================
    // Guardian Controls
    // =============================================================

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}