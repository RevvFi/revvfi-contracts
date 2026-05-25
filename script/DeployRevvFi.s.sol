// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/RevvFiArchController.sol";
import "../src/RevvFiFactory.sol";
import "../src/RevvFiMarket.sol";
import "../src/RevvFiOfferBook.sol";
import "../src/RevvFiPositionNFT.sol";
import "../src/RevvFiCollateralEscrow.sol";
import "../src/RevvFiLiquidator.sol";
import "../src/RevvFiLiquidityQueue.sol";
import "../src/ReputationRegistry.sol";

/**
 * @title RevvFiDeploymentScript
 * @author Preet Singh
 * @notice Deploys the complete RevvFi protocol
 * @dev Run with: forge script script/RevvFiDeployment.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract RevvFiDeploymentScript is Script {
    // Configuration from environment variables
    address public owner;
    address public feeRecipient;
    uint256 public deploymentFee;

    // Token addresses (to be configured per network)
    address public usdc;
    address public weth;
    address public chainlinkEthUsd;

    // Deployed contract addresses
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    address public marketAddress;

    function setUp() public {
        // Load environment variables
        owner = vm.envAddress("OWNER");
        feeRecipient = vm.envAddress("FEE_RECIPIENT");
        deploymentFee = vm.envUint("DEPLOYMENT_FEE");

        // Token addresses - set these in your .env file
        usdc = vm.envAddress("USDC");
        weth = vm.envAddress("WETH");
        chainlinkEthUsd = vm.envAddress("CHAINLINK_ETH_USD");
    }

    function run() public {
        vm.startBroadcast();

        // Step 1: Deploy ArchController
        console2.log("Deploying RevvFiArchController...");
        archController = new RevvFiArchController();
        console2.log("ArchController deployed at:", address(archController));

        // Step 2: Register the owner as a borrower (owner can create markets)
        archController.registerBorrower(owner);
        console2.log("Registered owner as borrower");

        // Step 3: Deploy Factory
        console2.log("Deploying RevvFiFactory...");
        factory = new RevvFiFactory(
            address(archController),
            feeRecipient,
            deploymentFee
        );
        console2.log("Factory deployed at:", address(factory));

        // Step 4: Register factory with ArchController
        console2.log("Registering factory with ArchController...");
        factory.registerWithArchController();
        console2.log("Factory registered");

        // Step 5: Deploy a market (example: USDC borrow, WETH collateral)
        console2.log("Deploying market...");
        console2.log("  Borrower:", owner);
        console2.log("  Borrow Asset:", usdc);
        console2.log("  Collateral Asset:", weth);
        console2.log("  Oracle:", chainlinkEthUsd);
        console2.log("  Collateral Decimals:", 18);
        console2.log("  Borrow Decimals:", 6);
        console2.log("  Min Collateral Ratio:", 10000); // 100%
        console2.log("  Liquidation Threshold:", 9500); // 95%

        marketAddress = factory.deployMarket{value: deploymentFee}(
            owner,              // borrower
            usdc,              // borrowAsset
            weth,              // collateralAsset
            chainlinkEthUsd,   // collateralOracle
            18,                // collateralDecimals (WETH)
            6,                 // borrowDecimals (USDC)
            10000,             // minCollateralRatio (100%)
            9500               // liquidationThreshold (95%)
        );
        console2.log("Market deployed at:", marketAddress);

        vm.stopBroadcast();

        // Log deployment summary
        console2.log("");
        console2.log("========== DEPLOYMENT SUMMARY ==========");
        console2.log("ArchController:", address(archController));
        console2.log("Factory:", address(factory));
        console2.log("Market:", marketAddress);
        console2.log("");
        console2.log("To verify contracts:");
        console2.log("forge verify-contract", address(archController), "src/RevvFiArchController.sol:RevvFiArchController");
        console2.log("forge verify-contract", address(factory), "src/RevvFiFactory.sol:RevvFiFactory");
        console2.log("forge verify-contract", marketAddress, "src/RevvFiMarket.sol:RevvFiMarket");
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Transfer ownership of ArchController to a multisig");
        console2.log("2. Register additional borrowers with archController.registerBorrower()");
        console2.log("3. Lenders can submit offers via market.submitOffer()");
        console2.log("4. Borrower can deposit collateral and borrow funds");
    }
}