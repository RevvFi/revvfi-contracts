// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "../src/RevvFiArchController.sol";
import "../src/RevvFiFactory.sol";
import "../src/RevvFiMarket.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockOracle.sol";

contract DeployLocal is Script {
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiMarket public market;
    
    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;
    
    address public owner;
    address public borrower;
    address public lender1;
    address public lender2;
    
    uint256 public constant DEPLOYMENT_FEE = 0.1 ether;
    
    // Protocol guardrails
    uint256 public constant MIN_COLLATERAL_RATIO = 11000; // 110% (minimum allowed)
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95% (must be < 10000 and < minCollateralRatio - 500)
    
    function setUp() public {
        // Load addresses from .env file
        owner = vm.envAddress("OWNER");
        borrower = vm.envAddress("BORROWER");
        lender1 = vm.envAddress("LENDER1");
        lender2 = vm.envAddress("LENDER2");
        
        // Log account info for verification
        console.log("=== Account Configuration ===");
        console.log(string(abi.encodePacked("Owner: ", vm.toString(owner))));
        console.log(string(abi.encodePacked("Borrower: ", vm.toString(borrower))));
        console.log(string(abi.encodePacked("Lender 1: ", vm.toString(lender1))));
        console.log(string(abi.encodePacked("Lender 2: ", vm.toString(lender2))));
        console.log("=============================\n");
    }
    
    function run() public {
        // Start broadcast as owner (the private key we passed in)
        vm.startBroadcast();
        
        // Step 1: Deploy mock tokens
        console.log("Deploying mock tokens...");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log(string(abi.encodePacked("USDC deployed at: ", vm.toString(address(usdc)))));
        console.log(string(abi.encodePacked("WETH deployed at: ", vm.toString(address(weth)))));
        
        // Step 2: Deploy mock oracle (price: $2000 per ETH)
        oracle = new MockOracle(8, 2000e8);
        console.log(string(abi.encodePacked("Oracle deployed at: ", vm.toString(address(oracle)))));
        
        // Step 3: Deploy ArchController
        archController = new RevvFiArchController();
        console.log(string(abi.encodePacked("ArchController deployed at: ", vm.toString(address(archController)))));
        
        // Register borrower - No vm.prank needed, broadcaster is owner
        archController.registerBorrower(borrower);
        console.log(string(abi.encodePacked("Registered borrower: ", vm.toString(borrower))));
        
        // Step 4: Deploy Factory (owner deploys)
        factory = new RevvFiFactory(address(archController), owner, DEPLOYMENT_FEE);
        console.log(string(abi.encodePacked("Factory deployed at: ", vm.toString(address(factory)))));
        
        // Register factory with arch controller
        factory.registerWithArchController();
        
        // Step 5: Deploy Market (owner pays deployment fee)
        console.log("\nDeploying market...");
        console.log(string(abi.encodePacked("Deployment fee: ", vm.toString(DEPLOYMENT_FEE), " ETH")));
        console.log(string(abi.encodePacked("Min Collateral Ratio: ", vm.toString(MIN_COLLATERAL_RATIO / 100), "%")));
        console.log(string(abi.encodePacked("Liquidation Threshold: ", vm.toString(LIQUIDATION_THRESHOLD / 100), "%")));
        
        address marketAddress = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower,                                    // borrower
            address(usdc),                              // borrowAsset
            address(weth),                              // collateralAsset
            address(oracle),                            // collateralOracle
            18,                                         // collateralDecimals
            6,                                          // borrowDecimals
            MIN_COLLATERAL_RATIO,                       // minCollateralRatio (110% - meets guardrails)
            LIQUIDATION_THRESHOLD                       // liquidationThreshold (95% - meets guardrails)
        );
        
        market = RevvFiMarket(marketAddress);
        console.log(string(abi.encodePacked("Market deployed at: ", vm.toString(marketAddress))));
        
        vm.stopBroadcast();
        
        // Print deployment summary
        console.log("\n========================================");
        console.log("     DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("ACCOUNTS:");
        console.log(string(abi.encodePacked("  Owner:     ", vm.toString(owner))));
        console.log(string(abi.encodePacked("  Borrower:  ", vm.toString(borrower))));
        console.log(string(abi.encodePacked("  Lender 1:  ", vm.toString(lender1))));
        console.log(string(abi.encodePacked("  Lender 2:  ", vm.toString(lender2))));
        console.log("\nCONTRACTS:");
        console.log(string(abi.encodePacked("  USDC:             ", vm.toString(address(usdc)))));
        console.log(string(abi.encodePacked("  WETH:             ", vm.toString(address(weth)))));
        console.log(string(abi.encodePacked("  Oracle:           ", vm.toString(address(oracle)))));
        console.log(string(abi.encodePacked("  ArchController:   ", vm.toString(address(archController)))));
        console.log(string(abi.encodePacked("  Factory:          ", vm.toString(address(factory)))));
        console.log(string(abi.encodePacked("  Market:           ", vm.toString(marketAddress))));
        console.log("\nMARKET CONFIGURATION:");
        console.log(string(abi.encodePacked("  Borrow Asset:        ", vm.toString(address(usdc)))));
        console.log(string(abi.encodePacked("  Collateral Asset:    ", vm.toString(address(weth)))));
        console.log(string(abi.encodePacked("  Min Collateral Ratio: ", vm.toString(MIN_COLLATERAL_RATIO / 100), "% (", vm.toString(MIN_COLLATERAL_RATIO), " bps)")));
        console.log(string(abi.encodePacked("  Liquidation Threshold: ", vm.toString(LIQUIDATION_THRESHOLD / 100), "% (", vm.toString(LIQUIDATION_THRESHOLD), " bps)")));
        console.log(string(abi.encodePacked("  Liquidation Buffer:    ", vm.toString((MIN_COLLATERAL_RATIO - LIQUIDATION_THRESHOLD) / 100), "%")));
        console.log("\nGUARDRAILS VERIFICATION:");
        console.log("  Min ratio >= 110% (minimum protocol requirement)");
        console.log("  Liquidation threshold < min ratio - 5% buffer");
        console.log("  Liquidation threshold < 100%");
        console.log("  Liquidation threshold >= 1%");
        console.log("========================================");
        
        // Save deployment addresses to file - use a path that forge allows
        // Option 1: Write to a file in the project root
        string memory deploymentData = string(abi.encodePacked(
            "# Deployment Addresses\n",
            "# Generated: ", vm.toString(block.timestamp), "\n\n",
            "# Accounts\n",
            "OWNER=", vm.toString(owner), "\n",
            "BORROWER=", vm.toString(borrower), "\n",
            "LENDER1=", vm.toString(lender1), "\n",
            "LENDER2=", vm.toString(lender2), "\n\n",
            "# Contracts\n",
            "USDC=", vm.toString(address(usdc)), "\n",
            "WETH=", vm.toString(address(weth)), "\n",
            "ORACLE=", vm.toString(address(oracle)), "\n",
            "ARCH_CONTROLLER=", vm.toString(address(archController)), "\n",
            "FACTORY=", vm.toString(address(factory)), "\n",
            "MARKET=", vm.toString(marketAddress), "\n\n",
            "# Market Configuration\n",
            "MIN_COLLATERAL_RATIO=", vm.toString(MIN_COLLATERAL_RATIO), "\n",
            "LIQUIDATION_THRESHOLD=", vm.toString(LIQUIDATION_THRESHOLD), "\n",
            "DEPLOYMENT_FEE=", vm.toString(DEPLOYMENT_FEE), "\n"
        ));
        
        // Try to write the file - if it fails, just log the data
        try vm.writeFile("deployment.local.txt", deploymentData) {
            console.log("Deployment addresses saved to deployment.local.txt");
        } catch {
            console.log("Could not write to file, but here are the deployment details:");
            console.log(deploymentData);
        }
        
        console.log("\nNext Steps:");
        console.log("  1. Fund your borrower account with WETH for collateral");
        console.log("  2. Have lenders approve USDC to the OfferBook");
        console.log("  3. Lenders submit offers via the OfferBook");
        console.log("  4. Borrower deposits collateral and borrows USDC");
    }
}