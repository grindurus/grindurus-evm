// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracleRouter {
    function maxStaleness() external view returns (uint256);

    function setMaxStaleness(uint256 maxStaleness) external;

    function addChainlinkFeed(address asset, address aggregator) external;

    function addPythFeed(address asset, address pyth, bytes32 priceId) external;

    function addCustomFeed(address asset, uint8 decimals, address oracle) external;

    function setCustomOracle(address asset, address oracle) external;

    function setCustomPrice(address asset, int256 price) external;

    function getPrice(address asset) external view returns (uint256 price, uint8 priceDecimals);
}
