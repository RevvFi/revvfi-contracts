// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiArchController {
    // Borrower management
    function isRegisteredBorrower(address borrower) external view returns (bool);
    function registerBorrower(address borrower) external;
    function removeBorrower(address borrower) external;
    function getRegisteredBorrowers() external view returns (address[] memory);
    function getRegisteredBorrowersCount() external view returns (uint256);

    // Market management
    function isRegisteredMarket(address market) external view returns (bool);
    function registerMarket(address market) external;
    function removeMarket(address market) external;
    function getRegisteredMarkets() external view returns (address[] memory);
    function getRegisteredMarketsCount() external view returns (uint256);

    // Controller management
    function isRegisteredController(address controller) external view returns (bool);
    function registerController(address controller) external;
    function removeController(address controller) external;
    function getRegisteredControllers() external view returns (address[] memory);
    function getRegisteredControllersCount() external view returns (uint256);

    // Controller Factory management
    function isRegisteredControllerFactory(address factory) external view returns (bool);
    function registerControllerFactory(address factory) external;
    function removeControllerFactory(address factory) external;
    function getRegisteredControllerFactories() external view returns (address[] memory);
    function getRegisteredControllerFactoriesCount() external view returns (uint256);

    // Asset Blacklist management
    function isBlacklistedAsset(address asset) external view returns (bool);
    function addBlacklist(address asset) external;
    function removeBlacklist(address asset) external;
    function getBlacklistedAssets() external view returns (address[] memory);
    function getBlacklistedAssetsCount() external view returns (uint256);
}
