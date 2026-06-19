// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../src/RevvFiOfferBook.sol";
import "../../src/libraries/RevvFiErrors.sol";
import "../mocks/MockERC20.sol";

/**
 * @title BucketCorruptionFixTest
 * @notice Tests the fix for bucket corruption issue that caused silent reverts
 * @dev This test reproduces the scenario where:
 *      1. Offers are submitted and added to buckets
 *      2. Offers are cancelled, leaving empty buckets in aprValues
 *      3. New borrow attempts fail with silent 0x revert
 */
contract BucketCorruptionFixTest is Test {
    using Clones for address;

    RevvFiOfferBook public offerBook;
    RevvFiOfferBook public implementation;
    MockERC20 public borrowToken;

    address public factory = address(0x1);
    address public market = address(0x2);
    address public lender1 = address(0x3);
    address public lender2 = address(0x4);

    function setUp() public {
        vm.startPrank(factory);

        borrowToken = new MockERC20("USD Coin", "USDC", 6);

        // Deploy implementation contract
        implementation = new RevvFiOfferBook();

        // Clone the implementation to get a fresh instance that can be initialized
        offerBook = RevvFiOfferBook(address(implementation).clone());

        // Initialize the clone
        offerBook.initialize(factory, market, address(borrowToken));

        vm.stopPrank();

        // Setup lender1
        vm.startPrank(lender1);
        borrowToken.mint(lender1, 10000e6);
        borrowToken.approve(address(offerBook), 10000e6);
        vm.stopPrank();

        // Setup lender2
        vm.startPrank(lender2);
        borrowToken.mint(lender2, 10000e6);
        borrowToken.approve(address(offerBook), 10000e6);
        vm.stopPrank();
    }

    /**
     * @dev Test that reproduces the bucket corruption bug:
     *      1. Submit offers with same APR (go into same bucket)
     *      2. Cancel all offers (bucket becomes empty but stays in aprValues)
     *      3. Submit new offer with same APR
     *      4. Try to execute drawdown - should work after fix
     */
    function test_BucketCorruptionFix_CancelAndReborrow() public {
        // Step 1: Submit offers with APR 500 (bucket ID 5)
        vm.prank(lender1);
        uint256 offer1 = offerBook.submitOffer(1000e6, 500, 0, 30 days);

        vm.prank(lender2);
        uint256 offer2 = offerBook.submitOffer(1000e6, 500, 0, 30 days);

        // Verify offers are active
        assertTrue(offerBook.isActiveOffer(offer1));
        assertTrue(offerBook.isActiveOffer(offer2));
        assertEq(offerBook.getTotalLiquidityAvailable(), 2000e6);

        // Step 2: Cancel all offers - this should leave bucket empty but in aprValues
        vm.prank(lender1);
        offerBook.cancelOffer(offer1);

        vm.prank(lender2);
        offerBook.cancelOffer(offer2);

        // Verify offers are cancelled
        assertFalse(offerBook.isActiveOffer(offer1));
        assertFalse(offerBook.isActiveOffer(offer2));
        assertEq(offerBook.getTotalLiquidityAvailable(), 0);

        // Step 3: Submit new offer with same APR
        vm.prank(lender1);
        uint256 offer3 = offerBook.submitOffer(1000e6, 500, 0, 30 days);

        // Verify new offer is active
        assertTrue(offerBook.isActiveOffer(offer3));
        assertEq(offerBook.getTotalLiquidityAvailable(), 1000e6);

        // Step 4: Execute drawdown - this should work after the fix
        vm.startPrank(market);

        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) = offerBook.executeDrawdown(500e6, false);

        vm.stopPrank();

        // Verify drawdown succeeded
        assertEq(filledOffers.length, 1);
        assertEq(filledOffers[0].id, offer3);
        assertEq(filledOffers[0].remainingAmount, 500e6);
        assertEq(weightedApr, 500);
    }

    /**
     * @dev Test multiple cancellations and resubmissions with different APRs
     */
    function test_BucketCorruptionFix_MultipleBuckets() public {
        // Submit offers with different APRs
        vm.prank(lender1);
        uint256 offer1 = offerBook.submitOffer(1000e6, 400, 0, 30 days); // Bucket 4

        vm.prank(lender1);
        uint256 offer2 = offerBook.submitOffer(1000e6, 600, 0, 30 days); // Bucket 6

        vm.prank(lender2);
        uint256 offer3 = offerBook.submitOffer(1000e6, 800, 0, 30 days); // Bucket 8

        assertEq(offerBook.getTotalLiquidityAvailable(), 3000e6);

        // Cancel offers in bucket 4 and 8
        vm.prank(lender1);
        offerBook.cancelOffer(offer1);

        vm.prank(lender2);
        offerBook.cancelOffer(offer3);

        // Only bucket 6 should have liquidity
        assertEq(offerBook.getTotalLiquidityAvailable(), 1000e6);

        // Submit new offer in bucket 4 (which was emptied)
        vm.prank(lender2);
        uint256 offer4 = offerBook.submitOffer(2000e6, 400, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 3000e6);

        // Execute drawdown should work
        vm.startPrank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers, uint256 weightedApr) = offerBook.executeDrawdown(2500e6, false); // Need 2500 to use both buckets

        vm.stopPrank();

        // Should fill from bucket 4 first (lower APR), then bucket 6
        assertEq(filledOffers.length, 2);
        assertEq(filledOffers[0].apr, 400); // From bucket 4 (2000 USDC)
        assertEq(filledOffers[1].apr, 600); // From bucket 6 (500 USDC to reach 2500 total)
        assertTrue(weightedApr > 0);
    }

    /**
     * @dev Test that partial fills don't cause double removal
     */
    function test_BucketCorruptionFix_PartialFillNoDuplicateRemoval() public {
        // Submit large offer
        vm.prank(lender1);
        uint256 offer1 = offerBook.submitOffer(2000e6, 500, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 2000e6);

        // Execute partial drawdown (only 500 USDC out of 2000 USDC)
        vm.startPrank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers,) = offerBook.executeDrawdown(500e6, false);
        vm.stopPrank();

        // Verify partial fill
        assertEq(filledOffers.length, 1);
        assertEq(filledOffers[0].remainingAmount, 500e6); // Amount taken

        // Check remaining liquidity
        assertEq(offerBook.getTotalLiquidityAvailable(), 1500e6); // 2000 - 500

        // Verify offer is still active
        assertTrue(offerBook.isActiveOffer(offer1));

        // Second drawdown should work
        vm.startPrank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers2,) = offerBook.executeDrawdown(1000e6, false);
        vm.stopPrank();

        assertEq(filledOffers2.length, 1);
        assertEq(filledOffers2[0].remainingAmount, 1000e6);
        assertEq(offerBook.getTotalLiquidityAvailable(), 500e6); // 1500 - 1000
    }

    /**
     * @dev Test full fill removes offer and cleans up empty bucket
     */
    function test_BucketCorruptionFix_FullFillCleansUpBucket() public {
        // Submit single offer in a bucket
        vm.prank(lender1);
        uint256 offer1 = offerBook.submitOffer(1000e6, 700, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 1000e6);

        // Execute full drawdown
        vm.prank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers,) = offerBook.executeDrawdown(1000e6, false);

        assertEq(filledOffers.length, 1);
        assertEq(filledOffers[0].remainingAmount, 1000e6);

        // Verify offer is deactivated
        assertFalse(offerBook.isActiveOffer(offer1));
        assertEq(offerBook.getTotalLiquidityAvailable(), 0);

        // Submit new offer in same bucket - should work without issues
        vm.prank(lender2);
        uint256 offer2 = offerBook.submitOffer(1500e6, 700, 0, 30 days);

        assertTrue(offerBook.isActiveOffer(offer2));
        assertEq(offerBook.getTotalLiquidityAvailable(), 1500e6);

        // Drawdown should work
        vm.prank(market);
        (IRevvFiOfferBook.Offer[] memory filledOffers2,) = offerBook.executeDrawdown(1500e6, false);

        assertEq(filledOffers2.length, 1);
        assertEq(filledOffers2[0].id, offer2);
    }

    /**
     * @dev Test that getBestOffers works correctly after bucket cleanup
     */
    function test_BucketCorruptionFix_GetBestOffersAfterCleanup() public {
        // Submit and cancel offers to create empty buckets
        vm.prank(lender1);
        uint256 offer1 = offerBook.submitOffer(1000e6, 300, 0, 30 days);

        vm.prank(lender1);
        offerBook.cancelOffer(offer1);

        // Submit new offers in different buckets
        vm.prank(lender1);
        offerBook.submitOffer(1000e6, 500, 0, 30 days);

        vm.prank(lender2);
        offerBook.submitOffer(1000e6, 700, 0, 30 days);

        // getBestOffers should work correctly
        (IRevvFiOfferBook.Offer[] memory bestOffers, uint256 totalAvail, uint256 weightedApr) =
            offerBook.getBestOffers(1500e6, false);

        assertEq(bestOffers.length, 2);
        assertEq(totalAvail, 1500e6);
        assertEq(bestOffers[0].apr, 500); // Lower APR first
        assertEq(bestOffers[1].apr, 700);
        assertGt(weightedApr, 0);
    }
}
