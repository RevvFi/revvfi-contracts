// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../src/RevvFiArchController.sol";
import "../../src/libraries/RevvFiErrors.sol";

contract RevvFiArchControllerTest is Test {
    RevvFiArchController public archController;
    address public owner = address(0x1);
    address public borrower = address(0x2);
    address public factory = address(0x3);
    address public controller = address(0x4);
    address public market = address(0x5);
    address public asset = address(0x6);

    function setUp() public {
        vm.prank(owner);
        archController = new RevvFiArchController();
    }

    function test_RegisterBorrower() public {
        vm.prank(owner);
        archController.registerBorrower(borrower);
        assertTrue(archController.isRegisteredBorrower(borrower));
    }

    function test_CannotRegisterZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RevvFiErrors.ZeroAddressNotAllowed.selector);
        archController.registerBorrower(address(0));
    }

    function test_CannotRegisterDuplicateBorrower() public {
        vm.prank(owner);
        archController.registerBorrower(borrower);
        vm.prank(owner);
        vm.expectRevert(RevvFiErrors.BorrowerAlreadyExists.selector);
        archController.registerBorrower(borrower);
    }

    function test_RemoveBorrower() public {
        vm.prank(owner);
        archController.registerBorrower(borrower);
        vm.prank(owner);
        archController.removeBorrower(borrower);
        assertFalse(archController.isRegisteredBorrower(borrower));
    }

    function test_GetRegisteredBorrowers() public {
        vm.prank(owner);
        archController.registerBorrower(borrower);
        address[] memory borrowers = archController.getRegisteredBorrowers();
        assertEq(borrowers.length, 1);
        assertEq(borrowers[0], borrower);
    }

    function test_AddBlacklist() public {
        vm.prank(owner);
        archController.addBlacklist(asset);
        assertTrue(archController.isBlacklistedAsset(asset));
    }

    function test_RemoveBlacklist() public {
        vm.prank(owner);
        archController.addBlacklist(asset);
        vm.prank(owner);
        archController.removeBlacklist(asset);
        assertFalse(archController.isBlacklistedAsset(asset));
    }

    function test_RegisterControllerFactory() public {
        vm.prank(owner);
        archController.registerControllerFactory(factory);
        assertTrue(archController.isRegisteredControllerFactory(factory));
    }

    function test_RegisterController() public {
        vm.prank(owner);
        archController.registerControllerFactory(factory);

        vm.prank(factory);
        archController.registerController(controller);
        assertTrue(archController.isRegisteredController(controller));
    }

    function test_RegisterMarket() public {
        vm.prank(owner);
        archController.registerControllerFactory(factory);

        vm.prank(factory);
        archController.registerController(controller);

        vm.prank(controller);
        archController.registerMarket(market);
        assertTrue(archController.isRegisteredMarket(market));
    }

    function test_GetPaginatedBorrowers() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(owner);
            archController.registerBorrower(address(uint160(i + 100)));
        }

        address[] memory borrowers = archController.getRegisteredBorrowers(2, 6);
        assertEq(borrowers.length, 4);
    }

    function test_GetPaginatedWithInvalidStart() public {
        address[] memory borrowers = archController.getRegisteredBorrowers(100, 200);
        assertEq(borrowers.length, 0);
    }
}
