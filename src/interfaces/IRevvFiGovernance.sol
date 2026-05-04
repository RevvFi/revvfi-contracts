// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiGovernance {
    function propose(address target, bytes calldata data, uint8 proposalType, string calldata description)
        external
        returns (uint256);
    function castVote(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function cancelProposal(uint256 proposalId) external;
    function vetoProposal(uint256 proposalId) external;
    function getProposalState(uint256 proposalId) external view returns (uint8);
    function canExecute(uint256 proposalId) external view returns (bool);
    function getVotingPower(address lp) external view returns (uint256);
    function getTotalVotingPower() external view returns (uint256);
    function pause() external;
    function unpause() external;
    function onSharesUpdated(address lp, uint256 newShares) external;
}
