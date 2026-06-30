// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracleRouter {
    function getPrice(address feed) external view returns (uint256 price, uint8 priceDecimals);
}
