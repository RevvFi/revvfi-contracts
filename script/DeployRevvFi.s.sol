// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "../src/RevvFiArchController.sol";
import "../src/RevvFiFactory.sol";
import "../src/RevvFiMarket.sol";
import "../src/RevvFiCollateralEscrow.sol";
import "../src/RevvFiOfferBook.sol";
import "../src/RevvFiLiquidityQueue.sol";
import "../src/RevvFiPositionNFT.sol";
import "../src/RevvFiLiquidator.sol";
import "../src/ReputationRegistry.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockOracle.sol";

/**
 * @title DeployRevvFi
 * @author Preet Singh
 * @notice Main deployment script for RevvFi protocol (production/local)
 * @dev Deploys all RevvFi protocol contracts with mock tokens for testing
 */
contract DeployRevvFi is Script {
    // Core Protocol Contracts
    RevvFiArchController public archController; // Access control and borrower management
    RevvFiFactory public factory; // Factory for deploying markets
    RevvFiMarket public market; // Market contract instance
    RevvFiPositionNFT public positionNFT; // NFT representing lending positions
    RevvFiLiquidator public liquidator; // Handles liquidation auctions
    ReputationRegistry public reputationRegistry; // Tracks borrower reputation

    // Mock External Contracts
    MockERC20 public usdc; // Mock USDC token (6 decimals)
    MockERC20 public weth; // Mock WETH token (18 decimals)
    MockOracle public oracle; // Mock price oracle

    // Implementation Contract Addresses
    address public marketImpl;
    address public escrowImpl;
    address public offerBookImpl;
    address public liquidityQueueImpl;

    // Protocol Configuration Addresses
    address public owner; // Owner address (fee recipient)
    address public borrower; // Borrower address for the market
    address public lender1; // Test lender address 1
    address public lender2; // Test lender address 2

    // Protocol Parameters
    uint256 public constant DEPLOYMENT_FEE = 0.1 ether; // Fee to deploy a new market
    uint256 public constant MIN_COLLATERAL_RATIO = 11000; // 110% minimum collateral ratio (in basis points)
    uint256 public constant LIQUIDATION_THRESHOLD = 9500; // 95% liquidation threshold (in basis points)

    /**
     * @dev Sets up environment variables before deployment
     * @notice Reads addresses from .env file
     */
    function setUp() public {
        owner = vm.envAddress("OWNER");
        borrower = vm.envAddress("BORROWER");
        lender1 = vm.envAddress("LENDER1");
        lender2 = vm.envAddress("LENDER2");
    }

    /**
     * @dev Main deployment function - executes all deployment steps
     */
    function run() public {
        vm.startBroadcast();

        // ============================================================
        // STEP 1: Deploy mock tokens and oracle
        // ============================================================
        console.log("\n[STEP 1] Deploying mock tokens and oracle...");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, 2000e8);
        console.log("Mock USDC deployed");
        console.log("Mock WETH deployed");
        console.log("Mock Oracle deployed");

        // ============================================================
        // STEP 2: Deploy implementation contracts (for cloning)
        // ============================================================
        console.log("\n[STEP 2] Deploying implementation contracts...");
        marketImpl = address(new RevvFiMarket());
        escrowImpl = address(new RevvFiCollateralEscrow());
        offerBookImpl = address(new RevvFiOfferBook());
        liquidityQueueImpl = address(new RevvFiLiquidityQueue());
        console.log("Market implementation deployed");
        console.log("CollateralEscrow implementation deployed");
        console.log("OfferBook implementation deployed");
        console.log("LiquidityQueue implementation deployed");

        // ============================================================
        // STEP 3: Deploy Factory (without core contracts)
        // ============================================================
        console.log("\n[STEP 3] Deploying Factory...");
        factory = new RevvFiFactory(
            owner, // feeRecipient - receives deployment fees
            DEPLOYMENT_FEE, // deploymentFee - fee to deploy new markets
            marketImpl, // marketImpl - reference implementation
            escrowImpl, // escrowImpl - reference implementation
            offerBookImpl, // offerBookImpl - reference implementation
            liquidityQueueImpl // liquidityQueueImpl - reference implementation
        );
        console.log("Factory deployed");

        // ============================================================
        // STEP 4: Deploy ArchController (needs factory for registration later)
        // ============================================================
        console.log("\n[STEP 4] Deploying ArchController...");
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);
        console.log("ArchController deployed");
        console.log("Borrower registered");

        // ============================================================
        // STEP 5: Deploy core contracts with factory address
        // ============================================================
        console.log("\n[STEP 5] Deploying core contracts...");
        positionNFT = new RevvFiPositionNFT(address(factory));
        liquidator = new RevvFiLiquidator(address(factory));
        reputationRegistry = new ReputationRegistry(address(factory));
        console.log("PositionNFT deployed");
        console.log("Liquidator deployed");
        console.log("ReputationRegistry deployed");

        // ============================================================
        // STEP 6: Set core contracts in Factory (onlyOwner)
        // ============================================================
        console.log("\n[STEP 6] Setting core contracts in Factory...");
        factory.setCoreContracts(
            address(archController), // archController - access control
            address(positionNFT), // positionNFT - position NFT contract
            address(liquidator), // liquidator - liquidation handler
            address(reputationRegistry) // reputationRegistry - reputation tracking
        );
        console.log("Core contracts registered with Factory");

        // ============================================================
        // STEP 7: Register factory with ArchController
        // ============================================================
        console.log("\n[STEP 7] Registering Factory with ArchController...");
        factory.registerWithArchController();
        console.log("Factory registered");

        // ============================================================
        // STEP 8: Deploy Market
        // ============================================================
        console.log("\n[STEP 8] Deploying Market...");
        address marketAddress = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, // borrower - authorized borrower address
            address(usdc), // borrowAsset - USDC (borrow asset)
            address(weth), // collateralAsset - WETH (collateral asset)
            address(oracle), // oracle - price oracle
            18, // collateralDecimals - WETH decimals
            6, // borrowDecimals - USDC decimals
            MIN_COLLATERAL_RATIO, // minCollateralRatio - 110%
            LIQUIDATION_THRESHOLD // liquidationThreshold - 95%
        );
        market = RevvFiMarket(marketAddress);
        console.log("Market deployed");

        vm.stopBroadcast();

        // ============================================================
        // DEPLOYMENT SUMMARY
        // ============================================================
        console.log("\n================================================");
        console.log("           DEPLOYMENT SUMMARY");
        console.log("================================================");

        console.log("\n--- Core Protocol Contracts ---");
        console.log(string.concat("  ArchController:       ", vm.toString(address(archController))));
        console.log(string.concat("  Factory:              ", vm.toString(address(factory))));
        console.log(string.concat("  PositionNFT:          ", vm.toString(address(positionNFT))));
        console.log(string.concat("  Liquidator:           ", vm.toString(address(liquidator))));
        console.log(string.concat("  ReputationRegistry:   ", vm.toString(address(reputationRegistry))));
        console.log(string.concat("  Market:               ", vm.toString(marketAddress)));

        console.log("\n--- External Mock Contracts ---");
        console.log(string.concat("  Mock USDC:            ", vm.toString(address(usdc))));
        console.log(string.concat("  Mock WETH:            ", vm.toString(address(weth))));
        console.log(string.concat("  Mock Oracle:          ", vm.toString(address(oracle))));

        console.log("\n--- Implementation Contracts ---");
        console.log(string.concat("  Market Implementation:     ", vm.toString(marketImpl)));
        console.log(string.concat("  Escrow Implementation:     ", vm.toString(escrowImpl)));
        console.log(string.concat("  OfferBook Implementation:  ", vm.toString(offerBookImpl)));
        console.log(string.concat("  LiquidityQueue Implementation: ", vm.toString(liquidityQueueImpl)));

        console.log("\n--- Configuration ---");
        console.log(string.concat("  Owner:                ", vm.toString(owner)));
        console.log(string.concat("  Borrower:             ", vm.toString(borrower)));
        console.log(string.concat("  Lender1:              ", vm.toString(lender1)));
        console.log(string.concat("  Lender2:              ", vm.toString(lender2)));
        console.log(string.concat("  Deployment Fee:       ", vm.toString(DEPLOYMENT_FEE)));
        console.log(string.concat("  Min Collateral Ratio: ", vm.toString(MIN_COLLATERAL_RATIO)));
        console.log(string.concat("  Liquidation Threshold:", vm.toString(LIQUIDATION_THRESHOLD)));
        console.log("================================================");
    }
}
