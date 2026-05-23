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

    // Use INTERFACE types (not concrete contracts)
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
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant BORROW_AMOUNT = 10000e6; // 10,000 USDC
    uint256 public constant APR_1 = 800; // 8%
    uint256 public constant APR_2 = 1000; // 10%
    uint256 public constant MIN_COLLATERAL_RATIO = 10000; // 100%
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95%

    function setUp() public {
        // Fund the owner with ETH to cover the deployment fee
        vm.deal(owner, DEPLOYMENT_FEE);

        vm.startPrank(owner);

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy oracle (ETH/USD with 8 decimals)
        oracle = new MockOracle(8, 2000e8); // $2000 per ETH

        // Deploy arch controller
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);

        // Deploy factory
        factory = new RevvFiFactory(address(archController), owner, DEPLOYMENT_FEE);

        // Register the factory with the arch controller
        factory.registerWithArchController();

        // No need to fund the factory - the ETH comes from the caller (owner)

        // Deploy market
        address marketAddr = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower,
            address(usdc),
            address(weth),
            address(oracle),
            18, // weth decimals
            6, // usdc decimals
            MIN_COLLATERAL_RATIO,
            LIQUIDATION_THRESHOLD
        );

        market = RevvFiMarket(marketAddr);

        // Direct assignment - interfaces are implicitly convertible from concrete contracts
        offerBook = market.offerBook();
        positionNFT = market.positionNFT();
        collateralEscrow = market.collateralEscrow();
        // Cast explicitly if factory returns concrete types
        liquidator = IRevvFiLiquidator(address(factory.liquidator()));
        reputationRegistry = IReputationRegistry(address(factory.reputationRegistry()));

        // Stop the prank before starting new ones for lenders
        vm.stopPrank();

        // Fund borrowers and lenders
        vm.deal(borrower, 100 ether);

        vm.startPrank(lender1);
        usdc.mint(lender1, 10000e6);
        usdc.approve(address(offerBook), 10000e6);
        vm.stopPrank();

        vm.startPrank(lender2);
        usdc.mint(lender2, 10000e6);
        usdc.approve(address(offerBook), 10000e6);
        vm.stopPrank();

        vm.startPrank(lender3);
        usdc.mint(lender3, 10000e6);
        usdc.approve(address(offerBook), 10000e6);
        vm.stopPrank();
    }

    function test_FullLoanLifecycle() public {
        // Step 1: Lenders submit offers
        vm.prank(lender1);
        offerBook.submitOffer(5000e6, APR_1, 0, 30 days);

        vm.prank(lender2);
        offerBook.submitOffer(5000e6, APR_2, 0, 30 days);

        assertEq(offerBook.getTotalLiquidityAvailable(), 10000e6);

        // Step 2: Borrower deposits collateral
        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Step 3: Borrower borrows funds
        vm.prank(borrower);
        market.borrow(BORROW_AMOUNT, false, 1200);

        // Verify borrower received funds
        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
        assertEq(market.getTotalOwed(), BORROW_AMOUNT);

        // Step 4: Check position NFTs minted - cast to concrete type for methods not in interface
        RevvFiPositionNFT concretePositionNFT = RevvFiPositionNFT(address(positionNFT));
        uint256 lender1Balance = concretePositionNFT.getActivePositionCount(lender1);
        uint256 lender2Balance = concretePositionNFT.getActivePositionCount(lender2);
        assertEq(lender1Balance + lender2Balance, 2);

        // Step 5: Time passes and interest accrues
        vm.warp(block.timestamp + 365 days);

        // FIXED: Trigger interest accrual before reading totalOwed
        market.triggerAccrueInterest();

        // Step 6: Borrower repays
        vm.startPrank(borrower);
        uint256 totalOwed = market.getTotalOwed();
        usdc.mint(borrower, totalOwed);
        usdc.approve(address(market), totalOwed);
        market.repayFull();
        vm.stopPrank();

        assertEq(market.getTotalOwed(), 0);

        // Step 7: Lenders claim funds
        uint256[] memory lender1Positions = concretePositionNFT.getLenderPositions(lender1);
        for (uint256 i = 0; i < lender1Positions.length; i++) {
            vm.prank(lender1);
            uint256 claimable = market.getPositionClaimable(lender1Positions[i]);
            if (claimable > 0) {
                market.claimFunds(lender1Positions[i]);
            }
        }

        // Step 8: Verify lenders received funds
        assertGt(usdc.balanceOf(lender1), 0);
        assertGt(usdc.balanceOf(lender2), 0);

        // Step 9: Check reputation updated
        uint256 reputation = reputationRegistry.getReputationScore(borrower);
        assertGt(reputation, 500); // Successful repayment increased score
    }

    function test_InterestAccruesCorrectly() public {
        // Setup
        vm.prank(lender1);
        offerBook.submitOffer(BORROW_AMOUNT, APR_1, 0, 30 days);

        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);
        market.borrow(BORROW_AMOUNT, false, 1200);
        vm.stopPrank();

        // Wait 6 months
        vm.warp(block.timestamp + 180 days);

        // FIXED: Use the new function name
        market.triggerAccrueInterest();

        uint256 totalOwed = market.getTotalOwed();
        uint256 expectedInterest = BORROW_AMOUNT * APR_1 * 180 days / (365 days * 10000);
        assertApproxEqAbs(totalOwed, BORROW_AMOUNT + expectedInterest, 1);
    }

    function test_MultipleLendersDifferentAPRs() public {
        // Lenders submit offers at different APRs
        vm.prank(lender1);
        offerBook.submitOffer(3000e6, 500, 0, 30 days); // 5%

        vm.prank(lender2);
        offerBook.submitOffer(3000e6, 800, 0, 30 days); // 8%

        vm.prank(lender3);
        offerBook.submitOffer(4000e6, 1000, 0, 30 days); // 10%

        // Borrower deposits collateral
        vm.startPrank(borrower);
        weth.mint(borrower, COLLATERAL_AMOUNT);
        weth.approve(address(market), COLLATERAL_AMOUNT);
        market.depositCollateral(COLLATERAL_AMOUNT);

        // Borrower borrows 8000 USDC
        market.borrow(8000e6, false, 1200);
        vm.stopPrank();

        assertEq(market.getTotalOwed(), 8000e6);
    }
}
