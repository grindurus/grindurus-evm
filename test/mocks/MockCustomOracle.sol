// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockCustomOracle {
    mapping(address asset => uint256) private _price;
    mapping(address asset => uint8) private _decimals;
    mapping(address asset => uint256) private _updatedAt;

    function setPrice(address asset, uint256 price, uint8 decimals) external {
        _price[asset] = price;
        _decimals[asset] = decimals;
        _updatedAt[asset] = block.timestamp;
    }

    function setUpdatedAt(address asset, uint256 updatedAt) external {
        _updatedAt[asset] = updatedAt;
    }

    function getPrice(address asset) external view returns (uint256 price, uint8 decimals, uint256 updatedAt) {
        return (_price[asset], _decimals[asset], _updatedAt[asset]);
    }
}
