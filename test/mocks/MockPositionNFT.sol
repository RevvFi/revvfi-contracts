// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockPositionNFT is ERC721 {
    uint256 private _nextTokenId = 1;
    mapping(uint256 => address) public markets;

    constructor() ERC721("Mock Position", "MPOS") {}

    function mint(address to, address market) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        markets[tokenId] = market;
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return super.ownerOf(tokenId);
    }
}
