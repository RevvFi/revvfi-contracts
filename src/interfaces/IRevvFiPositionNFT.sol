// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IRevvFiPositionNFT {
    struct Position {
        uint256 tokenId;
        address market;
        uint256 principal;
        uint256 apr;
        uint8 seniority;
        uint256 startTime;
        bool active;
        bool isSenior;
    }

    function mintPosition(address lender, address market, uint256 principal, uint256 apr, uint8 seniority)
        external
        returns (uint256);
    function redeemPosition(uint256 tokenId) external;
    function getPosition(uint256 tokenId) external view returns (Position memory);
    function getLenderPositions(address lender) external view returns (uint256[] memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function registerMarket(address market) external;
    function isPositionActive(uint256 tokenId) external view returns (bool);
    function getLenderByTokenId(uint256 tokenId) external view returns (address);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
