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
    
    function setUp() public {
        // Use pre-funded anvil accounts
        owner = vm.addr(0x1);      // Account 0
        borrower = vm.addr(0x2);    // Account 1  
        lender1 = vm.addr(0x3);     // Account 2
        lender2 = vm.addr(0x4);     // Account 3
        
        vm.deal(owner, 100 ether);
        vm.deal(borrower, 100 ether);
        vm.deal(lender1, 100 ether);
        vm.deal(lender2, 100 ether);
    }
    
    function run() public {
        vm.startBroadcast();
        
        // Step 1: Deploy mock tokens
        console.log("Deploying mock tokens...");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log("USDC deployed at:", address(usdc));
        console.log("WETH deployed at:", address(weth));
        
        // Step 2: Deploy mock oracle (price: $2000 per ETH)
        oracle = new MockOracle(8, 2000e8);
        console.log("Oracle deployed at:", address(oracle));
        
        // Step 3: Deploy ArchController
        archController = new RevvFiArchController();
        console.log("ArchController deployed at:", address(archController));
        
        // Register borrower
        archController.registerBorrower(borrower);
        console.log("Registered borrower:", borrower);
        
        // Step 4: Deploy Factory
        factory = new RevvFiFactory(address(archController), owner, DEPLOYMENT_FEE);
        console.log("Factory deployed at:", address(factory));
        
        // Register factory with arch controller
        factory.registerWithArchController();
        
        // Step 5: Deploy Market
        console.log("\nDeploying market...");
        address marketAddress = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower,                                    // borrower
            address(usdc),                              // borrowAsset
            address(weth),                              // collateralAsset
            address(oracle),                            // collateralOracle
            18,                                         // collateralDecimals
            6,                                          // borrowDecimals
            10000,                                      // minCollateralRatio (100%)
            9500                                        // liquidationThreshold (95%)
        );
        
        market = RevvFiMarket(marketAddress);
        console.log("Market deployed at:", marketAddress);
        
        vm.stopBroadcast();
        
        // Print summary
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Owner:", owner);
        console.log("Borrower:", borrower);
        console.log("Lender 1:", lender1);
        console.log("Lender 2:", lender2);
        console.log("\nContracts:");
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
        console.log("Oracle:", address(oracle));
        console.log("ArchController:", address(archController));
        console.log("Factory:", address(factory));
        console.log("Market:", address(market));
        console.log("\nMarket Configuration:");
        console.log("Borrow Asset:", address(usdc));
        console.log("Collateral Asset:", address(weth));
        console.log("Min Collateral Ratio: 100%");
        console.log("Liquidation Threshold: 95%");
    }
}
