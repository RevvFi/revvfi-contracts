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

contract FullLoanLifecycleTest is Test {
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
    address public lender1 = address(0x3);
    address public lender2 = address(0x4);
    address public lender3 = address(0x5);

    uint256 public constant DEPLOYMENT_FEE = 0.1 ether;
    uint256 public constant COLLATERAL_AMOUNT = 12 ether;
    uint256 public constant BORROW_AMOUNT = 10000e6;
    uint256 public constant APR_1 = 800;
    uint256 public constant APR_2 = 1000;
    uint256 public constant MIN_COLLATERAL_RATIO = 11000;
    uint256 public constant LIQUIDATION_THRESHOLD = 9500;

    function setUp() public {
        vm.deal(owner, DEPLOYMENT_FEE);
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, 2000e8);

        // Deploy implementation contracts
        address marketImpl = address(new RevvFiMarket());
        address escrowImpl = address(new RevvFiCollateralEscrow());
        address offerBookImpl = address(new RevvFiOfferBook());
        address liquidityQueueImpl = address(new RevvFiLiquidityQueue());

        // Deploy Factory FIRST
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

        // Deploy core contracts WITH factory address (no setFactory needed)
        positionNFT = IRevvFiPositionNFT(address(new RevvFiPositionNFT(address(factory))));
        liquidator = IRevvFiLiquidator(address(new RevvFiLiquidator(address(factory))));
        reputationRegistry = IReputationRegistry(address(new ReputationRegistry(address(factory))));

        // Set core contracts in factory
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

        vm.deal(borrower, 100 ether);

        vm.startPrank(lender1);
        usdc.mint(lender1, 20000e6);
        usdc.approve(address(offerBook), 20000e6);
        vm.stopPrank();

        vm.startPrank(lender2);
        usdc.mint(lender2, 20000e6);
        usdc.approve(address(offerBook), 20000e6);
        vm.stopPrank();

        vm.startPrank(lender3);
        usdc.mint(lender3, 20000e6);
        usdc.approve(address(offerBook), 20000e6);
        vm.stopPrank();
    }

    function _getCurrentPrice() internal view returns (uint256) {
        (, int256 price,,,) = oracle.latestRoundData();
        return uint256(price);
    }

    function _accrueInterest() internal {
        if (market.getTotalOwed() == 0) return;

        vm.startPrank(borrower);
        usdc.mint(borrower, 1);
        usdc.approve(address(market), 1);
        market.repay(1);
        vm.stopPrank();
    }

    function _warpAndAccrue(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));
        _accrueInterest();
    }

    function test_FullLoanLifecycle() public {
        vm.prank(lender1);
        offerBook.submitOffer(6000e6, APR_1, 0, 30 days);

        vm.prank(lender2);
        offerBook.submitOffer(6000e6, APR_2, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 12000e6);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        vm.stopPrank();

        vm.prank(borrower);
        market.borrow(BORROW_AMOUNT, false, 1200);

        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        uint256 weightedApr = 880;

        _warpAndAccrue(365 days);

        uint256 totalOwed = market.getTotalOwed();
        assertGt(totalOwed, BORROW_AMOUNT);

        uint256 expectedInterest = (BORROW_AMOUNT * weightedApr * 365 days) / (365 days * 10000);
        assertApproxEqAbs(totalOwed, BORROW_AMOUNT + expectedInterest, 100);

        vm.startPrank(borrower);
        usdc.mint(borrower, totalOwed);
        usdc.approve(address(market), totalOwed);
        market.repayFull();
        vm.stopPrank();

        assertEq(market.getTotalOwed(), 0);

        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));

        uint256[] memory lender1Positions = concretePositionNFT.getLenderPositions(lender1);
        for (uint256 i = 0; i < lender1Positions.length; i++) {
            vm.prank(lender1);
            uint256 claimable = market.getPositionClaimable(lender1Positions[i]);
            if (claimable > 0) {
                market.claimFunds(lender1Positions[i]);
            }
        }

        uint256[] memory lender2Positions = concretePositionNFT.getLenderPositions(lender2);
        for (uint256 i = 0; i < lender2Positions.length; i++) {
            vm.prank(lender2);
            uint256 claimable = market.getPositionClaimable(lender2Positions[i]);
            if (claimable > 0) {
                market.claimFunds(lender2Positions[i]);
            }
        }

        assertGt(usdc.balanceOf(lender1), 6000e6);
        assertGt(usdc.balanceOf(lender2), 4000e6);

        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertGt(reputation, 500);
        assertEq(reputation, 1000);
    }

    function test_InterestAccruesCorrectly() public {
        vm.prank(lender1);
        offerBook.submitOffer(BORROW_AMOUNT, APR_1, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);

        uint256 borrowTimestamp = block.timestamp;
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        vm.warp(borrowTimestamp + 180 days);
        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));
        _accrueInterest();

        uint256 totalOwed = market.getTotalOwed();
        uint256 expectedInterest = BORROW_AMOUNT * APR_1 * 180 days / (365 days * 10000);

        assertApproxEqAbs(totalOwed, BORROW_AMOUNT + expectedInterest, 100);

        uint256[] memory positions = positionNFT.getLenderPositions(lender1);
        assertGt(positions.length, 0);
        uint256 positionId = positions[0];
        assertGt(market.positionAccruedInterest(positionId), 0);
    }

    function test_MultipleLendersDifferentAPRs() public {
        vm.prank(lender1);
        offerBook.submitOffer(3000e6, 500, 0, 30 days);

        vm.prank(lender2);
        offerBook.submitOffer(3000e6, 800, 0, 30 days);

        vm.prank(lender3);
        offerBook.submitOffer(4000e6, 1000, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(8000e6, false, 1200);
        vm.stopPrank();

        assertEq(market.getTotalOwed(), 8000e6);

        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        assertEq(concretePositionNFT.getActivePositionCount(lender1), 1);
        assertEq(concretePositionNFT.getActivePositionCount(lender2), 1);
        assertEq(concretePositionNFT.getActivePositionCount(lender3), 1);

        uint256[] memory lender1Positions = concretePositionNFT.getLenderPositions(lender1);
        uint256[] memory lender2Positions = concretePositionNFT.getLenderPositions(lender2);
        uint256[] memory lender3Positions = concretePositionNFT.getLenderPositions(lender3);

        assertEq(market.positionApr(lender1Positions[0]), 500);
        assertEq(market.positionApr(lender2Positions[0]), 800);
        assertEq(market.positionApr(lender3Positions[0]), 1000);
    }

    function test_CurrentCycleBorrowedAmountTracking() public {
        vm.prank(lender1);
        offerBook.submitOffer(BORROW_AMOUNT, APR_1, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        uint256 reputationBefore = reputationRegistry.getReputationScore(borrower);
        assertEq(reputationBefore, 500);

        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        oracle.setFresh(int256(_getCurrentPrice()));
        _accrueInterest();

        uint256 totalOwed = market.getTotalOwed();
        assertGt(totalOwed, BORROW_AMOUNT);

        vm.startPrank(borrower);
        usdc.mint(borrower, totalOwed);
        usdc.approve(address(market), totalOwed);
        market.repayFull();
        vm.stopPrank();

        uint256 reputationAfter = reputationRegistry.getReputationScore(borrower);
        assertGt(reputationAfter, reputationBefore);
        assertEq(reputationAfter, 1000);

        IReputationRegistry.BorrowerProfile memory profile = reputationRegistry.getBorrowerProfile(borrower);
        assertEq(profile.successfulLoans, 1);
        assertEq(profile.defaultedLoans, 0);
        assertEq(profile.totalBorrowed, BORROW_AMOUNT);
    }

    function test_PartialRepaymentWithInterest() public {
        vm.prank(lender1);
        offerBook.submitOffer(BORROW_AMOUNT, APR_1, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        _warpAndAccrue(180 days);

        uint256 totalOwed = market.getTotalOwed();
        uint256 expectedInterest = BORROW_AMOUNT * APR_1 * 180 days / (365 days * 10000);
        assertApproxEqAbs(totalOwed, BORROW_AMOUNT + expectedInterest, 100);

        uint256 halfRepayment = totalOwed / 2;
        vm.startPrank(borrower);
        usdc.mint(borrower, halfRepayment);
        usdc.approve(address(market), halfRepayment);
        market.repay(halfRepayment);
        vm.stopPrank();

        uint256 remainingDebt = market.getTotalOwed();
        assertApproxEqAbs(remainingDebt, totalOwed - halfRepayment, 2);

        _warpAndAccrue(90 days);

        uint256 finalDebt = market.getTotalOwed();
        assertGt(finalDebt, remainingDebt);

        vm.startPrank(borrower);
        usdc.mint(borrower, finalDebt);
        usdc.approve(address(market), finalDebt);
        market.repayFull();
        vm.stopPrank();

        assertEq(market.getTotalOwed(), 0);

        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertGt(reputation, 500);
    }
}
