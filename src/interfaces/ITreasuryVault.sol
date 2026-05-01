// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ITokenTemplateFactory {
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        bytes32 templateId,
        address initialRecipient
    ) external returns (address);
    
    function isRevvFiToken(address token) external view returns (bool);
}