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

/**
 * @title DeployMainnet
 * @notice Production deployment script for Polygon mainnet (chain ID 137).
 *
 * PROTOCOL ROLES
 * --------------
 * Admin (deployer)
 *   - Deploys all infrastructure contracts
 *   - Owns Factory and ArchController
 *   - Whitelists borrower addresses via archController.registerBorrower()
 *   - Applies the token safety blacklist
 *   - Does NOT deploy markets — that is the borrower's responsibility
 *
 * Borrower (BORROWER in .env.mainnet)
 *   - Separate wallet whitelisted by the admin
 *   - Calls factory.deployMarket() and pays the deployment fee themselves
 *   - The resulting market is permanently bound to their address
 *   - Only they can borrow, repay, deposit/withdraw collateral
 *
 * APPROVED TOKEN TYPES (verified safe with this protocol)
 * -------------------------------------------------------
 * Borrow assets  : Standard ERC20, no fees, no hooks
 *   - USDC (native)  0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359   6 dec
 *   - USDT           0xc2132D05D31c914a87C6611C10748AEb04B58e8F   6 dec
 *   - DAI            0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063  18 dec
 *
 * Collateral     : Standard ERC20, fixed supply, no rebase
 *   - WETH           0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619  18 dec
 *   - WBTC           0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6   8 dec
 *   - WPOL/WMATIC    0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270  18 dec
 *
 * BLACKLISTED (unsafe — see _applyBlacklist)
 * -------------------------------------------
 *   - USDC.e    0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174  deprecated by Circle Apr 2026
 *   - MaticX    0xfa68FB4628DFF1028CFEc22b4162FCcd0d45efb6  yield-bearing / rebasing (Stader)
 *   - stMATIC   verify address on Polygonscan before blacklisting (Lido, rebasing)
 *
 * CHAINLINK ORACLES (Polygon mainnet, 8 decimals each)
 * -----------------------------------------------------
 *   ETH/USD     0xF9680D99D6C9589e2a93a78A04A279e509205945
 *   BTC/USD     0xc907E116054Ad103354f2D350FD2514433D57F6f
 *   MATIC/USD   0xAB594600376Ec9fD91F8e885dADF0CE036862dE0
 *   DAI/USD     0x4746DeC9e833A82EC7C2C1356372CcF2cfcD2F3D
 *   USDC/USD    0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7
 *   USDT/USD    0x0A6513e40db6EB1b165753AD52E80663aeA50545
 *
 * Usage:
 *   source .env.mainnet
 *
 *   # Dry-run first (no --broadcast) — always do this before spending real MATIC
 *   forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $POLYGON_RPC_URL \
 *     -vvvv
 *
 *   # Live broadcast + auto-verify on Polygonscan
 *   forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $POLYGON_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $POLYGONSCAN_API_KEY \
 *     -vvvv
 */
