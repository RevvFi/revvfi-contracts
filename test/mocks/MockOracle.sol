// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../src/interfaces/IAggregatorV3Interface.sol";

contract MockOracle is IAggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 initialPrice) {
        _decimals = decimals_;
        _price = initialPrice;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return "Mock Oracle";
    }

    function version() external view override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function setStale() external {
        // Older than the escrow's default 24h stalePriceThreshold. Prevent underflow.
        if (block.timestamp < 25 hours) {
            _updatedAt = 0;
        } else {
            _updatedAt = block.timestamp - 25 hours;
        }
    }

    function setFresh(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    // uint256 overload used by test scripts that pass unsigned price values
    function setLatestPrice(uint256 newPrice) external {
        _price = int256(newPrice);
        _updatedAt = block.timestamp;
    }
}
