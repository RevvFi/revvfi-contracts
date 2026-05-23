// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/RevvFiPositionNFT.sol";
import "../../src/libraries/RevvFiErrors.sol";

contract RevvFiPositionNFTTest is Test {
    RevvFiPositionNFT public positionNFT;
    address public factory = address(0x1);
    address public market = address(0x2);
    address public lender1 = address(0x3);
    address public lender2 = address(0x4);

    uint256 public constant PRINCIPAL = 1000e6;
    uint256 public constant APR = 1000;
    uint8 public constant SENIORITY = 0;

    function setUp() public {
        vm.prank(factory);
        positionNFT = new RevvFiPositionNFT(factory);
    }

    function test_RegisterMarket() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);
        assertTrue(positionNFT.approvedMarkets(market));
    }

    function test_MintPosition() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        RevvFiPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        assertEq(pos.market, market);
        assertEq(pos.principal, PRINCIPAL);
        assertEq(pos.apr, APR);
        assertEq(pos.seniority, SENIORITY);
        assertTrue(pos.active);
        assertTrue(pos.isSenior);
        assertEq(positionNFT.ownerOf(tokenId), lender1);
    }

    function test_CannotMintFromNonApprovedMarket() public {
        vm.prank(market);
        vm.expectRevert(RevvFiErrors.MarketNotRegistered.selector);
        positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);
    }

    function test_RedeemPosition() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        vm.prank(market);
        positionNFT.redeemPosition(tokenId);

        RevvFiPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        assertFalse(pos.active);
    }

    function test_GetLenderPositions() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);
        positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        uint256[] memory positions = positionNFT.getLenderPositions(lender1);
        assertEq(positions.length, 2);
    }

    function test_GetActivePositionCount() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId1 = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);
        uint256 tokenId2 = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        assertEq(positionNFT.getActivePositionCount(lender1), 2);

        vm.prank(market);
        positionNFT.redeemPosition(tokenId1);

        assertEq(positionNFT.getActivePositionCount(lender1), 1);
    }

    function test_TransferPosition() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        vm.prank(lender1);
        positionNFT.transferFrom(lender1, lender2, tokenId);

        assertEq(positionNFT.ownerOf(tokenId), lender2);

        uint256[] memory positions = positionNFT.getLenderPositions(lender2);
        assertEq(positions.length, 1);
        assertEq(positions[0], tokenId);
    }

    // FIXED: Properly check string length using bytes()
    function test_TokenURI() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        // With no base URI set
        string memory uri = positionNFT.tokenURI(tokenId);
        assertEq(uri, "");

        // Set base URI
        vm.prank(factory);
        positionNFT.setBaseURI("https://revvfi.com/api/nft");

        uri = positionNFT.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0);
        // Use string comparison instead of contains
        string memory expected =
            string(abi.encodePacked("https://revvfi.com/api/nft/position/", vm.toString(tokenId), ".json"));
        assertEq(uri, expected);
    }

    function test_IsPositionActive() public {
        vm.prank(factory);
        positionNFT.registerMarket(market);

        vm.prank(market);
        uint256 tokenId = positionNFT.mintPosition(lender1, market, PRINCIPAL, APR, SENIORITY);

        assertTrue(positionNFT.isPositionActive(tokenId));

        vm.prank(market);
        positionNFT.redeemPosition(tokenId);

        assertFalse(positionNFT.isPositionActive(tokenId));
    }
}
