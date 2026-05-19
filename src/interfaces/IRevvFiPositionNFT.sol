// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IRevvFiPositionNFT {
    struct Position {
        uint256 tokenId;
        address lender;
        address market;
        uint256 principal;
        uint256 apr;
        uint8 seniority;
        uint256 startTime;
        uint256 lastAccrualTime;
        uint256 accruedInterest;
        bool active;
        bool isSenior;
    }

    function mintPosition(address lender, address market, uint256 principal, uint256 apr, uint8 seniority) external returns (uint256);
    function updateInterest(uint256 tokenId) external returns (uint256);
    function claimInterest(uint256 tokenId) external returns (uint256);
    function redeemPosition(uint256 tokenId, uint256 principalAmount, uint256 interestAmount) external;
    function getClaimableInterest(uint256 tokenId) external view returns (uint256);
    function getPositionValue(uint256 tokenId) external view returns (uint256);
    function getPosition(uint256 tokenId) external view returns (Position memory);
    function getLenderPositions(address lender) external view returns (uint256[] memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    
    // Additional functions needed by RevvFiMarket
    function registerMarket(address market) external;
    function addAccruedInterest(uint256 tokenId, uint256 amount) external;
    function updateLastAccrualTime(uint256 tokenId) external;
    function getAccruedInterest(uint256 tokenId) external view returns (uint256);
    function isPositionActive(uint256 tokenId) external view returns (bool);
}