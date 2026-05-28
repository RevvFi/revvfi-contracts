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
 * @notice NFT contract representing lending positions in RevvFi protocol
 * @dev ERC721 token that tracks position details including market, principal, APR, and seniority
 */
contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    /**
     * @dev Structure representing a lending position
     * @param tokenId Unique identifier for the position NFT
     * @param market Address of the market contract where position exists
     * @param principal Principal amount lent
     * @param apr Annual Percentage Rate in basis points
     * @param seniority Seniority level (0=senior, 1=junior)
     * @param startTime Timestamp when position was created
     * @param active Whether position is still active
     * @param isSenior Boolean indicating if position is senior (convenience field)
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

    address public immutable factory; // Factory contract that created this NFT contract
    mapping(uint256 => Position) public positions; // Token ID => Position details
    mapping(address => uint256[]) public lenderPositions; // Lender address => Array of token IDs owned
    mapping(address => mapping(uint256 => uint256)) public lenderPositionIndex; // Lender => Token ID => Index in array
    mapping(address => bool) public approvedMarkets; // Market address => Whether approved to mint/redeem

    uint256 private _nextTokenId; // Next available token ID
    string private _baseTokenURI; // Base URI for token metadata

    string public constant TOKEN_NAME = "RevvFi Position"; // NFT collection name
    string public constant TOKEN_SYMBOL = "RVF-POS"; // NFT collection symbol

    /**
     * @dev Modifier to restrict access to factory contract only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert RevvFiErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to approved markets only
     * @param market Address of the market to check
     */
    modifier onlyApprovedMarket(address market) {
        if (!approvedMarkets[market]) revert RevvFiErrors.MarketNotRegistered();
        _;
    }

    /**
     * @dev Constructor sets the factory address and initializes ERC721
     * @param _factory Address of the factory contract
     */
    constructor(address _factory) ERC721(TOKEN_NAME, TOKEN_SYMBOL) Ownable(msg.sender) {
        if (_factory == address(0)) revert RevvFiErrors.ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
        _baseTokenURI = "";
    }

    /**
     * @dev Registers a market to mint and redeem positions
     * @param market Address of the market to register
     * @notice Only callable by factory contract
     */
    function registerMarket(address market) external onlyFactory {
        if (market == address(0)) revert RevvFiErrors.ZeroAddress();
        if (approvedMarkets[market]) revert RevvFiErrors.MarketAlreadyRegistered();
        approvedMarkets[market] = true;
        emit RevvFiEvents.MarketRegistered(market);
    }

    /**
     * @dev Unregisters a market, revoking its mint/redeem privileges
     * @param market Address of the market to unregister
     * @notice Only callable by factory contract
     */
    function unregisterMarket(address market) external onlyFactory {
        if (!approvedMarkets[market]) revert RevvFiErrors.MarketNotRegistered();
        approvedMarkets[market] = false;
        emit RevvFiEvents.MarketUnregistered(market);
    }

    /**
     * @dev Mints a new position NFT for a lender
     * @param lender Address of the lender receiving the NFT
     * @param market Address of the market creating the position
     * @param principal Principal amount lent
     * @param apr APR in basis points
     * @param seniority Seniority level (0=senior, 1=junior)
     * @return tokenId ID of the newly minted token
     */
    function mintPosition(address lender, address market, uint256 principal, uint256 apr, uint8 seniority)
        external
        onlyApprovedMarket(market)
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId;
        _nextTokenId++;

        // Store position details
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

        // Track position for lender
        lenderPositions[lender].push(tokenId);
        lenderPositionIndex[lender][tokenId] = lenderPositions[lender].length - 1;

        // Mint NFT to lender
        _safeMint(lender, tokenId);

        emit RevvFiEvents.PositionMinted(tokenId, lender, market, principal, apr, seniority);
        return tokenId;
    }

    /**
     * @dev Redeems (burns) a position NFT after it's settled
     * @param tokenId ID of the token to redeem
     * @notice Only callable by the market that created the position
     */
    function redeemPosition(uint256 tokenId) external onlyApprovedMarket(positions[tokenId].market) {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert RevvFiErrors.PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit RevvFiEvents.PositionRedeemed(tokenId, pos.principal, 0);
    }

    /**
     * @dev Overrides ERC721 _update to maintain lender position tracking on transfers
     * @param to Address receiving the token
     * @param tokenId ID of the token being transferred
     * @param auth Authorized address for the transfer
     * @return Address of the previous owner
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Handle transfer to new owner (not mint or burn)
        if (from != address(0) && to != address(0)) {
            // Remove from sender's position list
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            // Swap with last element and pop for O(1) removal
            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];

            // Add to receiver's position list
            lenderPositionIndex[to][tokenId] = lenderPositions[to].length;
            lenderPositions[to].push(tokenId);
        }
        // Handle burn (to == address(0))
        else if (from != address(0) && to == address(0)) {
            uint256[] storage fromPositions = lenderPositions[from];
            uint256 index = lenderPositionIndex[from][tokenId];
            uint256 lastId = fromPositions[fromPositions.length - 1];

            // Swap with last element and pop for O(1) removal
            fromPositions[index] = lastId;
            lenderPositionIndex[from][lastId] = index;
            fromPositions.pop();
            delete lenderPositionIndex[from][tokenId];
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Returns the lender (owner) of a position by token ID
     * @param tokenId ID of the token
     * @return Address of the token owner
     */
    function getLenderByTokenId(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
    }

    /**
     * @dev Returns full position details for a token ID
     * @param tokenId ID of the token
     * @return Position struct with all position data
     */
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @dev Returns all position token IDs owned by a lender
     * @param lender Address of the lender
     * @return Array of token IDs
     */
    function getLenderPositions(address lender) external view returns (uint256[] memory) {
        return lenderPositions[lender];
    }

    /**
     * @dev Returns count of active positions for a lender
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
     * @dev Checks if a position is still active
     * @param tokenId ID of the token
     * @return True if position is active
     */
    function isPositionActive(uint256 tokenId) external view returns (bool) {
        return positions[tokenId].active;
    }

    /**
     * @dev Sets the base URI for token metadata
     * @param baseURI New base URI string
     * @notice Only callable by factory contract
     */
    function setBaseURI(string memory baseURI) external onlyFactory {
        _baseTokenURI = baseURI;
    }

    /**
     * @dev Internal function to check if a token exists
     * @param tokenId ID of the token to check
     * @return True if token exists
     */
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        return tokenId < _nextTokenId && tokenId != 0;
    }

    /**
     * @dev Returns the URI for a token's metadata
     * @param tokenId ID of the token
     * @return Metadata URI string
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_tokenExists(tokenId)) revert RevvFiErrors.PositionNotFound();

        string memory baseURI = _baseTokenURI;
        if (bytes(baseURI).length == 0) return "";

        return string(abi.encodePacked(baseURI, "/position/", tokenId.toString(), ".json"));
    }

    /**
     * @dev Returns comprehensive metadata for a position
     * @param tokenId ID of the token
     * @return name Token name
     * @return description Token description
     * @return image Token image URL
     * @return attributes Token attributes (reserved for future use)
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
        attributes = ""; // Reserved for future attribute expansion
    }

    /**
     * @dev Overrides ERC721Enumerable supportsInterface
     * @param interfaceId Interface identifier to check
     * @return True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
