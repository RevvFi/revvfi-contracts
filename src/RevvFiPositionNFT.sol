// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiPositionNFT
 * @author Preet Singh
 * @notice ERC721 NFT representing lender positions in lending markets
 * @dev Each minted position tracks principal, APR, seniority, and claimable amount
 */
contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    /**
     * @dev Represents a single lending position
     * @param tokenId Unique NFT identifier
     * @param market Associated lending market
     * @param principal Original principal amount
     * @param apr Annual percentage rate in basis points
     * @param seniority 0 for senior, 1 for junior
     * @param startTime When position was created
     * @param active Whether position is still active
     * @param isSenior True if senior position
     */
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

    /// @dev Factory that deployed this NFT contract
    address public factory;

    /// @dev Mapping from token ID to position details
    mapping(uint256 => Position) public positions;

    /// @dev Positions held by each lender
    mapping(address => uint256[]) public lenderPositions;

    /// @dev Index of position in lender's position array for O(1) removal
    mapping(address => mapping(uint256 => uint256)) public lenderPositionIndex;

    /// @dev Markets approved to mint/burn positions
    mapping(address => bool) public approvedMarkets;

    /// @dev Next available token ID (starting from 1)
    uint256 private _nextTokenId;

    /// @dev Base URI for token metadata
    string private _baseTokenURI;

    /// @dev Token metadata constants
    string public constant TOKEN_NAME = "RevvFi Position";
    string public constant TOKEN_SYMBOL = "RVF-POS";

    /// @dev Restricts to factory contract
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /// @dev Restricts to approved markets (or factory)
    modifier onlyApprovedMarket(address market) {
        if (!approvedMarkets[market] && msg.sender != factory) {
            revert RevvFiErrors.MarketNotRegistered();
        }
        _;
    }

    /**
     * @dev Deploys position NFT contract
     * @param _factory Address of the RevvFiFactory
     */
    constructor(address _factory) ERC721(TOKEN_NAME, TOKEN_SYMBOL) Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
        _baseTokenURI = "";
    }

    /**
     * @dev Registers a market to mint/burn positions
     * @param market Address of the market to register
     * @notice Can be called by factory or the market itself during initialization
     */
    function registerMarket(address market) external {
        if (msg.sender != factory && msg.sender != market) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (approvedMarkets[market]) revert RevvFiErrors.MarketAlreadyRegistered();
        approvedMarkets[market] = true;
        emit RevvFiEvents.MarketRegistered(market);
    }

    /**
     * @dev Unregisters a market (factory only)
     * @param market Address of the market to unregister
     */
    function unregisterMarket(address market) external onlyFactory {
        if (!approvedMarkets[market]) revert RevvFiErrors.MarketNotRegistered();
        approvedMarkets[market] = false;
        emit RevvFiEvents.MarketUnregistered(market);
    }

    /**
     * @dev Mints a new position NFT
     * @param lender Address that will own the NFT
     * @param market Associated lending market
     * @param principal Principal amount of the position
     * @param apr APR in basis points
     * @param seniority Seniority level (0 = senior, 1 = junior)
     * @return tokenId ID of the minted NFT
     */
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

    /**
     * @dev Burns a position NFT when fully redeemed
     * @param tokenId ID of the position to burn
     * @notice Only callable by the associated market
     */
    function redeemPosition(uint256 tokenId) external onlyApprovedMarket(positions[tokenId].market) {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert RevvFiErrors.PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit RevvFiEvents.PositionRedeemed(tokenId, pos.principal, 0);
    }

    /**
     * @dev Overridden transfer hook to maintain lender position lists
     * @param to New owner address
     * @param tokenId Token being transferred
     * @param auth Authorized address
     * @return Result of parent _update
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Handle transfers (not mints or burns)
        if (from != address(0) && to != address(0)) {
            // Remove from old owner's list
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];

            // Add to new owner's list
            lenderPositionIndex[to][tokenId] = lenderPositions[to].length;
            lenderPositions[to].push(tokenId);
        }
        // Handle burns (to == address(0))
        else if (from != address(0) && to == address(0)) {
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];
        }
        // Mints (from == address(0)) are already handled in mintPosition

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Returns owner of a position NFT
     * @param tokenId Token ID to query
     * @return Address of the owner
     */
    function getLenderByTokenId(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
    }

    /**
     * @dev Returns position details
     * @param tokenId Token ID to query
     * @return Position struct
     */
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @dev Returns all position IDs owned by a lender
     * @param lender Address of the lender
     * @return Array of token IDs
     */
    function getLenderPositions(address lender) external view returns (uint256[] memory) {
        return lenderPositions[lender];
    }

    /**
     * @dev Counts active positions for a lender
     * @param lender Address of the lender
     * @return Number of active positions
     */
    function getActivePositionCount(address lender) external view returns (uint256) {
        uint256 count = 0;
        uint256[] storage posIds = lenderPositions[lender];
        for (uint256 i = 0; i < posIds.length; i++) {
            if (positions[posIds[i]].active) count++;
        }
        return count;
    }

    /**
     * @dev Checks if a position is active
     * @param tokenId Token ID to check
     * @return True if position is active
     */
    function isPositionActive(uint256 tokenId) external view returns (bool) {
        return positions[tokenId].active;
    }

    /**
     * @dev Sets base URI for token metadata (factory only)
     * @param baseURI New base URI
     */
    function setBaseURI(string memory baseURI) external onlyFactory {
        _baseTokenURI = baseURI;
    }

    /**
     * @dev Checks if a token exists
     * @param tokenId Token ID to check
     * @return True if token exists
     */
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        return tokenId < _nextTokenId && tokenId != 0;
    }

    /**
     * @dev Returns token metadata URI
     * @param tokenId Token ID
     * @return Metadata URI string
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_tokenExists(tokenId)) revert RevvFiErrors.PositionNotFound();

        string memory baseURI = _baseTokenURI;
        if (bytes(baseURI).length == 0) {
            return "";
        }

        return string(abi.encodePacked(baseURI, "/position/", tokenId.toString(), ".json"));
    }

    /**
     * @dev Returns structured metadata for off-chain use
     * @param tokenId Token ID
     * @return name Token name
     * @return description Token description
     * @return image Image URL
     * @return attributes Attribute string
     */
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

    /**
     * @dev ERC721 interface support
     * @param interfaceId Interface identifier
     * @return True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
