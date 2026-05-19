// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

contract RevvFiArchController is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet internal _markets;
    EnumerableSet.AddressSet internal _controllerFactories;
    EnumerableSet.AddressSet internal _borrowers;
    EnumerableSet.AddressSet internal _controllers;
    EnumerableSet.AddressSet internal _assetBlacklist;

    constructor() Ownable(msg.sender) {}

    // ========================================================================== //
    //                                  Borrowers                                 //
    // ========================================================================== //

    function registerBorrower(address borrower) external onlyOwner {
        if (borrower == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_borrowers.add(borrower)) revert RevvFiErrors.BorrowerAlreadyExists();
        emit RevvFiEvents.BorrowerAdded(borrower);
    }

    function removeBorrower(address borrower) external onlyOwner {
        if (!_borrowers.remove(borrower)) revert RevvFiErrors.BorrowerDoesNotExist();
        emit RevvFiEvents.BorrowerRemoved(borrower);
    }

    function isRegisteredBorrower(address borrower) external view returns (bool) {
        return _borrowers.contains(borrower);
    }

    function getRegisteredBorrowers() external view returns (address[] memory) {
        return _borrowers.values();
    }

    function getRegisteredBorrowers(uint256 start, uint256 end) external view returns (address[] memory arr) {
        uint256 len = _borrowers.length();
        if (start >= end || start >= len) {
            return new address[](0);
        }
        end = end > len ? len : end;
        uint256 count = end - start;
        arr = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = _borrowers.at(start + i);
        }
    }

    function getRegisteredBorrowersCount() external view returns (uint256) {
        return _borrowers.length();
    }

    // ========================================================================== //
    //                          Asset Blacklist Registry                          //
    // ========================================================================== //

    function addBlacklist(address asset) external onlyOwner {
        if (asset == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_assetBlacklist.add(asset)) revert RevvFiErrors.AssetAlreadyBlacklisted();
        emit RevvFiEvents.AssetBlacklisted(asset);
    }

    function removeBlacklist(address asset) external onlyOwner {
        if (!_assetBlacklist.remove(asset)) revert RevvFiErrors.AssetNotBlacklisted();
        emit RevvFiEvents.AssetPermitted(asset);
    }

    function isBlacklistedAsset(address asset) external view returns (bool) {
        return _assetBlacklist.contains(asset);
    }

    function getBlacklistedAssets() external view returns (address[] memory) {
        return _assetBlacklist.values();
    }

    function getBlacklistedAssets(uint256 start, uint256 end) external view returns (address[] memory arr) {
        uint256 len = _assetBlacklist.length();
        if (start >= end || start >= len) {
            return new address[](0);
        }
        end = end > len ? len : end;
        uint256 count = end - start;
        arr = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = _assetBlacklist.at(start + i);
        }
    }

    function getBlacklistedAssetsCount() external view returns (uint256) {
        return _assetBlacklist.length();
    }

    // ========================================================================== //
    //                            Controller Factories                            //
    // ========================================================================== //

    function registerControllerFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_controllerFactories.add(factory)) revert RevvFiErrors.ControllerFactoryAlreadyExists();
        emit RevvFiEvents.ControllerFactoryAdded(factory);
    }

    function removeControllerFactory(address factory) external onlyOwner {
        if (!_controllerFactories.remove(factory)) revert RevvFiErrors.ControllerFactoryDoesNotExist();
        emit RevvFiEvents.ControllerFactoryRemoved(factory);
    }

    function isRegisteredControllerFactory(address factory) external view returns (bool) {
        return _controllerFactories.contains(factory);
    }

    function getRegisteredControllerFactories() external view returns (address[] memory) {
        return _controllerFactories.values();
    }

    function getRegisteredControllerFactories(uint256 start, uint256 end) external view returns (address[] memory arr) {
        uint256 len = _controllerFactories.length();
        if (start >= end || start >= len) {
            return new address[](0);
        }
        end = end > len ? len : end;
        uint256 count = end - start;
        arr = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = _controllerFactories.at(start + i);
        }
    }

    function getRegisteredControllerFactoriesCount() external view returns (uint256) {
        return _controllerFactories.length();
    }

    // ========================================================================== //
    //                                 Controllers                                //
    // ========================================================================== //

    modifier onlyControllerFactory() {
        if (!_controllerFactories.contains(msg.sender)) revert RevvFiErrors.NotControllerFactory();
        _;
    }

    function registerController(address controller) external onlyControllerFactory {
        if (controller == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_controllers.add(controller)) revert RevvFiErrors.ControllerAlreadyExists();
        emit RevvFiEvents.ControllerAdded(msg.sender, controller);
    }

    function removeController(address controller) external onlyOwner {
        if (!_controllers.remove(controller)) revert RevvFiErrors.ControllerDoesNotExist();
        emit RevvFiEvents.ControllerRemoved(controller);
    }

    function isRegisteredController(address controller) external view returns (bool) {
        return _controllers.contains(controller);
    }

    function getRegisteredControllers() external view returns (address[] memory) {
        return _controllers.values();
    }

    function getRegisteredControllers(uint256 start, uint256 end) external view returns (address[] memory arr) {
        uint256 len = _controllers.length();
        if (start >= end || start >= len) {
            return new address[](0);
        }
        end = end > len ? len : end;
        uint256 count = end - start;
        arr = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = _controllers.at(start + i);
        }
    }

    function getRegisteredControllersCount() external view returns (uint256) {
        return _controllers.length();
    }

    // ========================================================================== //
    //                                   Markets                                  //
    // ========================================================================== //

    modifier onlyController() {
        if (!_controllers.contains(msg.sender)) revert RevvFiErrors.NotController();
        _;
    }

    function registerMarket(address market) external onlyController {
        if (market == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_markets.add(market)) revert RevvFiErrors.MarketAlreadyExists();
        emit RevvFiEvents.MarketAdded(msg.sender, market);
    }

    function removeMarket(address market) external onlyOwner {
        if (!_markets.remove(market)) revert RevvFiErrors.MarketDoesNotExist();
        emit RevvFiEvents.MarketRemoved(market);
    }

    function isRegisteredMarket(address market) external view returns (bool) {
        return _markets.contains(market);
    }

    function getRegisteredMarkets() external view returns (address[] memory) {
        return _markets.values();
    }

    function getRegisteredMarkets(uint256 start, uint256 end) external view returns (address[] memory arr) {
        uint256 len = _markets.length();
        if (start >= end || start >= len) {
            return new address[](0);
        }
        end = end > len ? len : end;
        uint256 count = end - start;
        arr = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            arr[i] = _markets.at(start + i);
        }
    }

    function getRegisteredMarketsCount() external view returns (uint256) {
        return _markets.length();
    }
}
