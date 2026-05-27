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

contract DeployLocal is Script {
    RevvFiArchController public archController;
    RevvFiFactory public factory;
    RevvFiMarket public market;
    RevvFiPositionNFT public positionNFT;
    RevvFiLiquidator public liquidator;
    ReputationRegistry public reputationRegistry;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;

    address public owner;
    address public borrower;
    address public lender1;
    address public lender2;

    uint256 public constant DEPLOYMENT_FEE = 0.1 ether;
    uint256 public constant MIN_COLLATERAL_RATIO = 11000;
    uint256 public constant LIQUIDATION_THRESHOLD = 9500;

    function setUp() public {
        owner = vm.envAddress("OWNER");
        borrower = vm.envAddress("BORROWER");
        lender1 = vm.envAddress("LENDER1");
        lender2 = vm.envAddress("LENDER2");
    }

    function run() public {
        vm.startBroadcast();

        // STEP 1: Deploy mock tokens and oracle
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(8, 2000e8);

        // STEP 2: Deploy implementation contracts (for cloning)
        address marketImpl = address(new RevvFiMarket());
        address escrowImpl = address(new RevvFiCollateralEscrow());
        address offerBookImpl = address(new RevvFiOfferBook());
        address liquidityQueueImpl = address(new RevvFiLiquidityQueue());

        // STEP 3: Deploy Factory (without core contracts)
        factory = new RevvFiFactory(
            owner, // feeRecipient
            DEPLOYMENT_FEE, // deploymentFee
            marketImpl, // marketImpl
            escrowImpl, // escrowImpl
            offerBookImpl, // offerBookImpl
            liquidityQueueImpl // liquidityQueueImpl
        );

        // STEP 4: Deploy ArchController (needs factory for registration later, but not in constructor)
        archController = new RevvFiArchController();
        archController.registerBorrower(borrower);

        // STEP 5: Deploy core contracts with factory address
        positionNFT = new RevvFiPositionNFT(address(factory));
        liquidator = new RevvFiLiquidator(address(factory));
        reputationRegistry = new ReputationRegistry(address(factory));

        // STEP 6: Set core contracts in Factory (onlyOwner)
        factory.setCoreContracts(
            address(archController), address(positionNFT), address(liquidator), address(reputationRegistry)
        );

        // STEP 7: Register factory with ArchController
        factory.registerWithArchController();

        // STEP 8: Deploy Market
        address marketAddress = factory.deployMarket{value: DEPLOYMENT_FEE}(
            borrower, address(usdc), address(weth), address(oracle), 18, 6, MIN_COLLATERAL_RATIO, LIQUIDATION_THRESHOLD
        );
        market = RevvFiMarket(marketAddress);

        vm.stopBroadcast();

        // Deployment Summary
        console.log("\n========================================");
        console.log("     DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log(string(abi.encodePacked("ArchController: ", vm.toString(address(archController)))));
        console.log(string(abi.encodePacked("Factory: ", vm.toString(address(factory)))));
        console.log(string(abi.encodePacked("PositionNFT: ", vm.toString(address(positionNFT)))));
        console.log(string(abi.encodePacked("Liquidator: ", vm.toString(address(liquidator)))));
        console.log(string(abi.encodePacked("ReputationRegistry: ", vm.toString(address(reputationRegistry)))));
        console.log(string(abi.encodePacked("Market: ", vm.toString(marketAddress))));
        console.log("========================================");
    }
}

