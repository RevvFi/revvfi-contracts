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
    uint256 public constant COLLATERAL_AMOUNT = 15 ether;
    uint256 public constant BORROW_AMOUNT = 15000e6; // 15,000 USDC
    uint256 public constant APR = 800; // 8%
    uint256 public constant MIN_COLLATERAL_RATIO = 11000; // 110%
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95%

    function setUp() public {
        vm.deal(owner, DEPLOYMENT_FEE);
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, 2000e8);

        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);

        factory = new RevvFiFactory(address(archController), owner, DEPLOYMENT_FEE);
        factory.registerWithArchController();

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

        vm.deal(borrower, 100 ether);
        vm.deal(liquidatorAddress, 100 ether);

        vm.startPrank(lender);
        usdc.mint(lender, BORROW_AMOUNT);
        usdc.approve(address(offerBook), BORROW_AMOUNT);
        vm.stopPrank();

        vm.startPrank(liquidatorAddress);
        usdc.mint(liquidatorAddress, BORROW_AMOUNT * 2);
        vm.stopPrank();
    }

    // Helper to trigger interest accrual
    function _accrueInterest() internal {
        vm.prank(borrower);
        vm.expectRevert();
        market.borrow(0, false, 1200);
    }

    function test_LiquidationLifecycle() public {
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);
        assertEq(offerBook.getTotalLiquidityAvailable(), BORROW_AMOUNT);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(collateralEscrow.getCollateralBalance(borrower), COLLATERAL_AMOUNT);

        vm.prank(borrower);
        market.borrow(BORROW_AMOUNT, false, 1200);

        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);
        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());

        // Drop price below liquidation threshold
        // 15 ETH * $945 = $14,175, debt $15,000 = 94.5% (9450 bps) < 9500 bps
        vm.prank(owner);
        oracle.setPrice(945e8);

        _accrueInterest();

        assertTrue(market.isLiquidatable());
        assertFalse(market.isHealthy());

        vm.prank(borrower);
        market.liquidate();

        assertTrue(market.isLiquidating());
        assertTrue(collateralEscrow.isLiquidationActive());

        uint256 auctionId = market.liquidationAuctionId();
        assertTrue(auctionId > 0);

        IRevvFiLiquidator.Auction memory auction = liquidator.getAuction(auctionId);
        assertTrue(auction.active);
        assertEq(auction.market, address(market));
        assertEq(auction.borrower, borrower);
        assertEq(auction.collateralAmount, COLLATERAL_AMOUNT);
        assertEq(auction.debtAmount, market.getTotalOwed());

        uint256 debtAmount = market.getTotalOwed();
        uint256 bidAmount = debtAmount;

        vm.prank(liquidatorAddress);
        usdc.approve(address(liquidator), bidAmount);

        vm.prank(liquidatorAddress);
        liquidator.placeBid(auctionId, bidAmount);

        auction = liquidator.getAuction(auctionId);
        assertEq(auction.highestBid, bidAmount);
        assertEq(auction.highestBidder, liquidatorAddress);

        vm.warp(block.timestamp + 4 days);

        vm.prank(liquidatorAddress);
        liquidator.settleAuction(auctionId);

        auction = liquidator.getAuction(auctionId);
        assertFalse(auction.active);
        assertTrue(auction.settled);

        vm.prank(address(liquidator));
        market.settleLiquidation(bidAmount, 0);

        assertFalse(market.isLiquidating());
        assertFalse(collateralEscrow.isLiquidationActive());
        assertApproxEqAbs(market.getTotalOwed(), 0, 1);

        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        uint256[] memory lenderPositions = concretePositionNFT.getLenderPositions(lender);

        if (lenderPositions.length > 0) {
            vm.prank(lender);
            uint256 claimable = market.getPositionClaimable(lenderPositions[0]);
            if (claimable > 0) {
                vm.prank(lender);
                market.claimFunds(lenderPositions[0]);
            }
        }

        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertLt(reputation, 500);

        emit log("=== Liquidation Lifecycle Test Passed ===");
        emit log_named_uint("Initial ETH Price", 2000);
        emit log_named_uint("Liquidation ETH Price", 945);
        emit log_named_uint("Collateral Amount (ETH)", COLLATERAL_AMOUNT / 1e18);
        emit log_named_uint("Debt Amount (USDC)", BORROW_AMOUNT / 1e6);
        emit log_named_uint("Final Borrower Reputation", reputation);
    }

    function test_LiquidationWithPartialBid() public {
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(945e8);
        _accrueInterest();

        vm.prank(borrower);
        market.liquidate();

        uint256 auctionId = market.liquidationAuctionId();
        uint256 debtAmount = market.getTotalOwed();

        uint256 stepsNeeded = 4;
        uint256 timeToWait = stepsNeeded * 1 hours;
        vm.warp(block.timestamp + timeToWait);

        uint256 currentPrice = liquidator.getCurrentPrice(auctionId);
        uint256 partialBid = (debtAmount * 80) / 100;

        assertApproxEqAbs(currentPrice, partialBid, 1e6);

        vm.prank(liquidatorAddress);
        usdc.approve(address(liquidator), partialBid);

        vm.prank(liquidatorAddress);
        liquidator.placeBid(auctionId, partialBid);

        vm.warp(block.timestamp + 4 days);

        vm.prank(liquidatorAddress);
        liquidator.settleAuction(auctionId);

        vm.prank(address(liquidator));
        market.settleLiquidation(partialBid, 0);

        assertGt(market.badDebt(), 0);
        assertGt(market.totalRealizedLoss(), 0);

        // Verify reputation was penalized for default
        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertLt(reputation, 500);

        emit log("=== Partial Bid Liquidation Test Passed ===");
        emit log_named_uint("Total Debt", debtAmount / 1e6);
        emit log_named_uint("Partial Bid", partialBid / 1e6);
        emit log_named_uint("Bad Debt", market.badDebt() / 1e6);
        emit log_named_uint("Borrower Reputation", reputation);
    }

    function test_CannotLiquidateHealthyPosition() public {
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        market.liquidate();
    }

    function test_DefaultRecordedInReputationRegistry() public {
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        uint256 reputationBefore = reputationRegistry.getReputationScore(borrower);

        // Force liquidation
        vm.prank(owner);
        oracle.setPrice(945e8);
        _accrueInterest();

        vm.prank(borrower);
        market.liquidate();

        uint256 auctionId = market.liquidationAuctionId();
        uint256 debtAmount = market.getTotalOwed();

        vm.prank(liquidatorAddress);
        usdc.approve(address(liquidator), debtAmount);

        vm.prank(liquidatorAddress);
        liquidator.placeBid(auctionId, debtAmount);

        vm.warp(block.timestamp + 4 days);

        vm.prank(liquidatorAddress);
        liquidator.settleAuction(auctionId);

        vm.prank(address(liquidator));
        market.settleLiquidation(debtAmount, 0);

        uint256 reputationAfter = reputationRegistry.getReputationScore(borrower);
        assertLt(reputationAfter, reputationBefore);

        IReputationRegistry.BorrowerProfile memory profile = reputationRegistry.getBorrowerProfile(borrower);
        assertEq(profile.defaultedLoans, 1);

        emit log("=== Default Recording Test Passed ===");
        emit log_named_uint("Reputation Before", reputationBefore);
        emit log_named_uint("Reputation After", reputationAfter);
        emit log_named_uint("Default Count", profile.defaultedLoans);
    }
}
