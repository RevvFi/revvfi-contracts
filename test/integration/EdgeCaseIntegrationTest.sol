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
    uint256 public constant BORROW_AMOUNT = 10000e6; // 10,000 USDC
    uint256 public constant APR = 800; // 8%
    // Minimum collateral ratio must be at least 11000 (110%)
    uint256 public constant MIN_COLLATERAL_RATIO = 11000; // 110%
    // Liquidation threshold must be:
    // 1. Less than minCollateralRatio - MIN_LIQUIDATION_BUFFER (11000 - 500 = 10500)
    // 2. Less than 10000 (100%) 
    // 3. Greater than or equal to 100 (1%)
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95% - This meets all requirements

    // Track initial timestamp for proper time advancement
    uint256 public initialTimestamp;

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

        // Deploy market - using updated ratios that meet guardrails
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

        // Fund lender with enough USDC for all tests
        vm.startPrank(lender);
        usdc.mint(lender, 50000e6); // 50,000 USDC
        usdc.approve(address(offerBook), 50000e6);
        vm.stopPrank();

        // Store initial timestamp
        initialTimestamp = block.timestamp;
    }

    // ============================================================
    // DEBUG HELPERS
    // ============================================================

    function _getCurrentPrice() internal returns (uint256) {
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

        // Log first few positions if they exist
        uint256[] memory positions = nft.getLenderPositions(lender);
        for (uint256 i = 0; i < positions.length && i < 5; i++) {
            string memory label = string(abi.encodePacked("Position ", vm.toString(i)));
            emit log_named_uint(label, positions[i]);
        }
        emit log("");
    }

    function _warpAndAccrue(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        emit log("");
        emit log_named_uint("Added Duration", duration);
        emit log_named_uint("New Timestamp", block.timestamp);

        // Refresh oracle price to avoid stale price errors
        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));

        market.triggerAccrueInterest();
        _logMarketState("AFTER INTEREST ACCRUAL");
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

        // Verify price was set
        uint256 verifiedPrice = _getCurrentPrice();
        emit log_named_uint("Verified Price", verifiedPrice);

        _logMarketState("AFTER PRICE UPDATE");
    }

    // ============================================================
    // TEST 1: Partial Repayment (20%, 50%, remaining)
    // ============================================================
    function test_PartialRepayment() public {
        _snapshot("TEST START");

        // Setup - Lender submits offer
        vm.prank(lender);
        offerBook.submitOffer(BORROW_AMOUNT, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        // Borrower deposits collateral
        _depositCollateral(COLLATERAL_AMOUNT);

        // Borrower borrows full amount
        _borrow(BORROW_AMOUNT);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        // Accrue some interest (1 month)
        _warpAndAccrue(30 days);

        uint256 totalOwed = market.getTotalOwed();
        assertGt(totalOwed, BORROW_AMOUNT);
        _snapshot("AFTER FIRST ACCRUAL");

        // Repay 20%
        uint256 repayment20Percent = (totalOwed * 20) / 100;
        _repay(repayment20Percent);

        uint256 afterFirstRepayment = market.getTotalOwed();
        assertApproxEqAbs(afterFirstRepayment, totalOwed - repayment20Percent, 1);
        _snapshot("AFTER 20% REPAYMENT");

        // Wait another month - INCREMENT time
        _warpAndAccrue(30 days);

        uint256 afterSecondMonth = market.getTotalOwed();
        assertGt(afterSecondMonth, afterFirstRepayment);
        _snapshot("AFTER SECOND ACCRUAL");

        // Repay 50% of remaining
        uint256 repayment50Percent = (afterSecondMonth * 50) / 100;
        _repay(repayment50Percent);

        uint256 afterSecondRepayment = market.getTotalOwed();
        assertApproxEqAbs(afterSecondRepayment, afterSecondMonth - repayment50Percent, 1);
        _snapshot("AFTER 50% REPAYMENT");

        // Wait one more month - INCREMENT time again
        _warpAndAccrue(30 days);

        uint256 beforeFinalRepayment = market.getTotalOwed();
        assertGt(beforeFinalRepayment, afterSecondRepayment);
        _snapshot("BEFORE FINAL REPAYMENT");

        // Repay remaining balance
        _repayFull();

        assertEq(market.getTotalOwed(), 0);
        _snapshot("TEST END");

        // Verify reputation increased after full repayment
        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertGt(reputation, 500);

        emit log("=== Partial Repayment Test Passed ===");
        emit log_named_uint("Final Reputation Score", reputation);
    }

    // ============================================================
    // TEST 3: Collateral Top Up (Deposit more collateral when price drops)
    // ============================================================
    function test_CollateralTopUp() public {
        _snapshot("TEST START");

        // Setup - Submit larger offer to allow additional borrowing
        uint256 largerOffer = BORROW_AMOUNT * 3; // 30,000 USDC
        vm.prank(lender);
        offerBook.submitOffer(largerOffer, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        // Initial deposit
        _depositCollateral(COLLATERAL_AMOUNT);

        // Initial borrow
        _borrow(BORROW_AMOUNT);

        uint256 initialCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(initialCollateral, COLLATERAL_AMOUNT);
        assertTrue(market.isHealthy());
        _snapshot("INITIAL STATE");

        // Price drops - but keep above liquidation threshold
        _setPrice(1800e8);

        assertTrue(market.isHealthy()); // Still healthy
        uint256 ratioAfterDrop = market.getCollateralRatio();
        // With 110% min ratio and 10 ETH @ $1800 = $18,000, debt $10,000 = 180%
        assertApproxEqAbs(ratioAfterDrop, 18000, 10);
        _snapshot("AFTER PRICE DROP");

        // Top up with additional collateral
        uint256 topUpAmount = 5 ether;
        _depositCollateral(topUpAmount);

        uint256 newCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(newCollateral, COLLATERAL_AMOUNT + topUpAmount);
        _snapshot("AFTER TOP UP");

        // Ratio should improve
        uint256 ratioAfterTopUp = market.getCollateralRatio();
        assertGt(ratioAfterTopUp, ratioAfterDrop);

        // Verify can borrow more now
        uint256 maxBorrowable = market.getMaxBorrowable();
        assertGt(maxBorrowable, 0);
        _snapshot("BEFORE ADDITIONAL BORROW");

        // Borrow additional amount
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
    // TEST 4: Liquidation Recovery (Warning state -> deposit more -> healthy again)
    // ============================================================
    function test_LiquidationRecovery() public {
        _snapshot("TEST START");

        // Setup - Use appropriate borrow amount for 110% min ratio
        uint256 borrowAmount = 16000e6; // 16,000 USDC

        vm.prank(lender);
        offerBook.submitOffer(borrowAmount + 10000e6, APR, 0, 30 days);
        _logMarketState("AFTER OFFER SUBMISSION");

        _depositCollateral(COLLATERAL_AMOUNT);
        _borrow(borrowAmount);

        // Verify position is healthy initially
        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());
        _snapshot("INITIAL STATE");

        // Price drops to create warning state (but above liquidation threshold)
        _setPrice(1650e8);
        _snapshot("AFTER PRICE DROP - BEFORE ADDITIONAL BORROW");

        // Try to borrow more to push into unhealthy territory
        uint256 currentDebt = market.getTotalOwed();
        uint256 maxBorrowable = market.getMaxBorrowable();

        if (maxBorrowable > 0 && currentDebt < 18000e6) {
            uint256 additionalBorrow = 2000e6;
            if (additionalBorrow <= maxBorrowable) {
                _borrow(additionalBorrow);
            }
        }

        _snapshot("AFTER ADDITIONAL BORROW");

        // Log health status
        bool isHealthy = market.isHealthy();
        bool isLiquidatable = market.isLiquidatable();

        emit log_named_uint("Current Debt", market.getTotalOwed());
        emit log_named_uint("Current Collateral Ratio", market.getCollateralRatio());
        emit log_string(isHealthy ? "Position is healthy" : "Position is unhealthy");
        emit log_string(isLiquidatable ? "Position is liquidatable" : "Position is not liquidatable");

        // Borrower deposits more collateral to recover
        uint256 recoveryAmount = 2 ether;
        _depositCollateral(recoveryAmount);
        _snapshot("AFTER RECOVERY COLLATERAL");

        uint256 newCollateral = collateralEscrow.getCollateralBalance(borrower);
        assertEq(newCollateral, COLLATERAL_AMOUNT + recoveryAmount);

        // Should be healthy again (ratio should be > min collateral ratio)
        assertTrue(market.isHealthy());
        assertFalse(market.isLiquidatable());

        uint256 recoveredRatio = market.getCollateralRatio();
        assertGt(recoveredRatio, MIN_COLLATERAL_RATIO);

        _snapshot("TEST END");

        emit log("=== Liquidation Recovery Test Passed ===");
        emit log_named_uint("Recovered Ratio (bps)", recoveredRatio);
    }

    // ============================================================
    // TEST 5: Multiple Borrows with Different APRs
    // ============================================================
    function test_MultipleBorrowsDifferentAPRs() public {
        _snapshot("TEST START");

        // Submit offers at different APRs
        uint256 offerAmount = 15000e6; // 15,000 USDC each

        vm.startPrank(lender);
        offerBook.submitOffer(offerAmount, 500, 0, 30 days); // 5% APR
        offerBook.submitOffer(offerAmount, 800, 0, 30 days); // 8% APR
        offerBook.submitOffer(offerAmount, 1000, 0, 30 days); // 10% APR
        vm.stopPrank();

        _logMarketState("AFTER OFFER SUBMISSIONS");

        // Deposit enough collateral (3x) - with 110% min ratio
        uint256 totalCollateral = COLLATERAL_AMOUNT * 3;
        _depositCollateral(totalCollateral);
        _snapshot("AFTER COLLATERAL DEPOSIT");

        // Borrow in multiple transactions
        _borrow(offerAmount); // Takes 5% APR offer
        _borrow(offerAmount); // Takes 8% APR offer
        _borrow(offerAmount); // Takes 10% APR offer

        _snapshot("AFTER ALL BORROWS");

        assertEq(market.getTotalOwed(), offerAmount * 3);

        // All positions should be active
        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        uint256 activePositions = concretePositionNFT.getActivePositionCount(lender);
        assertEq(activePositions, 3);

        _logPositionState();

        // Full repayment
        _repayFull();

        _snapshot("AFTER REPAYMENT");
        assertEq(market.getTotalOwed(), 0);
        _snapshot("TEST END");

        emit log("=== Multiple Borrows Different APRs Test Passed ===");
    }
}