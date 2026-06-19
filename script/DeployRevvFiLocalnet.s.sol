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
 *   - Whitelisted by the admin
 *   - Calls factory.deployMarket() and pays the deployment fee themselves
 *   - The market is permanently bound to their address
 *   - Only they can borrow, repay, and manage collateral
 *
 * Note: For localnet convenience, if BORROWER_PRIVATE_KEY is not set, the
 * deployer key is used as a fallback to sign the borrower's deployMarket()
 * transaction.  This is acceptable locally because Anvil accounts share the
 * same node and the factory still binds the market to the BORROWER address.
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
        console.log("  USDC   :", address(usdc));
        console.log("  WETH   :", address(weth));
        console.log("  Oracle :", address(oracle));
        console.log("  Price  : $2,000 (mock, call oracle.setPrice() to change)");

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

        // Step 7 — Mint test tokens to all relevant accounts
        console.log("\n[ADMIN 7/7] Minting test tokens...");
        usdc.mint(deployer, 1_000_000e6); // 1 M USDC  to admin
        weth.mint(deployer, 1_000 ether);
        usdc.mint(borrower, 100_000e6); // 100 K USDC to borrower
        weth.mint(borrower, 100 ether);
        console.log("  Deployer: 1,000,000 USDC + 1,000 WETH");
        console.log("  Borrower: 100,000 USDC + 100 WETH");

        vm.stopBroadcast();

        // =====================================================================
        // PHASE 2 — BORROWER: deploy their own market and pay the deployment fee
        //
        // factory.deployMarket() has no onlyOwner or msg.sender check — it only
        // validates that the `borrower` PARAMETER is a registered address.
        // The market is permanently bound to `borrower` regardless of who signs.
        //
        // On localnet: borrowerKey falls back to deployerKey if not set in env,
        // which is fine for local development.
        // =====================================================================

        console.log("\n--- Phase 2: Borrower deploys market ---");

        vm.startBroadcast(borrowerKey);

        // The borrower calls deployMarket and pays the deployment fee.
        // The fee is sent to `feeRecipient` (the deployer/admin in this setup).
        // On localnet the ETH stays within the same Anvil node, so the deployer
        // effectively pays themselves — net cost is just gas.
        console.log("\n[BORROWER 1/1] Deploying WETH/USDC market...");
        address marketAddr = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, // market bound to this address — only they can borrow
            address(usdc), // borrow asset  : mock USDC (6 dec)
            address(weth), // collateral    : mock WETH (18 dec)
            address(oracle), // mock ETH/USD oracle (initial price: $2,000)
            18, // collateral decimals
            6, // borrow asset decimals
            MIN_COLLATERAL_RATIO,
            LIQUIDATION_THRESHOLD
        );
        console.log("  Market deployed:", marketAddr);
        console.log("  Market borrower:", borrower);

        vm.stopBroadcast();

        _printSummary(deployer, borrower, marketAddr);
    }

    function _printSummary(address deployer, address borrower, address marketAddr) internal view {
        console.log("\n==================================================");
        console.log("          LOCALNET DEPLOYMENT SUMMARY");
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
        console.log("\n--- Mock Contracts ---");
        console.log("  USDC  :", address(usdc));
        console.log("  WETH  :", address(weth));
        console.log("  Oracle:", address(oracle));
        console.log("  (call oracle.setPrice(newPrice) to simulate price changes)");
        console.log("\n--- Implementations ---");
        console.log("  Market        :", marketImpl);
        console.log("  Escrow        :", escrowImpl);
        console.log("  OfferBook     :", offerBookImpl);
        console.log("  LiquidityQueue:", liquidityQueueImpl);
        console.log("\n--- Roles ---");
        console.log("  Admin (deployer):", deployer);
        console.log("  Borrower        :", borrower);
        console.log("\n--- Parameters ---");
        console.log("  Deployment Fee       : 0.1 ETH");
        console.log("  Min Collateral Ratio : 110%");
        console.log("  Liquidation Threshold: 95%");
        console.log("  Initial ETH Price    : $2,000 (mock)");
        console.log("\n--- Test Token Balances ---");
        console.log("  Deployer: 1,000,000 USDC + 1,000 WETH");
        console.log("  Borrower: 100,000 USDC + 100 WETH");
        console.log("\nNote: No Etherscan verification needed for localnet.");
        console.log("==================================================");
    }
}
