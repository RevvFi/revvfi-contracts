// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/RevvFiErrors.sol";
import "./libraries/RevvFiEvents.sol";

/**
 * @title RevvFiArchController
 * @author Preet Singh
 * @notice Central registry and permission manager for the entire RevvFi protocol
 * @dev Maintains whitelists for borrowers, markets, controllers, and blacklisted assets
 */
contract RevvFiArchController is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev All registered lending markets (pools)
    EnumerableSet.AddressSet internal _markets;

    /// @dev Factories that can deploy protocol components
    EnumerableSet.AddressSet internal _controllerFactories;

    /// @dev Approved borrowers who can create lending markets
    EnumerableSet.AddressSet internal _borrowers;

    /// @dev Registered controller contracts (factories and other privileged contracts)
    EnumerableSet.AddressSet internal _controllers;

    /// @dev Assets that are prohibited from use in the protocol
    EnumerableSet.AddressSet internal _assetBlacklist;

    constructor() Ownable(msg.sender) {}

    // ============================================================
    //                      Borrower Management
    // ============================================================

    /**
     * @dev Adds a new borrower to the approved list
     * @param borrower Address to register as a borrower
     */
    function registerBorrower(address borrower) external onlyOwner {
        if (borrower == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_borrowers.add(borrower)) revert RevvFiErrors.BorrowerAlreadyExists();
        emit RevvFiEvents.BorrowerAdded(borrower);
    }

    /**
     * @dev Removes a borrower from the approved list
     * @param borrower Address to remove
     */
    function removeBorrower(address borrower) external onlyOwner {
        if (!_borrowers.remove(borrower)) revert RevvFiErrors.BorrowerDoesNotExist();
        emit RevvFiEvents.BorrowerRemoved(borrower);
    }

    /**
     * @dev Checks if an address is a registered borrower
     * @param borrower Address to check
     * @return True if registered, false otherwise
     */
    function isRegisteredBorrower(address borrower) external view returns (bool) {
        return _borrowers.contains(borrower);
    }

    /**
     * @dev Returns all registered borrowers
     * @return Array of borrower addresses
     */
    function getRegisteredBorrowers() external view returns (address[] memory) {
        return _borrowers.values();
    }

    /**
     * @dev Returns a paginated list of registered borrowers
     * @param start Starting index
     * @param end Ending index (exclusive)
     * @return arr Array of borrower addresses in the specified range
     */
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

    /**
     * @dev Returns total number of registered borrowers
     * @return Count of registered borrowers
     */
    function getRegisteredBorrowersCount() external view returns (uint256) {
        return _borrowers.length();
    }

    // ============================================================
    //                   Asset Blacklist Management
    // ============================================================

    /**
     * @dev Adds an asset to the blacklist, preventing its use in the protocol
     * @param asset Address of token to blacklist
     */
    function addBlacklist(address asset) external onlyOwner {
        if (asset == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_assetBlacklist.add(asset)) revert RevvFiErrors.AssetAlreadyBlacklisted();
        emit RevvFiEvents.AssetBlacklisted(asset);
    }

    /**
     * @dev Removes an asset from the blacklist
     * @param asset Address of token to permit
     */
    function removeBlacklist(address asset) external onlyOwner {
        if (!_assetBlacklist.remove(asset)) revert RevvFiErrors.AssetNotBlacklisted();
        emit RevvFiEvents.AssetPermitted(asset);
    }

    /**
     * @dev Checks if an asset is blacklisted
     * @param asset Address to check
     * @return True if blacklisted, false otherwise
     */
    function isBlacklistedAsset(address asset) external view returns (bool) {
        return _assetBlacklist.contains(asset);
    }

    /**
     * @dev Returns all blacklisted assets
     * @return Array of blacklisted token addresses
     */
    function getBlacklistedAssets() external view returns (address[] memory) {
        return _assetBlacklist.values();
    }

    /**
     * @dev Returns paginated list of blacklisted assets
     * @param start Starting index
     * @param end Ending index (exclusive)
     * @return arr Array of token addresses in the specified range
     */
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

    /**
     * @dev Returns total number of blacklisted assets
     * @return Count of blacklisted assets
     */
    function getBlacklistedAssetsCount() external view returns (uint256) {
        return _assetBlacklist.length();
    }

    // ============================================================
    //                 Controller Factory Management
    // ============================================================

    /**
     * @dev Registers a factory that can deploy protocol controllers
     * @param factory Address of factory contract to register
     */
    function registerControllerFactory(address factory) external {
        if (msg.sender != owner() && (msg.sender != factory || _controllerFactories.contains(factory))) {
            revert RevvFiErrors.UnauthorizedCaller();
        }
        if (factory == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_controllerFactories.add(factory)) revert RevvFiErrors.ControllerFactoryAlreadyExists();
        emit RevvFiEvents.ControllerFactoryAdded(factory);
    }

    /**
     * @dev Removes a controller factory from the registry
     * @param factory Address of factory to remove
     */
    function removeControllerFactory(address factory) external onlyOwner {
        if (!_controllerFactories.remove(factory)) revert RevvFiErrors.ControllerFactoryDoesNotExist();
        emit RevvFiEvents.ControllerFactoryRemoved(factory);
    }

    /**
     * @dev Checks if an address is a registered controller factory
     * @param factory Address to check
     * @return True if registered, false otherwise
     */
    function isRegisteredControllerFactory(address factory) external view returns (bool) {
        return _controllerFactories.contains(factory);
    }

    /**
     * @dev Returns all registered controller factories
     * @return Array of factory addresses
     */
    function getRegisteredControllerFactories() external view returns (address[] memory) {
        return _controllerFactories.values();
    }

    /**
     * @dev Returns paginated list of registered controller factories
     * @param start Starting index
     * @param end Ending index (exclusive)
     * @return arr Array of factory addresses in the specified range
     */
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

    /**
     * @dev Returns total number of registered controller factories
     * @return Count of registered factories
     */
    function getRegisteredControllerFactoriesCount() external view returns (uint256) {
        return _controllerFactories.length();
    }

    // ============================================================
    //                    Controller Management
    // ============================================================

    /// @dev Ensures caller is a registered controller factory
    modifier onlyControllerFactory() {
        if (!_controllerFactories.contains(msg.sender)) revert RevvFiErrors.NotControllerFactory();
        _;
    }

    /**
     * @dev Registers a controller contract (only callable by a registered factory)
     * @param controller Address of controller to register
     */
    function registerController(address controller) external onlyControllerFactory {
        if (controller == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_controllers.add(controller)) revert RevvFiErrors.ControllerAlreadyExists();
        emit RevvFiEvents.ControllerAdded(msg.sender, controller);
    }

    /**
     * @dev Removes a controller from the registry
     * @param controller Address of controller to remove
     */
    function removeController(address controller) external onlyOwner {
        if (!_controllers.remove(controller)) revert RevvFiErrors.ControllerDoesNotExist();
        emit RevvFiEvents.ControllerRemoved(controller);
    }

    /**
     * @dev Checks if an address is a registered controller
     * @param controller Address to check
     * @return True if registered, false otherwise
     */
    function isRegisteredController(address controller) external view returns (bool) {
        return _controllers.contains(controller);
    }

    /**
     * @dev Returns all registered controllers
     * @return Array of controller addresses
     */
    function getRegisteredControllers() external view returns (address[] memory) {
        return _controllers.values();
    }

    /**
     * @dev Returns paginated list of registered controllers
     * @param start Starting index
     * @param end Ending index (exclusive)
     * @return arr Array of controller addresses in the specified range
     */
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

    /**
     * @dev Returns total number of registered controllers
     * @return Count of registered controllers
     */
    function getRegisteredControllersCount() external view returns (uint256) {
        return _controllers.length();
    }

    // ============================================================
    //                     Market Management
    // ============================================================

    /// @dev Ensures caller is a registered controller
    modifier onlyController() {
        if (!_controllers.contains(msg.sender)) revert RevvFiErrors.NotController();
        _;
    }

    /**
     * @dev Registers a lending market (only callable by a registered controller)
     * @param market Address of lending market to register
     */
    function registerMarket(address market) external onlyController {
        if (market == address(0)) revert RevvFiErrors.ZeroAddressNotAllowed();
        if (!_markets.add(market)) revert RevvFiErrors.MarketAlreadyExists();
        emit RevvFiEvents.MarketAdded(msg.sender, market);
    }

    /**
     * @dev Removes a lending market from the registry
     * @param market Address of market to remove
     */
    function removeMarket(address market) external onlyOwner {
        if (!_markets.remove(market)) revert RevvFiErrors.MarketDoesNotExist();
        emit RevvFiEvents.MarketRemoved(market);
    }

    /**
     * @dev Checks if a market is registered
     * @param market Address to check
     * @return True if registered, false otherwise
     */
    function isRegisteredMarket(address market) external view returns (bool) {
        return _markets.contains(market);
    }

    /**
     * @dev Returns all registered markets (use paginated version for large lists)
     * @return Array of market addresses
     */
    function getRegisteredMarkets() external view returns (address[] memory) {
        return _markets.values();
    }

    /**
     * @dev Returns paginated list of registered markets
     * @param start Starting index
     * @param end Ending index (exclusive)
     * @return arr Array of market addresses in the specified range
     */
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

    /**
     * @dev Returns total number of registered markets
     * @return Count of registered markets
     */
    function getRegisteredMarketsCount() external view returns (uint256) {
        return _markets.length();
    }
}