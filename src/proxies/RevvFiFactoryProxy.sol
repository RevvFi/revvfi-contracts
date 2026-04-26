// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title MyTransparentUpgradeableProxy
/// @notice Transparent proxy that can be managed by a ProxyAdmin
contract MyTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    /// @param _logic Address of the initial implementation contract
    /// @param admin Address of the ProxyAdmin
    /// @param _data Initialization calldata for the logic contract
    constructor(address _logic, address admin, bytes memory _data) TransparentUpgradeableProxy(_logic, admin, _data){}

}