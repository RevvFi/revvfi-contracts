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
 * @title DeployLocalnet
 * @notice Deployment script for local Anvil development environment.
 *         Deploys mock tokens and oracle so everything works out-of-the-box.
 *
 * PROTOCOL ROLES
 * --------------
 * Admin (deployer / PRIVATE_KEY)
 *   - Deploys all infrastructure contracts
 *   - Owns Factory and ArchController
 *   - Whitelists the borrower via archController.registerBorrower()
 *   - Does NOT deploy markets — that is the borrower's job
 *
 * Borrower (BORROWER address / BORROWER_PRIVATE_KEY)
 *   - Whitelisted by the admin, ready to call factory.deployMarket() whenever
 *     you want to test that flow yourself
 *
 * Note: This script intentionally does NOT deploy any market - it only
 * deploys infrastructure and funds test accounts, so every market you see in
 * the app was created by you (or a script you ran), not pre-seeded. Deploy
 * one from the frontend's "Create Market" flow, or call
 * factory.deployMarket() directly, whenever you're ready.
 *
 * Usage:
 *   anvil                        # terminal 1 — keep running
 *
 *   source .env.localnet         # terminal 2
 *   forge script script/DeployRevvFiLocalnet.s.sol:DeployLocalnet \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployLocalnet is Script {
    // ─── Protocol parameters ──────────────────────────────────────────────────
    uint256 constant DEPLOYMENT_FEE = 0.1 ether;
    uint256 constant MIN_COLLATERAL_RATIO = 11000; // 110%  (basis points)
    uint256 constant LIQUIDATION_THRESHOLD = 9500; //  95%
    int256 constant INITIAL_ETH_PRICE = 2000e8; // $2,000 @ 8 decimals

    // ─── Deployed contract state ──────────────────────────────────────────────
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;
    MockOracle public oracleUsdcCollateral;

    address marketImpl;
    address escrowImpl;
    address offerBookImpl;
    address liquidityQueueImpl;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address borrower = vm.envAddress("BORROWER");

        // For localnet: fall back to deployer key if borrower key not provided
        uint256 borrowerKey = vm.envOr("BORROWER_PRIVATE_KEY", deployerKey);
        address borrowerSigner = vm.addr(borrowerKey);

        console.log("\n=== RevvFi Localnet Deployment ===");
        console.log("Admin (deployer) :", deployer);
        console.log("Borrower address :", borrower);
        console.log("Borrower signer  :", borrowerSigner);
        if (borrowerKey == deployerKey) {
            console.log("  Note: BORROWER_PRIVATE_KEY not set, deployer signing on borrower's behalf");
        }

        // =====================================================================
        // PHASE 1 — ADMIN: deploy infrastructure and whitelist the borrower
        // Signer: deployer
        // =====================================================================

        vm.startBroadcast(deployerKey);

        // Step 1 — Mock tokens and oracle
        console.log("\n[ADMIN 1/7] Deploying mock tokens and oracle...");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, INITIAL_ETH_PRICE);
        // A single price oracle can only correctly represent ONE "collateral
        // priced in borrow-asset units" direction (RevvFiCollateralEscrow has
        // no separate per-asset USD price - see _getCollateralValueFromAmount).
        // `oracle` above is calibrated as "1 WETH = 2000 (borrow asset units)",
        // correct only when collateral=WETH. This second oracle is the
        // reciprocal ("1 USDC = 0.0005 borrow asset units", price=50000 @ 8
        // decimals), for markets with USDC as collateral instead. Deployed
        // here - not as a one-off manual transaction - so it survives every
        // `make up`/anvil restart instead of silently vanishing.
        oracleUsdcCollateral = new MockOracle(8, 50000);
        console.log("  USDC   :", address(usdc));
        console.log("  WETH   :", address(weth));
        // Label kept exactly as "Oracle :" (not renamed/reformatted) because
        // scripts/deploy.sh greps this exact "^\s*Oracle\s*:" pattern to
        // extract the address - a differently-worded label would silently
        // break that extraction.
        console.log("  Oracle :", address(oracle));
        console.log("  Price  : $2,000 (mock, call oracle.setPrice() to change)");
        console.log("  OracleUsdcCollateral :", address(oracleUsdcCollateral));
        console.log("  Price  : 0.0005 (reciprocal, mock, for USDC-as-collateral markets)");

        // Step 2 — Implementation contracts (EIP-1167 clone templates)
        console.log("\n[ADMIN 2/7] Deploying implementation contracts...");
        marketImpl = address(new RevvFiMarket());
        escrowImpl = address(new RevvFiCollateralEscrow());
        offerBookImpl = address(new RevvFiOfferBook());
        liquidityQueueImpl = address(new RevvFiLiquidityQueue());
        console.log("  MarketImpl        :", marketImpl);
        console.log("  EscrowImpl        :", escrowImpl);
        console.log("  OfferBookImpl     :", offerBookImpl);
        console.log("  LiquidityQueueImpl:", liquidityQueueImpl);

        // Step 3 — Factory (admin-owned, deployer is also fee recipient)
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

        // Step 4 — ArchController: whitelist the borrower
        // Only registered borrower addresses can have a market deployed for them.
        // The admin registers them here; the borrower deploys the market themselves.
        console.log("\n[ADMIN 4/7] Deploying ArchController and whitelisting borrower...");
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);
        console.log("  ArchController      :", address(archController));
        console.log("  Borrower whitelisted:", borrower);

        // Step 5 — Core singleton contracts (shared across all markets)
        console.log("\n[ADMIN 5/7] Deploying core contracts...");
        positionNFT = new RevvFiPositionNFT(address(factory));
        liquidator = new RevvFiLiquidator(address(factory));
        reputationRegistry = new ReputationRegistry(address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));

        // Step 6 — Wire Factory to core contracts
        console.log("\n[ADMIN 6/7] Wiring Factory...");
        factory.setCoreContracts(
            address(archController), address(positionNFT), address(liquidator), address(reputationRegistry)
        );
        factory.registerWithArchController();
        console.log("  Done.");

        // Step 7 — Mint test tokens to every default Anvil account, so
        // whichever one you connect with in MetaMask already has funds to
        // create markets, deposit collateral, or submit offers with -
        // no separate seeding step required.
        console.log("\n[ADMIN 7/7] Minting test tokens to all default Anvil accounts...");
        address[10] memory anvilAccounts = [
            deployer, // index 0
            borrower, // index 1
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, // index 2
            0x90F79bf6EB2c4f870365E785982E1f101E93b906, // index 3
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, // index 4
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, // index 5
            0x976EA74026E726554dB657fA54763abd0C3a0aa9, // index 6
            0x14dC79964da2C08b23698B3D3cc7Ca32193d9955, // index 7
            0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f, // index 8
            0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 // index 9
        ];
        for (uint256 i = 0; i < anvilAccounts.length; i++) {
            usdc.mint(anvilAccounts[i], 100_000e6); // 100,000 USDC
            weth.mint(anvilAccounts[i], 100 ether); // 100 WETH
        }
        console.log("  Every default Anvil account (index 0-9): 100,000 USDC + 100 WETH");

        vm.stopBroadcast();

        // No market is deployed here on purpose - every account above is
        // funded and Borrower is whitelisted, ready for you to call
        // factory.deployMarket() (from the frontend's "Create Market" flow,
        // or directly) with whatever pairing/parameters you want to test.

        _printSummary(deployer, borrower);
    }

    function _printSummary(address deployer, address borrower) internal view {
        console.log("\n==================================================");
        console.log("          LOCALNET DEPLOYMENT SUMMARY");
        console.log("==================================================");
        console.log("\n--- Protocol Contracts (deployed by admin) ---");
        console.log("  ArchController    :", address(archController));
        console.log("  Factory           :", address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));
        console.log("\n--- No market deployed ---");
        console.log("  Deploy one yourself via factory.deployMarket() or the");
        console.log("  frontend's Create Market flow, with whatever borrower/");
        console.log("  asset pairing/parameters you want to test.");
        console.log("\n--- Mock Contracts ---");
        console.log("  USDC  :", address(usdc));
        console.log("  WETH  :", address(weth));
        console.log("  Oracle (WETH collateral):", address(oracle));
        console.log("  Oracle (USDC collateral):", address(oracleUsdcCollateral));
        console.log("  (call oracle.setPrice(newPrice) to simulate price changes)");
        console.log("\n--- Implementations ---");
        console.log("  Market        :", marketImpl);
        console.log("  Escrow        :", escrowImpl);
        console.log("  OfferBook     :", offerBookImpl);
        console.log("  LiquidityQueue:", liquidityQueueImpl);
        console.log("\n--- Roles ---");
        console.log("  Admin (deployer)     :", deployer);
        console.log("  Borrower (whitelisted):", borrower);
        console.log("\n--- Parameters ---");
        console.log("  Deployment Fee       : 0.1 ETH");
        console.log("  Min Collateral Ratio : 110%  (suggested - your call at deployMarket() time)");
        console.log("  Liquidation Threshold: 95%   (suggested - your call at deployMarket() time)");
        console.log("  Initial ETH Price    : $2,000 (mock)");
        console.log("\n--- Test Token Balances ---");
        console.log("  Every default Anvil account (index 0-9): 100,000 USDC + 100 WETH");
        console.log("\nNote: No Etherscan verification needed for localnet.");
        console.log("==================================================");
    }
}