contract DeployMainnet is Script {
    // ─── Polygon mainnet token addresses (verified via Polygonscan) ───────────

    // Native USDC — Circle-issued directly on Polygon PoS (recommended)
    // USDC.e (bridged, deprecated Apr 2026) is blacklisted below.
    address constant DEFAULT_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // Bridged WETH from Ethereum
    address constant DEFAULT_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    // Chainlink ETH/USD on Polygon mainnet (8 decimals, ~1 hr heartbeat)
    address constant DEFAULT_ORACLE_ETH_USD = 0xF9680D99D6C9589e2a93a78A04A279e509205945;

    // ─── Protocol parameters ──────────────────────────────────────────────────
    uint256 constant DEPLOYMENT_FEE = 0.1 ether; // 0.1 MATIC per market
    uint256 constant MIN_COLLATERAL_RATIO = 11000; // 110%
    uint256 constant LIQUIDATION_THRESHOLD = 9500; //  95%

    // ─── Deployed contract state ──────────────────────────────────────────────
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    address marketImpl;
    address escrowImpl;
    address offerBookImpl;
    address liquidityQueueImpl;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address borrower = vm.envAddress("BORROWER");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        // Token addresses — read from .env.mainnet, fall back to Polygon defaults
        address usdc = vm.envOr("USDC_ADDRESS", DEFAULT_USDC);
        address weth = vm.envOr("WETH_ADDRESS", DEFAULT_WETH);
        address oracle = vm.envOr("ORACLE_ETH_USD", DEFAULT_ORACLE_ETH_USD);

        // ── Pre-flight safety checks ──────────────────────────────────────────
        require(deployer != address(0), "DeployMainnet: deployer is zero");
        require(borrower != address(0), "DeployMainnet: borrower is zero");
        require(feeRecipient != address(0), "DeployMainnet: feeRecipient is zero");
        require(usdc != address(0), "DeployMainnet: USDC is zero");
        require(weth != address(0), "DeployMainnet: WETH is zero");
        require(oracle != address(0), "DeployMainnet: oracle is zero");
        require(usdc != weth, "DeployMainnet: borrow == collateral");

        console.log("\n=== RevvFi Mainnet (Polygon) Deployment ===");
        console.log("Network      : Polygon mainnet (chain 137)");
        console.log("Admin        :", deployer);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Borrower     :", borrower);
        console.log("USDC         :", usdc);
        console.log("WETH         :", weth);
        console.log("Oracle       :", oracle);

        // =====================================================================
        // PHASE 1 — ADMIN: deploy infrastructure + whitelist borrower
        // Signer: deployer (protocol admin)
        // =====================================================================

        vm.startBroadcast(deployerKey);

        // Step 1 — Implementation contracts (EIP-1167 clone templates)
        console.log("\n[ADMIN 1/7] Deploying implementation contracts...");
        marketImpl = address(new RevvFiMarket());
        escrowImpl = address(new RevvFiCollateralEscrow());
        offerBookImpl = address(new RevvFiOfferBook());
        liquidityQueueImpl = address(new RevvFiLiquidityQueue());
        console.log("  MarketImpl        :", marketImpl);
        console.log("  EscrowImpl        :", escrowImpl);
        console.log("  OfferBookImpl     :", offerBookImpl);
        console.log("  LiquidityQueueImpl:", liquidityQueueImpl);

        // Step 2 — Factory
        console.log("\n[ADMIN 2/7] Deploying Factory...");
        factory =
            new RevvFiFactory(feeRecipient, DEPLOYMENT_FEE, marketImpl, escrowImpl, offerBookImpl, liquidityQueueImpl);
        console.log("  Factory:", address(factory));

        // Step 3 — ArchController: whitelist the borrower and apply token blacklist
        // The admin registers approved borrowers here.
        // Only registered borrower addresses can have a market deployed for them.
        console.log("\n[ADMIN 3/7] Deploying ArchController, whitelisting borrower, applying token blacklist...");
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);
        console.log("  ArchController      :", address(archController));
        console.log("  Borrower whitelisted:", borrower);

        _applyBlacklist();

        // Step 4 — Core singleton contracts (shared across all markets)
        console.log("\n[ADMIN 4/7] Deploying core contracts...");
        positionNFT = new RevvFiPositionNFT(address(factory));
        liquidator = new RevvFiLiquidator(address(factory));
        reputationRegistry = new ReputationRegistry(address(factory));
        console.log("  PositionNFT       :", address(positionNFT));
        console.log("  Liquidator        :", address(liquidator));
        console.log("  ReputationRegistry:", address(reputationRegistry));

        // Step 5 — Wire Factory to core contracts
        console.log("\n[ADMIN 5/7] Wiring Factory...");
        factory.setCoreContracts(
            address(archController), address(positionNFT), address(liquidator), address(reputationRegistry)
        );

        // Step 6 — Register Factory with ArchController
        console.log("\n[ADMIN 6/7] Registering Factory with ArchController...");
        factory.registerWithArchController();

        // Step 7 — Sanity check: confirm ownership
        console.log("\n[ADMIN 7/7] Confirming ownership...");
        require(archController.owner() == deployer, "DeployMainnet: wrong ArchController owner");
        require(factory.owner() == deployer, "DeployMainnet: wrong Factory owner");
        console.log("  ArchController owner:", archController.owner());
        console.log("  Factory owner       :", factory.owner());

        vm.stopBroadcast();

        // =====================================================================
        // PHASE 2 — BORROWER: deploy their own market and pay the deployment fee
        //
        // factory.deployMarket() has no onlyOwner / msg.sender restriction — it
        // only checks that the `borrower` PARAMETER is a registered address.
        // The market is permanently bound to `borrower` regardless of who signs
        // this transaction.
        //
        // In production: the borrower signs this with their own wallet.
        // BORROWER_PRIVATE_KEY must be set in .env.mainnet for this to work.
        // =====================================================================

        uint256 borrowerKey = vm.envUint("BORROWER_PRIVATE_KEY");
        address borrowerSigner = vm.addr(borrowerKey);

        require(borrowerSigner == borrower, "DeployMainnet: BORROWER_PRIVATE_KEY does not match BORROWER address");

        console.log("\n--- Phase 2: Borrower deploys market ---");
        console.log("  Borrower signer:", borrowerSigner);

        vm.startBroadcast(borrowerKey);

        console.log("\n[BORROWER 1/1] Deploying WETH/USDC market...");
        address marketAddr = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, // market bound to this address — only they can borrow/repay
            usdc, // borrow asset  : native USDC (6 dec)
            weth, // collateral    : WETH (18 dec)
            oracle, // Chainlink ETH/USD (8 dec)
            18, // collateral decimals
            6, // borrow asset decimals
            MIN_COLLATERAL_RATIO,
            LIQUIDATION_THRESHOLD
        );
        console.log("  Market deployed:", marketAddr);
        console.log("  Market borrower:", borrower);

        vm.stopBroadcast();

        _printSummary(deployer, feeRecipient, borrower, usdc, weth, oracle, marketAddr);
    }

    // ─── Token safety blacklist ───────────────────────────────────────────────
    // Prevents anyone from accidentally deploying a market with an unsafe token.
    // These tokens are incompatible because:
    //   - Rebasing tokens: collateral balance changes without a transfer, so the
    //     protocol's per-borrower accounting goes stale silently.
    //   - Fee-on-transfer: the contract receives less than `amount`, creating an
    //     ever-growing accounting shortfall that eventually causes insolvency.
    function _applyBlacklist() internal {
        // USDC.e — deprecated by Circle (April 2026). Liquidity migrating to
        // native USDC. New markets must not build on a sunset asset.
        archController.addBlacklist(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

        // MaticX (Stader) — yield-bearing / rebasing-equivalent on Polygon.
        // Balance increases with staking rewards outside of transfers, corrupting
        // the protocol's per-borrower collateral accounting.
        archController.addBlacklist(0xfa68FB4628DFF1028CFEc22b4162FCcd0d45efb6);

        // stMATIC (Lido) — rebasing, same issue as MaticX.
        // TODO: verify the exact Polygon address on https://polygonscan.com before
        // uncommenting. Search "stMATIC" on Polygonscan and confirm the contract.
        // archController.addBlacklist(<STMATIC_ADDRESS>);

        console.log("  Blacklisted: USDC.e, MaticX");
        console.log("  TODO: add stMATIC once address is verified on Polygonscan");
    }

    function _printSummary(
        address deployer,
        address feeRecipient,
        address borrower,
        address usdc,
        address weth,
        address oracle,
        address marketAddr
    ) internal view {
        console.log("\n==================================================");
        console.log("     MAINNET (POLYGON) DEPLOYMENT SUMMARY");
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
        console.log("\n--- External Contracts (Polygon mainnet) ---");
        console.log("  USDC (native) :", usdc);
        console.log("  WETH          :", weth);
        console.log("  Oracle ETH/USD:", oracle);
        console.log("\n--- Implementations ---");
        console.log("  Market        :", marketImpl);
        console.log("  Escrow        :", escrowImpl);
        console.log("  OfferBook     :", offerBookImpl);
        console.log("  LiquidityQueue:", liquidityQueueImpl);
        console.log("\n--- Roles ---");
        console.log("  Admin (deployer) :", deployer);
        console.log("  Fee Recipient    :", feeRecipient);
        console.log("  Borrower         :", borrower);
        console.log("\n--- Token Safety ---");
        console.log("  Approved borrow : USDC (native), USDT, DAI");
        console.log("  Approved collat : WETH, WBTC, WPOL/WMATIC");
        console.log("  Blacklisted     : USDC.e (deprecated), MaticX (rebase) | stMATIC: verify address first");
        console.log("\n--- Polygonscan Verification Commands ---");
        console.log("  # These run automatically if --verify was passed to forge script.");
        console.log("  # Run manually if any contract was missed:");
        console.log(
            "  forge verify-contract <MARKET_IMPL>    RevvFiMarket           --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <ESCROW_IMPL>    RevvFiCollateralEscrow --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <OFFERBOOK_IMPL> RevvFiOfferBook        --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <LQ_IMPL>        RevvFiLiquidityQueue   --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <ARCH_CTRL>      RevvFiArchController   --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --watch"
        );
        console.log(
            "  forge verify-contract <POSITION_NFT>   RevvFiPositionNFT      --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --constructor-args $(cast abi-encode 'constructor(address)' <FACTORY>) --watch"
        );
        console.log(
            "  forge verify-contract <LIQUIDATOR>     RevvFiLiquidator       --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --constructor-args $(cast abi-encode 'constructor(address)' <FACTORY>) --watch"
        );
        console.log(
            "  forge verify-contract <REP_REG>        ReputationRegistry     --chain polygon --etherscan-api-key $POLYGONSCAN_API_KEY --constructor-args $(cast abi-encode 'constructor(address)' <FACTORY>) --watch"
        );
        console.log("==================================================");
    }
}
