// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ITreasuryVault {
    function initializeGovernance(address governanceModule) external;
    function createProposal(address proposer, uint256 amount, address recipient, uint256 totalVotingPower)
        external
        returns (uint256);
    function castVote(uint256 proposalId, address voter, bool support, uint256 votingPower) external;
    function executeProposal(uint256 proposalId) external;
    function cancelProposal(uint256 proposalId) external;
    function getVaultBalance() external view returns (uint256);
    function getAvailableBalance() external view returns (uint256);
    function pause() external;
    function unpause() external;
}
