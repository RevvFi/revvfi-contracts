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
 *   - Does NOT whitelist any borrower and does NOT deploy any market — both
 *     happen later, live, through the frontend:
 *       1. Any wallet submits a borrower access request (or the admin
 *          registers one directly) from the app's Admin panel.
 *       2. The registered borrower deploys their own market from the
 *          Create Market page, paying the deployment fee themselves.
 *
 * Borrower (BORROWER in .env)
 *   - Only used by this script to mint mock test tokens to (Step 7) so the
 *     address has something to test with once registered via the frontend.
 *     Not registered as a borrower and does not sign anything here.
 *
 * TOKENS
 * ------
 * Approved borrow assets  : Standard ERC20, no fees, no hooks (USDC, DAI, USDT)
 * Approved collateral     : Standard ERC20, fixed supply           (WETH, WBTC)
 * By default deploys freely-mintable mock USDC/WETH. Set USDC_ADDRESS/WETH_ADDRESS
 * in .env to reuse existing Sepolia test tokens instead (no minting is attempted
 * for a reused token — fund the deployer/borrower accounts manually in that case).
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

    // ─── Deployed contract state ──────────────────────────────────────────────
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    address public usdc;
    address public weth;
    bool public usdcIsMock;
    bool public wethIsMock;

    address marketImpl;
    address escrowImpl;
    address offerBookImpl;
    address liquidityQueueImpl;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        // Only used to mint mock test tokens to (Step 7) — this script never
        // signs anything as the borrower, so no private key is needed for it.
        address borrower = vm.envAddress("BORROWER");

        // Oracle: override via env or default to Chainlink Sepolia ETH/USD
        address oracle = vm.envOr("ORACLE_ETH_USD", CHAINLINK_ETH_USD_SEPOLIA);

        // Tokens: override via env, or default to deploying freely-mintable mocks
        address usdcOverride = vm.envOr("USDC_ADDRESS", address(0));
        address wethOverride = vm.envOr("WETH_ADDRESS", address(0));
        usdcIsMock = usdcOverride == address(0);
        wethIsMock = wethOverride == address(0);

        console.log("\n=== RevvFi Testnet (Sepolia) Deployment ===");
        console.log("Admin (deployer) :", deployer);
        console.log("Borrower         :", borrower);
        console.log("Oracle           :", oracle);

        // =====================================================================
        // ADMIN: deploy protocol infrastructure
        // Signer: deployer (protocol admin)
        // =====================================================================

        vm.startBroadcast(deployerKey);

        // Step 1 — Tokens (reuse existing, or deploy mocks)
        console.log("\n[ADMIN 1/7] Setting up USDC and WETH...");
        if (usdcIsMock) {
            usdc = address(new MockERC20("USD Coin", "USDC", 6));
            console.log("  USDC  (mock)    :", usdc);
        } else {
            usdc = usdcOverride;
            console.log("  USDC  (existing):", usdc);
        }
        if (wethIsMock) {
            weth = address(new MockERC20("Wrapped Ether", "WETH", 18));
            console.log("  WETH  (mock)    :", weth);
        } else {
            weth = wethOverride;
            console.log("  WETH  (existing):", weth);
        }
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

        // Step 4 — ArchController
        // No borrower is whitelisted here — that happens later through the
        // frontend (borrower access request + admin approval, or a direct
        // admin registration), so the whole registration flow can be
        // exercised live instead of pre-seeded by this script.
        console.log("\n[ADMIN 4/7] Deploying ArchController...");
        archController = new RevvFiArchController();
        console.log("  ArchController:", address(archController));

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

        // Step 7 — Mint test tokens (mocks only)
        console.log("\n[ADMIN 7/7] Minting test tokens...");
        if (usdcIsMock) {
            MockERC20(usdc).mint(deployer, 500_000e6);
            MockERC20(usdc).mint(borrower, 100_000e6);
            console.log("  Deployer: +500,000 USDC");
            console.log("  Borrower: +100,000 USDC");
        } else {
            console.log("  Skipped USDC mint (using existing token) - fund accounts manually.");
        }
        if (wethIsMock) {
            MockERC20(weth).mint(deployer, 500 ether);
            MockERC20(weth).mint(borrower, 100 ether);
            console.log("  Deployer: +500 WETH");
            console.log("  Borrower: +100 WETH");
        } else {
            console.log("  Skipped WETH mint (using existing token) - fund accounts manually.");
        }

        vm.stopBroadcast();

        // Borrower registration and market deployment happen later, live,
        // through the frontend — not here. See the class doc-comment above.

        _printSummary(deployer, borrower, oracle);
    }

    function _printSummary(address deployer, address borrower, address oracle) internal view {
        console.log("\n==================================================");
        console.log("      TESTNET (SEPOLIA) DEPLOYMENT SUMMARY");
        console.log("==================================================");
        console.log("\n--- Protocol Contracts (deployed by admin) ---");
        console.log("  ArchController    :", address(archController));
        console.log("  Factory           :", address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));
        console.log("\n--- Next steps (do these from the frontend) ---");
        console.log("  1. Connect a wallet and submit/approve a borrower access request in Admin.");
        console.log("  2. Deploy a market as that borrower from the Create Market page.");
        console.log("\n--- Tokens ---");
        console.log("  USDC  :", usdc);
        console.log("  USDC is mock:", usdcIsMock);
        console.log("  WETH  :", weth);
        console.log("  WETH is mock:", wethIsMock);
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
