// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IReputationRegistry.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title ReputationRegistry
 * @author Preet Singh
 * @notice Tracks borrower behavior and assigns reputation scores based on loan performance
 * @dev Scores range from 0-1000, starting at 500 for new borrowers
 */
contract ReputationRegistry is Ownable, ReentrancyGuard, IReputationRegistry {
    /// @dev Factory contract that can deploy and manage this registry
    address public factory;

    /// @dev Approved lending markets that can report borrower activity
    mapping(address => bool) public approvedMarkets;

    /// @dev Complete borrowing history and current score for each borrower
    mapping(address => BorrowerProfile) public borrowerProfiles;

    /// @dev Quick lookup for registered borrowers
    mapping(address => bool) public registeredBorrowers;

    /// @dev Restricts function calls to the factory contract only
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts function calls to approved lending markets
    modifier onlyApprovedMarket() {
        if (!approvedMarkets[msg.sender] && msg.sender != factory) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
        _;
    }

    /**
     * @dev Sets up the reputation system with factory as the deploying contract
     * @param _factory Address of the RevvFiFactory that will manage this registry
     */
    constructor(address _factory) Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
    }

    /**
     * @dev Authorizes a lending market to report borrower activity
     * @param market Address of the lending market to approve
     */
    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        approvedMarkets[market] = true;
    }

    /**
     * @dev Creates a new borrower profile with starting reputation of 500
     * @param borrower Address of the borrower to register
     */
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

    /**
     * @dev Updates borrower's total borrowed amount when they take a loan
     * @param borrower Address of the borrower
     * @param borrowAmount Amount borrowed in this transaction
     */
    function recordBorrowActivity(address borrower, uint256 borrowAmount) external onlyApprovedMarket {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();

        BorrowerProfile storage profile = borrowerProfiles[borrower];
        profile.totalBorrowed += borrowAmount;
        profile.lastUpdateTime = block.timestamp;

        emit RevvFiEvents.BorrowActivityRecorded(borrower, borrowAmount);
    }

    /**
     * @dev Updates borrower's repayment history and recalculates reputation score
     * @param borrower Address of the borrower
     * @param repaidAmount Amount successfully repaid
     */
    function recordSuccessfulRepayment(address borrower, uint256 repaidAmount) external onlyApprovedMarket {
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

    /**
     * @dev Records a loan default and penalizes the borrower's reputation
     * @param borrower Address of the borrower who defaulted
     * @param originalDebt Total amount that was owed
     * @param recoveredAmount Amount recovered through liquidation
     */
    function recordDefault(address borrower, uint256 originalDebt, uint256 recoveredAmount)
        external
        onlyApprovedMarket
    {
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

    /**
     * @dev Calculates reputation score based on loan success rate and default penalties
     * @param profile Storage reference to borrower's profile
     * @return Calculated reputation score between 0 and 1000
     */
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

    /**
     * @dev Returns complete borrowing profile for a borrower
     * @param borrower Address to query
     * @return BorrowerProfile struct containing all history and current score
     */
    function getBorrowerProfile(address borrower) external view returns (BorrowerProfile memory) {
        if (!registeredBorrowers[borrower]) revert RevvFiErrors.BorrowerNotRegistered();
        return borrowerProfiles[borrower];
    }

    /**
     * @dev Converts numerical reputation score to letter risk rating
     * @param borrower Address to evaluate
     * @return RiskLabel from AAA (best) to D (worst), UNRATED for unregistered
     */
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

    /**
     * @dev Returns just the numerical reputation score
     * @param borrower Address to query
     * @return Reputation score (0-1000) or 0 if borrower not registered
     */
    function getReputationScore(address borrower) external view returns (uint256) {
        if (!registeredBorrowers[borrower]) return 0;
        return borrowerProfiles[borrower].reputationScore;
    }

    /**
     * @dev Checks if a borrower has been registered in the system
     * @param borrower Address to check
     * @return True if borrower is registered, false otherwise
     */
    function isBorrowerRegistered(address borrower) external view returns (bool) {
        return registeredBorrowers[borrower];
    }

    /**
     * @dev Updates the factory contract address (owner only)
     * @param newFactory New factory contract address
     */
    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = newFactory;
    }
}
