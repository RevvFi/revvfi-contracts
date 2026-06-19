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
 * @title DeployTestnet
 * @notice Deployment script for Sepolia testnet.
 *
 * PROTOCOL ROLES
 * --------------
 * Admin (deployer)
 *   - Deploys all infrastructure contracts
 *   - Owns Factory and ArchController
 *   - Whitelists borrower addresses via archController.registerBorrower()
 *   - Does NOT deploy markets — that is the borrower's responsibility
 *
 * Borrower (BORROWER in .env)
 *   - A separate wallet that has been whitelisted by the admin
 *   - Calls factory.deployMarket() and pays the deployment fee themselves
 *   - Owns the resulting market (only they can borrow, repay, deposit collateral)
 *
 * This script runs BOTH phases in one broadcast for initial testnet setup
 * convenience.  On mainnet, Step 7 (deployMarket) would be a separate
 * transaction signed by the borrower's own wallet.
 *
 * TOKENS
 * ------
 * Approved borrow assets  : Standard ERC20, no fees, no hooks (USDC, DAI, USDT)
 * Approved collateral     : Standard ERC20, fixed supply           (WETH, WBTC)
 *
 * Usage:
 *   source .env.testnet
 *   forge script script/DeployRevvFi.s.sol:DeployTestnet \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeployTestnet is Script {
    // ─── Chainlink Sepolia ETH/USD (never changes) ────────────────────────────
    address constant CHAINLINK_ETH_USD_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    // ─── Protocol parameters ──────────────────────────────────────────────────
    uint256 constant DEPLOYMENT_FEE = 0.01 ether; // lower fee for testnet
    uint256 constant MIN_COLLATERAL_RATIO = 11000; // 110%
    uint256 constant LIQUIDATION_THRESHOLD = 9500; //  95%

    // ─── Deployed contract state ──────────────────────────────────────────────
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    MockERC20 public usdc;
    MockERC20 public weth;

    address marketImpl;
    address escrowImpl;
    address offerBookImpl;
    address liquidityQueueImpl;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 borrowerKey = vm.envUint("BORROWER_PRIVATE_KEY");
        address borrower = vm.addr(borrowerKey);

        // Oracle: override via env or default to Chainlink Sepolia ETH/USD
        address oracle = vm.envOr("ORACLE_ETH_USD", CHAINLINK_ETH_USD_SEPOLIA);

        console.log("\n=== RevvFi Testnet (Sepolia) Deployment ===");
        console.log("Admin (deployer) :", deployer);
        console.log("Borrower         :", borrower);
        console.log("Oracle           :", oracle);

        // =====================================================================
        // PHASE 1 — ADMIN: deploy infrastructure and whitelist the borrower
        // Signer: deployer (protocol admin)
        // =====================================================================

        vm.startBroadcast(deployerKey);

        // Step 1 — Mock tokens (freely mintable for testnet)
        console.log("\n[ADMIN 1/7] Deploying mock USDC and WETH...");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log("  USDC  :", address(usdc));
        console.log("  WETH  :", address(weth));
        console.log("  Oracle:", oracle);

        // Step 2 — Implementation contracts (used as clone templates by the factory)
        console.log("\n[ADMIN 2/7] Deploying implementation contracts...");
        marketImpl = address(new RevvFiMarket());
        escrowImpl = address(new RevvFiCollateralEscrow());
        offerBookImpl = address(new RevvFiOfferBook());
        liquidityQueueImpl = address(new RevvFiLiquidityQueue());
        console.log("  MarketImpl        :", marketImpl);
        console.log("  EscrowImpl        :", escrowImpl);
        console.log("  OfferBookImpl     :", offerBookImpl);
        console.log("  LiquidityQueueImpl:", liquidityQueueImpl);

        // Step 3 — Factory (owned by admin; deployer is also fee recipient here)
        console.log("\n[ADMIN 3/7] Deploying Factory...");
        factory = new RevvFiFactory(
            deployer, // feeRecipient — receives DEPLOYMENT_FEE per market
            DEPLOYMENT_FEE,
            marketImpl,
            escrowImpl,
            offerBookImpl,
            liquidityQueueImpl
        );
        console.log("  Factory:", address(factory));

        // Step 4 — ArchController + whitelist the borrower
        // The admin registers approved borrowers here.
        // Only registered borrowers can have a market deployed for them.
        console.log("\n[ADMIN 4/7] Deploying ArchController and whitelisting borrower...");
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower); // <-- admin whitelists the borrower
        console.log("  ArchController     :", address(archController));
        console.log("  Borrower whitelisted:", borrower);

        // Step 5 — Core singleton contracts (shared across all markets)
        console.log("\n[ADMIN 5/7] Deploying core contracts...");
        positionNFT = new RevvFiPositionNFT(address(factory));
        liquidator = new RevvFiLiquidator(address(factory));
        reputationRegistry = new ReputationRegistry(address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));

        // Step 6 — Wire everything together
        console.log("\n[ADMIN 6/7] Wiring Factory...");
        factory.setCoreContracts(
            address(archController), address(positionNFT), address(liquidator), address(reputationRegistry)
        );
        factory.registerWithArchController();
        console.log("  Done.");

        // Step 7 — Mint test tokens so the borrower and admin can interact
        console.log("\n[ADMIN 7/7] Minting test tokens...");
        usdc.mint(deployer, 500_000e6);
        weth.mint(deployer, 500 ether);
        usdc.mint(borrower, 100_000e6);
        weth.mint(borrower, 100 ether);
        console.log("  Deployer: 500,000 USDC + 500 WETH");
        console.log("  Borrower: 100,000 USDC + 100 WETH");

        vm.stopBroadcast();

        // =====================================================================
        // PHASE 2 — BORROWER: deploy their own market and pay the deployment fee
        //
        // In production this would be a SEPARATE transaction signed by the
        // borrower's own wallet.  For testnet convenience we reuse the deployer
        // key here, but the factory enforces borrower == BORROWER parameter, so
        // the market is correctly tied to the borrower address regardless of who
        // pays for deployment.
        // =====================================================================

        // If BORROWER_PRIVATE_KEY is not provided, the deployer calls on behalf
        // of the borrower (valid because deployMarket has no msg.sender check).

        console.log("\n--- Phase 2: Borrower deploys market ---");
        if (borrowerKey == deployerKey) {
            console.log("  Note: BORROWER_PRIVATE_KEY not set, deployer is paying");
            console.log("        the deployment fee on borrower's behalf (testnet only).");
        }

        vm.startBroadcast(borrowerKey);

        // The BORROWER calls factory.deployMarket() and pays the deployment fee.
        // factory.deployMarket() has no onlyOwner or msg.sender check — it only
        // verifies that the `borrower` parameter is a registered borrower address.
        // The resulting market is bound to `borrower`; only that address can
        // borrow, repay, and manage collateral.
        console.log("\n[BORROWER 1/1] Deploying WETH/USDC market...");
        address marketAddr = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, // the market is owned by this address, not msg.sender
            address(usdc), // borrow asset
            address(weth), // collateral asset
            oracle,
            18, // WETH decimals
            6, // USDC decimals
            MIN_COLLATERAL_RATIO,
            LIQUIDATION_THRESHOLD
        );
        console.log("  Market deployed:", marketAddr);
        console.log("  Market borrower:", borrower);

        vm.stopBroadcast();

        _printSummary(deployer, borrower, oracle, marketAddr);
    }

    function _printSummary(address deployer, address borrower, address oracle, address marketAddr) internal view {
        console.log("\n==================================================");
        console.log("      TESTNET (SEPOLIA) DEPLOYMENT SUMMARY");
        console.log("==================================================");
        console.log("\n--- Protocol Contracts (deployed by admin) ---");
        console.log("  ArchController    :", address(archController));
        console.log("  Factory           :", address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));
        console.log("\n--- Market (deployed by borrower) ---");
        console.log("  Market (WETH/USDC):", marketAddr);
        console.log("  Borrower          :", borrower);
        console.log("\n--- Mock Tokens ---");
        console.log("  USDC  :", address(usdc));
        console.log("  WETH  :", address(weth));
        console.log("  Oracle:", oracle);
        console.log("\n--- Implementations ---");
        console.log("  Market        :", marketImpl);
        console.log("  Escrow        :", escrowImpl);
        console.log("  OfferBook     :", offerBookImpl);
        console.log("  LiquidityQueue:", liquidityQueueImpl);
        console.log("\n--- Roles ---");
        console.log("  Admin (deployer):", deployer);
        console.log("  Borrower        :", borrower);
        console.log("\n--- Approved Token Types ---");
        console.log("  Borrow assets : Standard ERC20, no fees (USDC, DAI, USDT)");
        console.log("  Collateral    : Standard ERC20, fixed supply (WETH, WBTC)");
        console.log("\n--- Verification Commands (run after broadcast) ---");
        console.log(
            "  forge verify-contract <MARKET_IMPL>    RevvFiMarket           --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <ESCROW_IMPL>    RevvFiCollateralEscrow --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <OFFERBOOK_IMPL> RevvFiOfferBook        --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <LQ_IMPL>        RevvFiLiquidityQueue   --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <ARCH_CTRL>      RevvFiArchController   --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch"
        );
        console.log("==================================================");
    }
}
