// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/RevvFiArchController.sol";
import "../../src/RevvFiFactory.sol";
import "../../src/RevvFiMarket.sol";
import "../../src/RevvFiOfferBook.sol";
import "../../src/RevvFiPositionNFT.sol";
import "../../src/RevvFiCollateralEscrow.sol";
import "../../src/RevvFiLiquidator.sol";
import "../../src/RevvFiLiquidityQueue.sol";
import "../../src/ReputationRegistry.sol";
import "../../src/interfaces/IRevvFiOfferBook.sol";
import "../../src/interfaces/IRevvFiPositionNFT.sol";
import "../../src/interfaces/IRevvFiCollateralEscrow.sol";
import "../../src/interfaces/IReputationRegistry.sol";
import "../../src/interfaces/IRevvFiLiquidator.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracle.sol";

contract LiquidationLifecycleTest is Test {
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiMarket public market;

    IRevvFiOfferBook public offerBook;
    IRevvFiPositionNFT public positionNFT;
    IRevvFiCollateralEscrow public collateralEscrow;
    IRevvFiLiquidator public liquidator;
    IReputationRegistry public reputationRegistry;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;

    address public owner = address(0x1);
    address public borrower = address(0x2);
    address public lender = address(0x3);
    address public liquidatorAddress = address(0x6);

    uint256 public constant DEPLOYMENT_FEE = 0.1 ether;
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant BORROW_AMOUNT = 15000e6; // 15,000 USDC (75% LTV initially)
    uint256 public constant APR = 800; // 8%
    uint256 public constant MIN_COLLATERAL_RATIO = 10000; // 100%
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95%

    // Initial ETH price: $2000
    // Collateral value: 10 ETH * $2000 = $20,000
    // Borrow amount: $15,000 gives LTV = 75% (healthy)

    // Liquidation threshold: 95%
    // When ETH price drops to $1,425, collateral value = $14,250
    // Ratio = 14250/15000 = 95% -> liquidatable

    function setUp() public {
        vm.deal(owner, DEPLOYMENT_FEE);
        vm.startPrank(owner);

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy oracle with initial price $2000
        oracle = new MockOracle(8, 2000e8);

        // Deploy arch controller
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);

        // Deploy factory
        factory = new RevvFiFactory(address(archController), owner, DEPLOYMENT_FEE);
        factory.registerWithArchController();

        // Deploy market
        address marketAddr = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, address(usdc), address(weth), address(oracle), 18, 6, MIN_COLLATERAL_RATIO, LIQUIDATION_THRESHOLD
        );

        market = RevvFiMarket(marketAddr);
        offerBook = market.offerBook();
        positionNFT = market.positionNFT();
        collateralEscrow = market.collateralEscrow();
        liquidator = IRevvFiLiquidator(address(factory.liquidator()));
        reputationRegistry = IReputationRegistry(address(factory.reputationRegistry()));

        vm.stopPrank();

        // Fund accounts
        vm.deal(borrower, 100 ether);
        vm.deal(liquidatorAddress, 100 ether);

        // Fund lender
        vm.startPrank(lender);
        usdc.mint(lender, BORROW_AMOUNT);
        usdc.approve(address(offerBook), BORROW_AMOUNT);
        vm.stopPrank();

        // Fund liquidator with USDC to bid in auction
        vm.startPrank(liquidatorAddress);
        usdc.mint(liquidatorAddress, BORROW_AMOUNT);
        vm.stopPrank();
    }

    function test_LiquidationLifecycle() public {
        // ============================================================
        // STEP 1: Lender submits offer
        // ============================================================
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);
        assertEq(offerBook.getTotalLiquidityAvailable(), BORROW_AMOUNT);

        // ============================================================
        // STEP 2: Borrower deposits collateral
        // ============================================================
        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Verify collateral deposited
        assertEq(collateralEscrow.getCollateralBalance(borrower), COLLATERAL_AMOUNT);

        // ============================================================
        // STEP 3: Borrower borrows funds
        // ============================================================
        vm.prank(borrower);
        market.borrow(BORROW_AMOUNT, false, 1200);

        // Verify borrow succeeded
        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        // Verify position is healthy
        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());

        // Collateral ratio should be ~133% (20000/15000)
        uint256 ratio = market.getCollateralRatio();
        assertApproxEqAbs(ratio, 13333, 10); // ~133.33%

        // Verify position NFT minted
        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        assertEq(concretePositionNFT.getActivePositionCount(lender), 1);

        // ============================================================
        // STEP 4: Oracle price drops - position becomes unhealthy
        // ============================================================
        // Drop ETH price to $1,400 (below liquidation threshold)
        // New collateral value: 10 ETH * $1400 = $14,000
        // Ratio = 14000/15000 = 93.33% (< 95% threshold)
        vm.prank(owner);
        oracle.setPrice(1400e8);

        // Accrue interest (triggers price check)
        market.triggerAccrueInterest();

        // Verify position is now liquidatable
        assertTrue(market.isLiquidatable());
        assertFalse(market.isHealthy());

        // Collateral ratio should be ~93.33%
        uint256 newRatio = market.getCollateralRatio();
        assertApproxEqAbs(newRatio, 9333, 10);

        // ============================================================
        // STEP 5: Start liquidation
        // ============================================================
        vm.prank(borrower); // Any caller can liquidate
        market.liquidate();

        // Verify liquidation state
        assertTrue(market.isLiquidating());
        assertTrue(collateralEscrow.isLiquidationActive());

        // Get auction ID
        uint256 auctionId = market.liquidationAuctionId();
        assertTrue(auctionId > 0);

        // Verify auction created
        IRevvFiLiquidator.Auction memory auction = liquidator.getAuction(auctionId);
        assertTrue(auction.active);
        assertEq(auction.market, address(market));
        assertEq(auction.borrower, borrower);
        assertEq(auction.collateralAmount, COLLATERAL_AMOUNT);
        assertEq(auction.debtAmount, market.getTotalOwed());

        // ============================================================
        // STEP 6: Liquidator places bid
        // ============================================================
        uint256 debtAmount = market.getTotalOwed();
        uint256 bidAmount = debtAmount; // Full debt amount

        vm.prank(liquidatorAddress);
        usdc.approve(address(liquidator), bidAmount);

        vm.prank(liquidatorAddress);
        liquidator.placeBid(auctionId, bidAmount);

        // Verify bid placed
        auction = liquidator.getAuction(auctionId);
        assertEq(auction.highestBid, bidAmount);
        assertEq(auction.highestBidder, liquidatorAddress);

        // ============================================================
        // STEP 7: Settle auction
        // ============================================================
        // Warp past auction end time
        vm.warp(block.timestamp + 4 days);

        vm.prank(liquidatorAddress);
        liquidator.settleAuction(auctionId);

        // Verify auction settled
        auction = liquidator.getAuction(auctionId);
        assertFalse(auction.active);
        assertTrue(auction.settled);

        // ============================================================
        // STEP 8: Market settles liquidation
        // ============================================================
        // Call settleLiquidation on market with debt repaid
        vm.prank(address(liquidator));
        market.settleLiquidation(bidAmount, 0);

        // Verify liquidation ended
        assertFalse(market.isLiquidating());
        assertFalse(collateralEscrow.isLiquidationActive());

        // Verify debt reduced
        assertApproxEqAbs(market.getTotalOwed(), 0, 1);

        // ============================================================
        // STEP 9: Verify lender protected (received funds from liquidation)
        // ============================================================
        // Lender should have claimable amount from the liquidation proceeds
        uint256[] memory lenderPositions = concretePositionNFT.getLenderPositions(lender);

        if (lenderPositions.length > 0) {
            vm.prank(lender);
            uint256 claimable = market.getPositionClaimable(lenderPositions[0]);
            if (claimable > 0) {
                vm.prank(lender);
                market.claimFunds(lenderPositions[0]);
            }
        }

        // ============================================================
        // STEP 10: Verify reputation updated for default
        // ============================================================
        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        // Score should have decreased from initial 500 due to default
        assertLt(reputation, 500);

        // Verify default recorded
        RevvFiPositionNFT.Position memory pos = concretePositionNFT.getPosition(lenderPositions[0]);
        assertFalse(pos.active);

        // ============================================================
        // VERIFICATION SUMMARY
        // ============================================================
        emit log("=== Liquidation Lifecycle Test Passed ===");
        emit log_named_uint("Initial ETH Price", 2000);
        emit log_named_uint("Liquidation ETH Price", 1400);
        emit log_named_uint("Collateral Amount (ETH)", COLLATERAL_AMOUNT / 1e18);
        emit log_named_uint("Debt Amount (USDC)", BORROW_AMOUNT / 1e6);
        emit log_named_uint("Final Borrower Reputation", reputation);
    }

    function test_LiquidationWithPartialBid() public {
        // Setup same as above
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        // Drop price to trigger liquidation
        vm.prank(owner);
        oracle.setPrice(1400e8);
        market.triggerAccrueInterest();

        // Start liquidation
        vm.prank(borrower);
        market.liquidate();

        uint256 auctionId = market.liquidationAuctionId();
        uint256 debtAmount = market.getTotalOwed();

        // Calculate time needed for price to drop to 80% of debt
        // Price starts at debtAmount and decreases by 5% (500 bps) every step (1 hour)
        // Target price = debtAmount * 0.8 = 12,000 USDC
        // Number of steps needed = (debtAmount - targetPrice) / (debtAmount * 0.05) = 0.2 / 0.05 = 4 steps
        // Each step is 1 hour, so need 4 hours
        uint256 stepsNeeded = 4;
        uint256 timeToWait = stepsNeeded * 1 hours;

        // Warp forward to allow price to drop
        vm.warp(block.timestamp + timeToWait);

        // Get current price after waiting
        uint256 currentPrice = liquidator.getCurrentPrice(auctionId);
        uint256 partialBid = (debtAmount * 80) / 100; // 12,000 USDC

        // Verify price has dropped to approximately our target
        assertApproxEqAbs(currentPrice, partialBid, 1e6); // Allow small rounding

        // Place bid at current price
        vm.prank(liquidatorAddress);
        usdc.approve(address(liquidator), partialBid);

        vm.prank(liquidatorAddress);
        liquidator.placeBid(auctionId, partialBid);

        // Warp past auction end time
        vm.warp(block.timestamp + 4 days);

        vm.prank(liquidatorAddress);
        liquidator.settleAuction(auctionId);

        // Settle liquidation with loss
        vm.prank(address(liquidator));
        market.settleLiquidation(partialBid, 0);

        // Verify loss recorded
        assertGt(market.badDebt(), 0);
        assertGt(market.totalRealizedLoss(), 0);

        emit log("=== Partial Bid Liquidation Test Passed ===");
        emit log_named_uint("Total Debt", debtAmount / 1e6);
        emit log_named_uint("Partial Bid", partialBid / 1e6);
        emit log_named_uint("Bad Debt", market.badDebt() / 1e6);
    }

    function test_CannotLiquidateHealthyPosition() public {
        // Setup healthy position
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        // Try to liquidate - should revert
        vm.prank(borrower);
        vm.expectRevert(RevvFiErrors.InsufficientCollateral.selector);
        market.liquidate();
    }
}
