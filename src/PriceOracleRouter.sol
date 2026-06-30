// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";

contract PriceOracleRouter is IPriceOracleRouter {
    uint256 public constant MAX_STALENESS = 1 hours;

    function getPrice(address feed) public view returns (uint256 price, uint8 priceDecimals) {
        require(feed != address(0), "feed=0");
        AggregatorV3Interface agg = AggregatorV3Interface(feed);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        require(answer > 0, "bad price");
        require(updatedAt != 0, "round incomplete");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "stale price");
        return (uint256(answer), agg.decimals());
    }
}
