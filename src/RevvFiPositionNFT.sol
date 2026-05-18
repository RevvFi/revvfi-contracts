// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RevvFiPositionNFT
 * @notice ERC721 token representing a lender's debt position in a market
 * @dev Each position has its own APR, principal, and seniority
 */
contract RevvFiPositionNFT is ERC721Enumerable, Ownable {
    // ========================================================================== //
    //                                   Errors                                    //
    // ========================================================================== //

    error ZeroAddress();
    error UnauthorizedCaller();
    error PositionNotFound();
    error PositionAlreadyFinalized();

    // ========================================================================== //
    //                                   Events                                    //
    // ========================================================================== //

    event PositionMinted(
        uint256 indexed tokenId,
        address indexed lender,
        address indexed market,
        uint256 principal,
        uint256 apr,
        uint8 seniority
    );
    event PositionBurned(uint256 indexed tokenId);
    event InterestClaimed(uint256 indexed tokenId, uint256 amount);
    event PositionRedeemed(uint256 indexed tokenId, uint256 principalAmount, uint256 interestAmount);

    // ========================================================================== //
    //                                   Structs                                   //
    // ========================================================================== //

    struct Position {
        uint256 tokenId;
        address lender;
        address market;
        uint256 principal;
        uint256 apr; // Basis points (100 = 1%)
        uint8 seniority; // 0 = Senior, 1 = Junior
        uint256 startTime;
        uint256 lastAccrualTime;
        uint256 accruedInterest;
        bool active;
        bool isSenior;
    }

    // ========================================================================== //
    //                                   State                                     //
    // ========================================================================== //

    address public factory;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public lenderPositions;
    uint256 private _nextTokenId;

    // ========================================================================== //
    //                                 Modifiers                                   //
    // ========================================================================== //

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedCaller();
        _;
    }

    // ========================================================================== //
    //                                 Constructor                                //
    // ========================================================================== //

    constructor(address _factory) ERC721("RevvFi Position", "RVF-POS") Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        _nextTokenId = 1;
    }

    // ========================================================================== //
    //                              Position Management                            //
    // ========================================================================== //

    /**
     * @dev Mint a new position NFT (called by market)
     */
    function mintPosition(
        address lender,
        address market,
        uint256 principal,
        uint256 apr,
        uint8 seniority
    ) external onlyFactory returns (uint256 tokenId) {
        tokenId = _nextTokenId;
        _nextTokenId++;

        positions[tokenId] = Position({
            tokenId: tokenId,
            lender: lender,
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
        _safeMint(lender, tokenId);

        emit PositionMinted(tokenId, lender, market, principal, apr, seniority);
        
        return tokenId;
    }

    /**
     * @dev Update interest accrual for a position (called by market)
     */
    function updateInterest(uint256 tokenId) external onlyFactory returns (uint256 accrued) {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();

        uint256 timeElapsed = block.timestamp - pos.lastAccrualTime;
        if (timeElapsed == 0) return 0;

        accrued = (pos.principal * pos.apr * timeElapsed) / (365 days * 10000);
        pos.accruedInterest += accrued;
        pos.lastAccrualTime = block.timestamp;

        return accrued;
    }

    /**
     * @dev Claim accrued interest for a position (called by lender)
     */
    function claimInterest(uint256 tokenId) external returns (uint256 amount) {
        if (ownerOf(tokenId) != msg.sender) revert UnauthorizedCaller();

        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();

        // Update interest first
        uint256 timeElapsed = block.timestamp - pos.lastAccrualTime;
        if (timeElapsed > 0) {
            amount = (pos.principal * pos.apr * timeElapsed) / (365 days * 10000);
            pos.accruedInterest += amount;
            pos.lastAccrualTime = block.timestamp;
        } else {
            amount = pos.accruedInterest;
        }

        pos.accruedInterest = 0;

        emit InterestClaimed(tokenId, amount);
        
        return amount;
    }

    /**
     * @dev Redeem position (principal + interest) when loan is repaid
     */
    function redeemPosition(uint256 tokenId, uint256 principalAmount, uint256 interestAmount) external onlyFactory {
        Position storage pos = positions[tokenId];
        if (!pos.active) revert PositionNotFound();

        pos.active = false;
        _burn(tokenId);

        emit PositionRedeemed(tokenId, principalAmount, interestAmount);
    }

    /**
     * @dev Get claimable interest for a position
     */
    function getClaimableInterest(uint256 tokenId) external view returns (uint256) {
        Position storage pos = positions[tokenId];
        if (!pos.active) return 0;

        uint256 timeElapsed = block.timestamp - pos.lastAccrualTime;
        uint256 newInterest = (pos.principal * pos.apr * timeElapsed) / (365 days * 10000);
        return pos.accruedInterest + newInterest;
    }

    /**
     * @dev Get total value (principal + accrued interest)
     */
    function getPositionValue(uint256 tokenId) external view returns (uint256) {
        Position storage pos = positions[tokenId];
        if (!pos.active) return 0;

        uint256 timeElapsed = block.timestamp - pos.lastAccrualTime;
        uint256 accrued = (pos.principal * pos.apr * timeElapsed) / (365 days * 10000);
        return pos.principal + pos.accruedInterest + accrued;
    }

    // ========================================================================== //
    //                               View Functions                                //
    // ========================================================================== //

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
}