// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
    error ZeroAddress();
    error UnauthorizedCaller();
    error PositionNotFound();
    error PositionAlreadyFinalized();
    error MarketAlreadyRegistered();
    error MarketNotRegistered();

    event PositionMinted(
        uint256 indexed tokenId,
        address indexed lender,
        address indexed market,
        uint256 principal,
        uint256 apr,
        uint8 seniority
    );
    event PositionBurned(uint256 indexed tokenId);
    event InterestClaimed(uint256 indexed tokenId, address indexed lender, uint256 amount);
    event PositionRedeemed(uint256 indexed tokenId, uint256 principalAmount, uint256 interestAmount);
    event MarketRegistered(address indexed market);
    event MarketUnregistered(address indexed market);

    struct Position {
        uint256 tokenId;
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

    address public factory;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public lenderPositions;
    mapping(address => mapping(uint256 => uint256)) public lenderPositionIndex;
    mapping(address => bool) public approvedMarkets;
    uint256 private _nextTokenId;

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    modifier onlyApprovedMarket() {
        if (!approvedMarkets[msg.sender]) revert MarketNotRegistered();
        _;
    }

    constructor(address _factory) ERC721("RevvFi Position", "RVF-POS") Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
    }

    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert ZeroAddress();
        if (approvedMarkets[market]) revert MarketAlreadyRegistered();
        approvedMarkets[market] = true;
        emit MarketRegistered(market);
    }

    function unregisterMarket(address market) external onlyFactory {
        if (!approvedMarkets[market]) revert MarketNotRegistered();
        approvedMarkets[market] = false;
        emit MarketUnregistered(market);
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
            lastAccrualTime: block.timestamp,
            accruedInterest: 0,
            active: true,
            isSenior: seniority == 0
        });

        lenderPositions[lender].push(tokenId);
        lenderPositionIndex[lender][tokenId] = lenderPositions[lender].length - 1;
        _safeMint(lender, tokenId);

        emit PositionMinted(tokenId, lender, market, principal, apr, seniority);
        return tokenId;
    }

    // For OpenZeppelin v5, we override _update instead of _beforeTokenTransfer
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Remove from old owner's tracking
        if (from != address(0)) {
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];
            
            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];
        }
        
        // Add to new owner's tracking
        if (to != address(0)) {
            lenderPositionIndex[to][tokenId] = lenderPositions[to].length;
            lenderPositions[to].push(tokenId);
        }
        
        return super._update(to, tokenId, auth);
    }

    function getLenderByTokenId(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
    }

    function addAccruedInterest(uint256 tokenId, uint256 amount) external onlyApprovedMarket {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();
        pos.accruedInterest += amount;
        pos.lastAccrualTime = block.timestamp;
    }

    function updateLastAccrualTime(uint256 tokenId) external onlyApprovedMarket {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();
        pos.lastAccrualTime = block.timestamp;
    }

    function claimInterest(uint256 tokenId) external returns (uint256 amount) {
        address lender = ownerOf(tokenId);
        if (lender != msg.sender) revert UnauthorizedCaller();

        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();

        amount = pos.accruedInterest;
        if (amount == 0) revert PositionNotFound();

        pos.accruedInterest = 0;
        emit InterestClaimed(tokenId, lender, amount);
        return amount;
    }

    function getAccruedInterest(uint256 tokenId) external view returns (uint256) {
        Position storage pos = positions[tokenId];
        if (!pos.active) return 0;
        return pos.accruedInterest;
    }

    function redeemPosition(
        uint256 tokenId,
        uint256 principalAmount,
        uint256 interestAmount
    ) external onlyApprovedMarket {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit PositionRedeemed(tokenId, principalAmount, interestAmount);
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