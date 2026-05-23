// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IRevvFiArchController {
    function isRegisteredBorrower(address borrower) external view returns (bool);
    function isRegisteredMarket(address market) external view returns (bool);
    function isRegisteredController(address controller) external view returns (bool);
    function isRegisteredControllerFactory(address factory) external view returns (bool);
    function isBlacklistedAsset(address asset) external view returns (bool);
    function registerMarket(address market) external;
    function getRegisteredMarketsCount() external view returns (uint256);
    function getRegisteredMarkets() external view returns (address[] memory);
}
