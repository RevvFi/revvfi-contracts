// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../src/RevvFiCollateralEscrow.sol";
import "../../src/interfaces/IRevvFiCollateralEscrow.sol";
import "../../src/libraries/RevvFiErrors.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracle.sol";

contract RevvFiCollateralEscrowTest is Test {
    using Clones for address;

    RevvFiCollateralEscrow public escrow;
    RevvFiCollateralEscrow public implementation;
    MockERC20 public collateralToken;
    MockERC20 public borrowToken;
    MockOracle public oracle;

    address public factory = address(0x1);
    address public market = address(0x2);
    address public borrower = address(0x3);
    address public liquidator = address(0x4);

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant INITIAL_PRICE = 2000e8;

    function setUp() public {
        vm.startPrank(factory);

        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        borrowToken = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(8, int256(INITIAL_PRICE));

        // Deploy implementation contract (this will have _disableInitializers)
        implementation = new RevvFiCollateralEscrow();

        // Clone the implementation to get a fresh instance that can be initialized
        escrow = RevvFiCollateralEscrow(address(implementation).clone());

        // Initialize the clone
        escrow.initialize(
            factory, market, borrower, address(borrowToken), address(collateralToken), address(oracle), 18, 6
        );

        vm.stopPrank();

        // Set up borrower with tokens and approve the MARKET (not the escrow directly)
        vm.startPrank(borrower);
        collateralToken.mint(borrower, 10 ether);
        collateralToken.approve(market, 10 ether);
        vm.stopPrank();

        // Simulate what the market would do: transfer from borrower to market, then call escrow
        vm.startPrank(market);
        collateralToken.transferFrom(borrower, market, 10 ether);
        collateralToken.approve(address(escrow), 10 ether);
        escrow.depositCollateral(borrower, 10 ether);
        vm.stopPrank();
    }

    function test_Initialization() public view {
        assertEq(escrow.market(), market);
        assertEq(escrow.borrower(), borrower);
        assertEq(escrow.minCollateralRatio(), 10000);
        assertEq(escrow.liquidationThreshold(), 9500);
    }

    function test_DepositCollateral() public {
        address newBorrower = address(0x100);
        uint256 amount = 5 ether;

        vm.startPrank(newBorrower);
        collateralToken.mint(newBorrower, amount);
        collateralToken.approve(market, amount);
        vm.stopPrank();

        vm.startPrank(market);
        collateralToken.transferFrom(newBorrower, market, amount);
        collateralToken.approve(address(escrow), amount);
        escrow.depositCollateral(newBorrower, amount);
        vm.stopPrank();

        assertEq(escrow.collateralBalance(newBorrower), amount);
        assertEq(escrow.totalCollateral(), 10 ether + amount);
    }

    function test_CannotDepositZeroCollateral() public {
        vm.prank(market);
        vm.expectRevert(RevvFiErrors.ZeroAmount.selector);
        escrow.depositCollateral(borrower, 0);
    }

    function test_WithdrawCollateral() public {
        uint256 withdrawAmount = 5 ether;

        vm.prank(market);
        escrow.withdrawCollateral(borrower, withdrawAmount, 0);

        assertEq(escrow.collateralBalance(borrower), 10 ether - withdrawAmount);
        assertEq(escrow.totalCollateral(), 10 ether - withdrawAmount);
    }

    function test_CannotWithdrawMoreThanBalance() public {
        vm.prank(market);
        vm.expectRevert(RevvFiErrors.InsufficientCollateral.selector);
        escrow.withdrawCollateral(borrower, 20 ether, 0);
    }

    function test_GetCollateralRatio() public view {
        uint256 debt = 10000e6;
        uint256 ratio = escrow.getCollateralRatio(borrower, debt);
        assertEq(ratio, 20000);
    }

    function test_IsHealthy() public view {
        uint256 debt = 10000e6;
        assertTrue(escrow.isHealthy(borrower, debt));
    }

    function test_IsLiquidatable() public view {
        uint256 debt = 21100e6;
        assertTrue(escrow.isLiquidatable(borrower, debt));

        uint256 safeDebt = 20000e6;
        assertFalse(escrow.isLiquidatable(borrower, safeDebt));
    }

    function test_GetHealthStatus() public view {
        assertEq(
            uint256(escrow.getHealthStatus(borrower, 10000e6)), uint256(IRevvFiCollateralEscrow.HealthStatus.HEALTHY)
        );

        assertEq(
            uint256(escrow.getHealthStatus(borrower, 20500e6)), uint256(IRevvFiCollateralEscrow.HealthStatus.WARNING)
        );

        assertEq(
            uint256(escrow.getHealthStatus(borrower, 21100e6)),
            uint256(IRevvFiCollateralEscrow.HealthStatus.LIQUIDATABLE)
        );
    }

    function test_GetMaxBorrowable() public view {
        uint256 maxBorrowable = escrow.getMaxBorrowable(borrower);
        assertApproxEqAbs(maxBorrowable, 20000e6, 1e3);
    }

    function test_OraclePriceStale() public {
        MockOracle freshOracle = new MockOracle(8, int256(INITIAL_PRICE));

        // Create a fresh clone
        RevvFiCollateralEscrow freshEscrow = RevvFiCollateralEscrow(address(implementation).clone());

        vm.startPrank(factory);
        freshEscrow.initialize(
            factory, market, borrower, address(borrowToken), address(collateralToken), address(freshOracle), 18, 6
        );
        vm.stopPrank();

        vm.startPrank(borrower);
        collateralToken.mint(borrower, 10 ether);
        collateralToken.approve(market, 10 ether);
        vm.stopPrank();

        vm.startPrank(market);
        collateralToken.transferFrom(borrower, market, 10 ether);
        collateralToken.approve(address(freshEscrow), 10 ether);
        freshEscrow.depositCollateral(borrower, 10 ether);
        vm.stopPrank();

        vm.prank(factory);
        freshOracle.setStale();

        vm.prank(market);
        vm.expectRevert(RevvFiErrors.OraclePriceStale.selector);
        freshEscrow.isHealthy(borrower, 10000e6);
    }

    function test_SetMinCollateralRatio() public {
        uint256 newRatio = 12000;
        vm.prank(factory);
        escrow.setMinCollateralRatio(newRatio);
        assertEq(escrow.minCollateralRatio(), newRatio);
    }

    function test_CannotSetInvalidMinCollateralRatio() public {
        vm.prank(factory);
        vm.expectRevert(RevvFiErrors.CollateralBelowMinimum.selector);
        escrow.setMinCollateralRatio(0);
    }

    function test_StartLiquidation() public {
        vm.prank(market);
        escrow.startLiquidation();
        assertTrue(escrow.isLiquidationActive());
    }

    function test_EndLiquidation() public {
        vm.prank(market);
        escrow.startLiquidation();
        vm.prank(market);
        escrow.endLiquidation();
        assertFalse(escrow.isLiquidationActive());
    }
}

