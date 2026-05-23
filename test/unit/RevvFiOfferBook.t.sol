// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/RevvFiOfferBook.sol";
import "../../src/libraries/RevvFiErrors.sol";
import "../mocks/MockERC20.sol";

contract RevvFiOfferBookTest is Test {
    RevvFiOfferBook public offerBook;
    MockERC20 public borrowToken;

    address public factory = address(0x1);
    address public market = address(0x2);
    address public lender1 = address(0x3);
    address public lender2 = address(0x4);
    address public lender3 = address(0x5);

    uint256 public constant MIN_OFFER_AMOUNT = 100e6;
    uint256 public constant ONE_DAY = 1 days;

    function setUp() public {
        vm.startPrank(factory);

        borrowToken = new MockERC20("USD Coin", "USDC", 6);
        offerBook = new RevvFiOfferBook(factory);
        offerBook.initialize(market, address(borrowToken));

        vm.stopPrank();

        // Mint tokens for lenders
        vm.startPrank(lender1);
        borrowToken.mint(lender1, 10000e6);
        borrowToken.approve(address(offerBook), 10000e6);
        vm.stopPrank();

        vm.startPrank(lender2);
        borrowToken.mint(lender2, 10000e6);
        borrowToken.approve(address(offerBook), 10000e6);
        vm.stopPrank();

        vm.startPrank(lender3);
        borrowToken.mint(lender3, 10000e6);
        borrowToken.approve(address(offerBook), 10000e6);
        vm.stopPrank();
    }

    function test_SubmitOffer() public {
        vm.prank(lender1);
        uint256 offerId = offerBook.submitOffer(1000e6, 800, 0, 30 days);

        RevvFiOfferBook.Offer memory offer = offerBook.getOffer(offerId);
        assertEq(offer.lender, lender1);
        assertEq(offer.amount, 1000e6);
        assertEq(offer.remainingAmount, 1000e6);
        assertEq(offer.apr, 800);
        assertEq(offer.seniority, 0);
        assertTrue(offer.active);
        assertTrue(offer.isSenior);
    }

    function test_CannotSubmitZeroAmount() public {
        vm.prank(lender1);
        vm.expectRevert(RevvFiErrors.ZeroAmount.selector);
        offerBook.submitOffer(0, 800, 0, 30 days);
    }

    function test_CannotSubmitBelowMinAmount() public {
        vm.prank(lender1);
        vm.expectRevert(RevvFiErrors.ZeroAmount.selector);
        offerBook.submitOffer(10e6, 800, 0, 30 days);
    }

    function test_CannotSubmitZeroApr() public {
        vm.prank(lender1);
        vm.expectRevert(RevvFiErrors.ZeroApr.selector);
        offerBook.submitOffer(1000e6, 0, 0, 30 days);
    }

    function test_CancelOffer() public {
        vm.prank(lender1);
        uint256 offerId = offerBook.submitOffer(1000e6, 800, 0, 30 days);

        vm.prank(lender1);
        offerBook.cancelOffer(offerId);

        RevvFiOfferBook.Offer memory offer = offerBook.getOffer(offerId);
        assertFalse(offer.active);
    }

    function test_ModifyOffer() public {
        vm.prank(lender1);
        uint256 offerId = offerBook.submitOffer(1000e6, 800, 0, 30 days);

        vm.prank(lender1);
        offerBook.modifyOffer(offerId, 1500e6, 900, 60 days);

        RevvFiOfferBook.Offer memory offer = offerBook.getOffer(offerId);
        assertEq(offer.amount, 1500e6);
        assertEq(offer.apr, 900);
        assertEq(offer.expiry, block.timestamp + 60 days);
    }

    function test_CannotModifyToLessThanFilled() public {
        // Lender submits offer
        vm.prank(lender1);
        uint256 offerId = offerBook.submitOffer(1000e6, 800, 0, 30 days);

        // Market borrows 600e6 from the offer (partial fill)
        vm.prank(market);
        offerBook.executeDrawdown(600e6, false);

        // Verify the offer now has 400e6 remaining
        RevvFiOfferBook.Offer memory offer = offerBook.getOffer(offerId);
        assertEq(offer.remainingAmount, 400e6);

        // Try to modify the offer to 500e6 total (but 600e6 already filled)
        // This should revert because new total (500e6) < filled amount (600e6)
        vm.prank(lender1);
        vm.expectRevert(RevvFiErrors.InsufficientOfferAmount.selector);
        offerBook.modifyOffer(offerId, 500e6, 900, 60 days);
    }

    function test_GetBestOffers_SingleOffer() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 800, 0, 30 days);

        (RevvFiOfferBook.Offer[] memory offers, uint256 totalAvailable, uint256 weightedApr) =
            offerBook.getBestOffers(1000e6, false);

        assertEq(offers.length, 1);
        assertEq(totalAvailable, 1000e6);
        assertEq(weightedApr, 800);
    }

    function test_GetBestOffers_MultipleOffers() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 1000, 0, 30 days); // 10% APR
        vm.prank(lender2);
        offerBook.submitOffer(1000e6, 800, 0, 30 days); // 8% APR
        vm.prank(lender3);
        offerBook.submitOffer(1000e6, 1200, 0, 30 days); // 12% APR

        (RevvFiOfferBook.Offer[] memory offers, uint256 totalAvailable, uint256 weightedApr) =
            offerBook.getBestOffers(1500e6, false);

        // Should get the 8% and 10% offers (lowest APR first)
        assertEq(offers.length, 2);
        assertEq(offers[0].apr, 800);
        assertEq(offers[1].apr, 1000);
        assertEq(totalAvailable, 1500e6);

        // Weighted average (800*1000 + 1000*500)/1500 = 866.67
        assertApproxEqAbs(weightedApr, 867, 1);
    }

    function test_GetBestOffers_SeniorOnly() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 1000, 0, 30 days); // Senior
        vm.prank(lender2);
        offerBook.submitOffer(1000e6, 800, 1, 30 days); // Junior

        (RevvFiOfferBook.Offer[] memory offers, uint256 totalAvailable, uint256 weightedApr) =
            offerBook.getBestOffers(1000e6, true);

        // Should only get senior offers
        assertEq(offers.length, 1);
        assertEq(offers[0].apr, 1000);
        assertTrue(offers[0].isSenior);
    }

    function test_GetBestOffers_InsufficientLiquidity() public {
        vm.prank(lender1);
        offerBook.submitOffer(500e6, 800, 0, 30 days);

        (RevvFiOfferBook.Offer[] memory offers, uint256 totalAvailable, uint256 weightedApr) =
            offerBook.getBestOffers(1000e6, false);

        assertEq(offers.length, 0);
        assertEq(totalAvailable, 0);
        assertEq(weightedApr, 0);
    }

    function test_ExecuteDrawdown() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 800, 0, 30 days);
        vm.prank(lender2);
        offerBook.submitOffer(500e6, 1000, 0, 30 days);

        vm.prank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) = offerBook.executeDrawdown(1200e6, false);

        assertEq(filledOffers.length, 2);

        RevvFiOfferBook.Offer memory offer1 = offerBook.getOffer(filledOffers[0].id);
        assertEq(offer1.remainingAmount, 0); // Fully filled
        assertFalse(offer1.active);
    }

    function test_CleanupExpiredOffers() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 800, 0, 1 seconds);

        vm.warp(block.timestamp + 2 seconds);

        vm.prank(lender1);
        offerBook.cleanupExpiredOffers(10);

        RevvFiOfferBook.Offer memory offer = offerBook.getOffer(1);
        assertFalse(offer.active);
        assertEq(offer.remainingAmount, 0);
    }

    function test_GetTotalLiquidityAvailable() public {
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 800, 0, 30 days);
        vm.prank(lender2);
        offerBook.submitOffer(2000e6, 900, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 3000e6);
    }
}
