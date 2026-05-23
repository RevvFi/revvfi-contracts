// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

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

    string private _baseTokenURI;
    string public constant TOKEN_NAME = "RevvFi Position";
    string public constant TOKEN_SYMBOL = "RVF-POS";

    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    modifier onlyApprovedMarket(address market) {
        if (!approvedMarkets[market] && msg.sender != factory) {
            revert RevvFiErrors.MarketNotRegistered();
        }
        _;
    }

    constructor(address _factory) ERC721(TOKEN_NAME, TOKEN_SYMBOL) Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
        _baseTokenURI = "";
    }

    // FIXED: Allow market to register itself during initialization
    function registerMarket(address market) external {
        // Allow factory OR the market itself to register
        if (msg.sender != factory && msg.sender != market) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
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

    function mintPosition(address lender, address market, uint256 principal, uint256 apr, uint8 seniority)
        external
        onlyApprovedMarket(market)
        returns (uint256 tokenId)
    {
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

    function redeemPosition(uint256 tokenId) external onlyApprovedMarket(positions[tokenId].market) {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert RevvFiErrors.PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit RevvFiEvents.PositionRedeemed(tokenId, pos.principal, 0);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Only handle transfers (not mints or burns)
        if (from != address(0) && to != address(0)) {
            // Remove from old owner
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];

            // Add to new owner
            lenderPositionIndex[to][tokenId] = lenderPositions[to].length;
            lenderPositions[to].push(tokenId);
        }
        // For burns (to == address(0)), remove from owner's list
        else if (from != address(0) && to == address(0)) {
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];
        }
        // For mints (from == address(0)), do nothing - already added in mintPosition

        return super._update(to, tokenId, auth);
    }

    function getLenderByTokenId(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
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

    function setBaseURI(string memory baseURI) external onlyFactory {
        _baseTokenURI = baseURI;
    }

    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        return tokenId < _nextTokenId && tokenId != 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_tokenExists(tokenId)) revert RevvFiErrors.PositionNotFound();

        string memory baseURI = _baseTokenURI;
        if (bytes(baseURI).length == 0) {
            return "";
        }

        return string(abi.encodePacked(baseURI, "/position/", tokenId.toString(), ".json"));
    }

    function getPositionMetadata(uint256 tokenId)
        external
        view
        returns (string memory name, string memory description, string memory image, string memory attributes)
    {
        if (!_tokenExists(tokenId)) revert RevvFiErrors.PositionNotFound();

        Position memory pos = positions[tokenId];

        name = string(abi.encodePacked(TOKEN_NAME, " #", tokenId.toString()));
        description = string(
            abi.encodePacked(
                "RevvFi Position NFT representing a ", pos.isSenior ? "Senior" : "Junior", " lending position."
            )
        );
        image = "https://revvfi.com/images/position-nft.png";
        attributes = "";
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
