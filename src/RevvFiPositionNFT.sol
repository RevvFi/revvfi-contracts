// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
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

    address public factory;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public lenderPositions;
    mapping(address => mapping(uint256 => uint256)) public lenderPositionIndex;
    mapping(address => bool) public approvedMarkets;
    uint256 private _nextTokenId;

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyApprovedMarket() {
        if (!approvedMarkets[msg.sender]) revert RevvFiErrors.MarketNotRegistered();
        _;
    }

    constructor(address _factory) ERC721("RevvFi Position", "RVF-POS") Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
    }

    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (approvedMarkets[market]) revert RevvFiErrors.MarketAlreadyRegistered();
        approvedMarkets[market] = true;
        emit RevvFiEvents.MarketRegistered(market);
    }

    function unregisterMarket(address market) external onlyFactory {
        if (!approvedMarkets[market]) revert RevvFiErrors.MarketNotRegistered();
        approvedMarkets[market] = false;
        emit RevvFiEvents.MarketUnregistered(market);
    }

    function mintPosition(
        address lender,
        address market,
        uint256 principal,
        uint256 apr,
        uint8 seniority
    ) external onlyApprovedMarket returns (uint256 tokenId) {
        tokenId = _nextTokenId;
        _nextTokenId++;

        positions[tokenId] = Position({
            tokenId: tokenId,
            market: market,
            principal: principal,
            apr: apr,
            seniority: seniority,
            startTime: block.timestamp,
            active: true,
            isSenior: seniority == 0
        });

        lenderPositions[lender].push(tokenId);
        lenderPositionIndex[lender][tokenId] = lenderPositions[lender].length - 1;
        _safeMint(lender, tokenId);

        emit RevvFiEvents.PositionMinted(tokenId, lender, market, principal, apr, seniority);
        return tokenId;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0)) {
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];
        }

        if (to != address(0)) {
            lenderPositionIndex[to][tokenId] = lenderPositions[to].length;
            lenderPositions[to].push(tokenId);
        }

        return super._update(to, tokenId, auth);
    }

    function getLenderByTokenId(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
    }

    function redeemPosition(uint256 tokenId) external onlyApprovedMarket {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert RevvFiErrors.PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit RevvFiEvents.PositionRedeemed(tokenId, pos.principal, 0);
    }

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    function getLenderPositions(address lender) external view returns (uint256[] memory) {
        return lenderPositions[lender];
    }

    function getActivePositionCount(address lender) external view returns (uint256) {
        uint256 count = 0;
        uint256[] storage posIds = lenderPositions[lender];
        for (uint256 i = 0; i < posIds.length; i++) {
            if (positions[posIds[i]].active) count++;
        }
        return count;
    }

    function isPositionActive(uint256 tokenId) external view returns (bool) {
        return positions[tokenId].active;
    }
}