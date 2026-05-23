// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiLiquidityQueue {
    struct WithdrawalRequest {
        uint256 requestId;
        address lender;
        uint256 positionId;
        uint256 requestedAmount;
        uint256 fulfilledAmount;
        uint256 remainingAmount;
        uint256 requestedEpoch;
        bool processed;
        bool claimed;
        bool positionLocked;
    }

    struct Epoch {
        uint256 epochNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRequested;
        uint256 totalAvailable;
        bool processed;
        uint256[] requestIds;
    }

    function requestWithdrawal(address lender, uint256 positionId, uint256 amount) external returns (uint256);
    function processEpoch(uint256 epochNumber, uint256 availableLiquidity) external;
    function claimWithdrawal(uint256 requestId, uint256 amount) external;
    function cancelWithdrawal(uint256 requestId) external;
    function getCurrentEpoch() external view returns (uint256);
    function getEpoch(uint256 epochNumber) external view returns (Epoch memory);
    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory);
    function getLenderRequests(address lender) external view returns (uint256[] memory);
    function isWithdrawalReady(uint256 requestId) external view returns (bool);
    function timeUntilEpochEnd() external view returns (uint256);
}
