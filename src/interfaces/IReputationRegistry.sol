// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IReputationRegistry {
    enum RiskLabel {
        AAA,
        AA,
        A,
        B,
        C,
        D,
        UNRATED
    }

    struct BorrowerProfile {
        address borrower;
        uint256 totalBorrowed;
        uint256 totalRepaid;
        uint256 successfulLoans;
        uint256 defaultedLoans;
        uint256 reputationScore;
        uint256 lastUpdateTime;
    }

    function registerBorrower(address borrower) external;
    function recordBorrowActivity(address borrower, uint256 borrowAmount) external;
    function recordSuccessfulRepayment(address borrower, uint256 repaidAmount) external;
    function recordDefault(address borrower, uint256 originalDebt, uint256 recoveredAmount) external;
    function getBorrowerProfile(address borrower) external view returns (BorrowerProfile memory);
    function getRiskLabel(address borrower) external view returns (RiskLabel);
    function getReputationScore(address borrower) external view returns (uint256);
    function isBorrowerRegistered(address borrower) external view returns (bool);
}
