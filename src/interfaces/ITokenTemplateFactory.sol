// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ITokenTemplateFactory {
    function addTemplate(bytes32 templateId, address implementation) external;
    function removeTemplate(bytes32 templateId) external;
    function updateTemplate(bytes32 templateId, address newImplementation) external;
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver,
        bytes calldata initData
    ) external returns (address);
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address receiver
    ) external returns (address);
    function templateExists(bytes32 templateId) external view returns (bool);
    function getTemplate(bytes32 templateId) external view returns (address);
    function templates(bytes32 templateId) external view returns (address);
}
