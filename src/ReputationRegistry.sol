// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract ReputationRegistry is Ownable, ReentrancyGuard {
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

    address public factory;

    mapping(address => BorrowerProfile) public borrowerProfiles;
    mapping(address => bool) public registeredBorrowers;

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    constructor(address _factory) Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
    }

    function registerBorrower(address borrower) external onlyFactory {
        if (borrower == address(0)) revert RevvFiErrors.ZeroAddress();
        if (registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerAlreadyExists();

        borrowerProfiles[borrower] = BorrowerProfile({
            borrower: borrower,
            totalBorrowed: 0,
            totalRepaid: 0,
            successfulLoans: 0,
            defaultedLoans: 0,
            reputationScore: 500,
            lastUpdateTime: block.timestamp
        });

        registeredBorrowers[borrower] = true;
        emit RevvFiEvents.BorrowerRegistered(borrower);
    }

    function recordBorrowActivity(address borrower, uint256 borrowAmount) external onlyFactory {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();

        BorrowerProfile storage profile = borrowerProfiles[borrower];
        profile.totalBorrowed += borrowAmount;
        profile.lastUpdateTime = block.timestamp;

        emit RevvFiEvents.BorrowActivityRecorded(borrower, borrowAmount);
    }

    function recordSuccessfulRepayment(address borrower, uint256 repaidAmount) external onlyFactory {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();

        BorrowerProfile storage profile = borrowerProfiles[borrower];
        profile.totalRepaid += repaidAmount;
        profile.successfulLoans += 1;

        uint256 oldScore = profile.reputationScore;
        profile.reputationScore = _calculateReputationScore(profile);
        profile.lastUpdateTime = block.timestamp;

        emit RevvFiEvents.SuccessfulRepaymentRecorded(borrower, repaidAmount);
        emit RevvFiEvents.ReputationScoreUpdated(borrower, oldScore, profile.reputationScore);
    }

    function recordDefault(address borrower, uint256 originalDebt, uint256 recoveredAmount) external onlyFactory {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();

        BorrowerProfile storage profile = borrowerProfiles[borrower];
        profile.defaultedLoans += 1;
        profile.totalRepaid += recoveredAmount;

        uint256 oldScore = profile.reputationScore;
        profile.reputationScore = _calculateReputationScore(profile);
        profile.lastUpdateTime = block.timestamp;

        emit RevvFiEvents.DefaultRecorded(borrower, originalDebt, recoveredAmount);
        emit RevvFiEvents.ReputationScoreUpdated(borrower, oldScore, profile.reputationScore);
    }

    function _calculateReputationScore(BorrowerProfile storage profile) internal view returns (uint256) {
        uint256 totalLoans = profile.successfulLoans + profile.defaultedLoans;

        if (totalLoans == 0) return 500;

        uint256 successRate = (profile.successfulLoans * 1000) / totalLoans;
        uint256 defaultPenalty = profile.defaultedLoans * 50;

        int256 score = int256(successRate) - int256(defaultPenalty);

        if (score <= 0) return 0;
        if (score >= 1000) return 1000;
        return uint256(score);
    }

    function getBorrowerProfile(address borrower) external view returns (BorrowerProfile memory) {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();
        return borrowerProfiles[borrower];
    }

    function getRiskLabel(address borrower) external view returns (RiskLabel) {
        if (!registeredBorrowers[borrower]) return RiskLabel.UNRATED;

        uint256 score = borrowerProfiles[borrower].reputationScore;

        if (score >= 900) return RiskLabel.AAA;
        if (score >= 800) return RiskLabel.AA;
        if (score >= 700) return RiskLabel.A;
        if (score >= 500) return RiskLabel.B;
        if (score >= 300) return RiskLabel.C;
        return RiskLabel.D;
    }

    function getReputationScore(address borrower) external view returns (uint256) {
        if (!registeredBorrowers[borrower]) return 0;
        return borrowerProfiles[borrower].reputationScore;
    }

    function isBorrowerRegistered(address borrower) external view returns (bool) {
        return registeredBorrowers[borrower];
    }

    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = newFactory;
    }
}
