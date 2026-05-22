// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title RevvFiDebtAccounting
 * @notice Debt share accounting system using cumulative index pattern
 * @dev Similar to Aave's scaled balance or Compound's borrow index
 */
library RevvFiDebtAccounting {
    using Math for uint256;

    struct DebtIndex {
        uint256 cumulativeIndex; // Scaled by 1e27 (RAY)
        uint256 lastUpdateTime;
    }

    struct PositionDebt {
        uint256 shares; // Scaled by 1e27 (RAY)
        uint256 principal; // For reference only
        uint256 apr;
        uint256 lastAccrualTime;
        bool isSenior;
    }

    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BASIS_POINTS = 10000;

    function calculateInterest(uint256 principal, uint256 apr, uint256 elapsed) internal pure returns (uint256) {
        return (principal * apr * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);
    }

    /**
     * @dev Calculate new cumulative index
     * Formula: newIndex = oldIndex + (oldIndex * apr * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)
     */
    function updateIndex(uint256 oldIndex, uint256 apr, uint256 elapsed) internal pure returns (uint256 newIndex) {
        uint256 indexGrowth = (oldIndex * apr * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS);
        newIndex = oldIndex + indexGrowth;
    }

    function principalToShares(uint256 principal, uint256 currentIndex) internal pure returns (uint256) {
        return (principal * RAY) / currentIndex;
    }

    function sharesToPrincipal(uint256 shares, uint256 currentIndex) internal pure returns (uint256) {
        return (shares * currentIndex) / RAY;
    }

    function distributeRepayment(uint256 totalActiveShares, uint256 lenderShares, uint256 repaymentAmount)
        internal
        pure
        returns (uint256 lenderRepayment)
    {
        if (totalActiveShares == 0) return 0;
        return (repaymentAmount * lenderShares) / totalActiveShares;
    }
}
