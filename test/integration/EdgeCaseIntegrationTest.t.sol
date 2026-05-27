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

contract EdgeCaseIntegrationTest is Test {
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

    uint256 public constant DEPLOYMENT_FEE = 0.1 ether;
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant BORROW_AMOUNT = 10000e6;
    uint256 public constant APR = 800;
    uint256 public constant MIN_COLLATERAL_RATIO = 11000;
    uint256 public constant LIQUIDATION_THRESHOLD = 9500;

    function setUp() public {
        vm.deal(owner, DEPLOYMENT_FEE);
        vm.startPrank(owner);

        // Deploy tokens and oracle
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, 2000e8);

        // Deploy implementation contracts (for cloning)
        address marketImpl = address(new RevvFiMarket());
        address escrowImpl = address(new RevvFiCollateralEscrow());
        address offerBookImpl = address(new RevvFiOfferBook());
        address liquidityQueueImpl = address(new RevvFiLiquidityQueue());

        // Deploy Factory FIRST (without core contracts)
        factory = new RevvFiFactory(
            owner, // feeRecipient
            DEPLOYMENT_FEE, // deploymentFee
            marketImpl, // marketImpl
            escrowImpl, // escrowImpl
            offerBookImpl, // offerBookImpl
            liquidityQueueImpl // liquidityQueueImpl
        );

        // Deploy ArchController
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);

        // Deploy core contracts with factory address (no setFactory needed - they take factory in constructor)
        positionNFT = IRevvFiPositionNFT(address(new RevvFiPositionNFT(address(factory))));
        liquidator = IRevvFiLiquidator(address(new RevvFiLiquidator(address(factory))));
        reputationRegistry = IReputationRegistry(address(new ReputationRegistry(address(factory))));

        // Set core contracts in Factory (onlyOwner)
        factory.setCoreContracts(
            address(archController), address(positionNFT), address(liquidator), address(reputationRegistry)
        );

        // Register factory with ArchController
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

        // Fund and approve for lender
        vm.deal(borrower, 100 ether);
        vm.startPrank(lender);
        usdc.mint(lender, 50000e6);
        usdc.approve(address(offerBook), 50000e6);
        vm.stopPrank();
    }

    function _getCurrentPrice() internal view returns (uint256) {
        (, int256 price,,,) = oracle.latestRoundData();
        return uint256(price);
    }

    function _snapshot(string memory tag) internal {
        emit log("");
        emit log("########################################");
        emit log(tag);
        emit log("########################################");

        emit log_named_uint("Block Timestamp", block.timestamp);
        emit log_named_uint("Debt", market.getTotalOwed());
        emit log_named_uint("Ratio", market.getCollateralRatio());
        emit log_named_uint("Collateral", collateralEscrow.getCollateralBalance(borrower));
        emit log_named_uint("Price", _getCurrentPrice());
        emit log_named_uint("Liquidity", usdc.balanceOf(address(offerBook)));
        emit log_named_uint("Market USDC Balance", usdc.balanceOf(address(market)));
        emit log_named_uint("Borrower USDC Balance", usdc.balanceOf(borrower));
        emit log_named_uint("Lender USDC Balance", usdc.balanceOf(lender));
        emit log_string(market.isHealthy() ? "HEALTHY" : "UNHEALTHY");
        emit log_string(market.isLiquidatable() ? "LIQUIDATABLE" : "NOT LIQUIDATABLE");
        emit log("");
    }

    function _logMarketState(string memory title) internal {
        emit log("");
        emit log("=================================================");
        emit log(title);
        emit log("=================================================");

        emit log_named_uint("Block Timestamp", block.timestamp);
        emit log_named_uint("Borrower Collateral", collateralEscrow.getCollateralBalance(borrower));
        emit log_named_uint("Total Debt", market.getTotalOwed());
        emit log_named_uint("Collateral Ratio", market.getCollateralRatio());
        emit log_named_uint("Max Borrowable", market.getMaxBorrowable());
        emit log_named_uint("Oracle Price", _getCurrentPrice());
        emit log_named_uint("Borrower Reputation", reputationRegistry.getReputationScore(borrower));
        emit log_named_uint("OfferBook Liquidity", usdc.balanceOf(address(offerBook)));
        emit log_named_uint("Market USDC Balance", usdc.balanceOf(address(market)));
        emit log_named_uint("Escrow WETH Balance", weth.balanceOf(address(collateralEscrow)));
        emit log_named_uint("Borrower USDC Balance", usdc.balanceOf(borrower));
        emit log_named_uint("Borrower WETH Balance", weth.balanceOf(borrower));
        emit log_named_uint("Lender USDC Balance", usdc.balanceOf(lender));
        emit log_string(market.isHealthy() ? "HEALTHY" : "UNHEALTHY");
        emit log_string(market.isLiquidatable() ? "LIQUIDATABLE" : "NOT LIQUIDATABLE");
        emit log("");
    }

    function _logPositionState() internal {
        RevvFiPositionNFT nft = RevvFiPositionNFT(address(positionNFT));
        uint256 active = nft.getActivePositionCount(lender);

        emit log("");
        emit log("===== POSITION STATE =====");
        emit log_named_uint("Active Positions", active);

        uint256[] memory positions_arr = nft.getLenderPositions(lender);
        for (uint256 i = 0; i < positions_arr.length && i < 5; i++) {
            string memory label = string(abi.encodePacked("Position ", vm.toString(i)));
            emit log_named_uint(label, positions_arr[i]);
        }
        emit log("");
    }

    function _accrueInterest() internal {
        vm.startPrank(borrower);
        if (market.getTotalOwed() > 0) {
            usdc.mint(borrower, 1);
            usdc.approve(address(market), 1);
            market.repay(1);
        }
        vm.stopPrank();
    }

    function _warpAndAccrue(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        emit log("");
        emit log_named_uint("Added Duration", duration);
        emit log_named_uint("New Timestamp", block.timestamp);

        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));

        _accrueInterest();
    }

    function _borrow(uint256 amount) internal {
        emit log("");
        emit log("===== BORROW =====");
        emit log_named_uint("Requested Borrow", amount);

        _logMarketState("BEFORE BORROW");

        vm.prank(borrower);
        market.borrow(amount, false, 1200);

        _logMarketState("AFTER BORROW");
        _logPositionState();
    }

    function _repay(uint256 amount) internal {
        emit log("");
        emit log("===== REPAY =====");
        emit log_named_uint("Repayment Amount", amount);

        uint256 debtBefore = market.getTotalOwed();

        vm.startPrank(borrower);
        usdc.mint(borrower, amount);
        usdc.approve(address(market), amount);
        market.repay(amount);
        vm.stopPrank();

        uint256 debtAfter = market.getTotalOwed();

        emit log_named_uint("Debt Before", debtBefore);
        emit log_named_uint("Debt After", debtAfter);

        _logMarketState("AFTER REPAYMENT");
        _logPositionState();
    }

    function _repayFull() internal {
        emit log("");
        emit log("===== REPAY FULL =====");

        uint256 debtBefore = market.getTotalOwed();

        vm.startPrank(borrower);
        usdc.mint(borrower, debtBefore);
        usdc.approve(address(market), debtBefore);
        market.repayFull();
        vm.stopPrank();

        uint256 debtAfter = market.getTotalOwed();

        emit log_named_uint("Debt Before", debtBefore);
        emit log_named_uint("Debt After", debtAfter);

        _logMarketState("AFTER FULL REPAYMENT");
        _logPositionState();
    }

    function _depositCollateral(uint256 amount) internal {
        emit log("");
        emit log("===== DEPOSIT COLLATERAL =====");
        emit log_named_uint("Amount", amount);

        uint256 before = collateralEscrow.getCollateralBalance(borrower);

        vm.startPrank(borrower);
        weth.mint(borrower, amount);
        weth.approve(address(market), amount);
        market.depositCollateral(amount);
        vm.stopPrank();

        uint256 afterview = collateralEscrow.getCollateralBalance(borrower);

        emit log_named_uint("Collateral Before", before);
        emit log_named_uint("Collateral After", afterview);

        _logMarketState("AFTER COLLATERAL DEPOSIT");
    }

    function _setPrice(uint256 newPrice) internal {
        emit log("");
        emit log("===== ORACLE UPDATE =====");
        emit log_named_uint("New Price", newPrice);

        vm.prank(owner);
        oracle.setFresh(int256(newPrice));

        uint256 verifiedPrice = _getCurrentPrice();
        emit log_named_uint("Verified Price", verifiedPrice);

        _logMarketState("AFTER PRICE UPDATE");
    }

    // ============================================================
    // TEST 1: Partial Repayment (20%, 50%, remaining)
    // ============================================================
    function test_PartialRepayment() public {
        _snapshot("TEST START");

        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(BORROW_AMOUNT);

        uint256 debtAfterBorrow = market.getTotalOwed();
        assertEq(debtAfterBorrow, BORROW_AMOUNT);

        _warpAndAccrue(30 days);

        uint256 totalOwed = market.getTotalOwed();
        uint256 expectedInterest = (BORROW_AMOUNT * APR * 30 days) / (365 days * 10000);
        assertApproxEqAbs(totalOwed, BORROW_AMOUNT + expectedInterest, 100);
        _snapshot("AFTER FIRST ACCRUAL");

        uint256 repayment20Percent = (totalOwed * 20) / 100;
        _repay(repayment20Percent);

        uint256 afterFirstRepayment = market.getTotalOwed();
        assertApproxEqAbs(afterFirstRepayment, totalOwed - repayment20Percent, 2);
        _snapshot("AFTER 20% REPAYMENT");

        _warpAndAccrue(30 days);

        uint256 afterSecondMonth = market.getTotalOwed();
        assertGt(afterSecondMonth, afterFirstRepayment);
        _snapshot("AFTER SECOND ACCRUAL");

        uint256 repayment50Percent = (afterSecondMonth * 50) / 100;
        _repay(repayment50Percent);

        uint256 afterSecondRepayment = market.getTotalOwed();
        assertApproxEqAbs(afterSecondRepayment, afterSecondMonth - repayment50Percent, 2);
        _snapshot("AFTER 50% REPAYMENT");

        _warpAndAccrue(30 days);

        uint256 beforeFinalRepayment = market.getTotalOwed();
        assertGt(beforeFinalRepayment, afterSecondRepayment);
        _snapshot("BEFORE FINAL REPAYMENT");

        _repayFull();

        assertEq(market.getTotalOwed(), 0);
        _snapshot("TEST END");

        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertGt(reputation, 500);

        emit log("=== Partial Repayment Test Passed ===");
        emit log_named_uint("Final Reputation Score", reputation);
    }

    // ============================================================
    // TEST 2: Collateral Top Up
    // ============================================================
    function test_CollateralTopUp() public {
        _snapshot("TEST START");

        uint256 largerOffer = BORROW_AMOUNT * 3;
        vm.prank(lender);
        offerBook.submitOffer(largerOffer, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(BORROW_AMOUNT);

        uint256 initialCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(initialCollateral, COLLATERAL_AMOUNT);
        assertTrue(market.isHealthy());
        _snapshot("INITIAL STATE");

        _setPrice(1800e8);

        assertTrue(market.isHealthy());
        uint256 ratioAfterDrop = market.getCollateralRatio();
        assertApproxEqAbs(ratioAfterDrop, 18000, 10);
        _snapshot("AFTER PRICE DROP");

        uint256 topUpAmount = 5 ether;
        _depositCollateral(topUpAmount);

        uint256 newCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(newCollateral, COLLATERAL_AMOUNT + topUpAmount);
        _snapshot("AFTER TOP UP");

        uint256 ratioAfterTopUp = market.getCollateralRatio();
        assertGt(ratioAfterTopUp, ratioAfterDrop);

        uint256 maxBorrowable = market.getMaxBorrowable();
        assertGt(maxBorrowable, 0);
        _snapshot("BEFORE ADDITIONAL BORROW");

        uint256 additionalBorrow = (maxBorrowable * 20) / 100;
        _borrow(additionalBorrow);

        assertApproxEqAbs(market.getTotalOwed(), BORROW_AMOUNT + additionalBorrow, 1);
        _snapshot("TEST END");

        emit log("=== Collateral Top Up Test Passed ===");
        emit log_named_uint("Initial Collateral", COLLATERAL_AMOUNT / 1e18);
        emit log_named_uint("Top Up Amount", topUpAmount / 1e18);
        emit log_named_uint("New Total Collateral", newCollateral / 1e18);
    }

    // ============================================================
    // TEST 3: Liquidation Recovery
    // ============================================================
    function test_LiquidationRecovery() public {
        _snapshot("TEST START");

        uint256 borrowAmount = 16000e6;

        vm.prank(lender);
        offerBook.submitOffer(borrowAmount + 10000e6, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(borrowAmount);

        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());
        _snapshot("INITIAL STATE");

        _setPrice(1650e8);
        _snapshot("AFTER PRICE DROP - BEFORE ADDITIONAL BORROW");

        uint256 currentDebt = market.getTotalOwed();
        uint256 maxBorrowable = market.getMaxBorrowable();

        if (maxBorrowable > 0 && currentDebt < 18000e6) {
            uint256 additionalBorrow = 2000e6;
            if (additionalBorrow <= maxBorrowable) {
                _borrow(additionalBorrow);
            }
        }

        _snapshot("AFTER ADDITIONAL BORROW");

        bool isHealthy = market.isHealthy();
        bool isLiquidatable = market.isLiquidatable();

        emit log_named_uint("Current Debt", market.getTotalOwed());
        emit log_named_uint("Current Collateral Ratio", market.getCollateralRatio());
        emit log_string(isHealthy ? "Position is healthy" : "Position is unhealthy");
        emit log_string(isLiquidatable ? "Position is liquidatable" : "Position is not liquidatable");

        uint256 recoveryAmount = 2 ether;
        _depositCollateral(recoveryAmount);
        _snapshot("AFTER RECOVERY COLLATERAL");

        uint256 newCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(newCollateral, COLLATERAL_AMOUNT + recoveryAmount);

        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());

        uint256 recoveredRatio = market.getCollateralRatio();
        assertGt(recoveredRatio, MIN_COLLATERAL_RATIO);

        _snapshot("TEST END");

        emit log("=== Liquidation Recovery Test Passed ===");
        emit log_named_uint("Recovered Ratio (bps)", recoveredRatio);
    }

    // ============================================================
    // TEST 4: Multiple Borrows with Different APRs
    // ============================================================
    function test_MultipleBorrowsDifferentAPRs() public {
        _snapshot("TEST START");

        uint256 offerAmount = 15000e6;

        vm.startPrank(lender);
        offerBook.submitOffer(offerAmount, 500, 0, 30 days);
        offerBook.submitOffer(offerAmount, 800, 0, 30 days);
        offerBook.submitOffer(offerAmount, 1000, 0, 30 days);
        vm.stopPrank();

        _logMarketState("AFTER OFFER SUBMISSIONS");

        uint256 totalCollateral = COLLATERAL_AMOUNT * 3;
        _depositCollateral(totalCollateral);
        _snapshot("AFTER COLLATERAL DEPOSIT");

        _borrow(offerAmount);
        _borrow(offerAmount);
        _borrow(offerAmount);

        _snapshot("AFTER ALL BORROWS");

        assertEq(market.getTotalOwed(), offerAmount * 3);

        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        uint256 activePositions = concretePositionNFT.getActivePositionCount(lender);
        assertEq(activePositions, 3);

        _logPositionState();

        _repayFull();

        _snapshot("AFTER REPAYMENT");
        assertEq(market.getTotalOwed(), 0);
        _snapshot("TEST END");

        emit log("=== Multiple Borrows Different APRs Test Passed ===");
    }

    // ============================================================
    // TEST 5: Reputation Registry Integration
    // ============================================================
    function test_ReputationRegistryIntegration() public {
        assertTrue(reputationRegistry.isBorrowerRegistered(borrower));
        assertEq(reputationRegistry.getReputationScore(borrower), 500);

        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(BORROW_AMOUNT);

        assertGt(reputationRegistry.getBorrowerProfile(borrower).totalBorrowed, 0);

        _repayFull();

        uint256 finalScore = reputationRegistry.getReputationScore(borrower);
        assertGt(finalScore, 500);

        IReputationRegistry.RiskLabel label = reputationRegistry.getRiskLabel(borrower);
        assertTrue(uint8(label) <= uint8(IReputationRegistry.RiskLabel.B));

        emit log("=== Reputation Registry Integration Test Passed ===");
        emit log_named_uint("Final Reputation Score", finalScore);
    }

    // ============================================================
    // TEST 6: Verify Interest Accrual Works Correctly
    // ============================================================
    function test_InterestAccrualWorks() public {
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(BORROW_AMOUNT);

        uint256 positionId = 1;

        assertEq(market.positionAccruedInterest(positionId), 0);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));

        vm.startPrank(borrower);
        usdc.mint(borrower, 1);
        usdc.approve(address(market), 1);
        market.repay(1);
        vm.stopPrank();

        uint256 accruedInterest = market.positionAccruedInterest(positionId);
        assertGt(accruedInterest, 0);

        uint256 expectedInterest = (BORROW_AMOUNT * APR * 30 days) / (365 days * 10000);
        assertApproxEqAbs(accruedInterest, expectedInterest, 100);

        assertApproxEqAbs(market.getTotalOwed(), BORROW_AMOUNT + expectedInterest, 100);

        emit log("=== Interest Accrual Test Passed ===");
        emit log_named_uint("Accrued Interest (USDC units)", accruedInterest);
        emit log_named_uint("Expected Interest (USDC units)", expectedInterest);
    }
}
