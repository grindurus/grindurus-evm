// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPyth, PythStructs} from "./interfaces/IPyth.sol";

/// Pyth price feed exposed as AggregatorV3Interface for the oracle router.
contract PythPriceFeed is AggregatorV3Interface {
    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    string private _description;

    constructor(address pyth_, bytes32 priceId_, string memory description_) {
        require(pyth_ != address(0), "pyth=0");
        require(priceId_ != bytes32(0), "id=0");
        pyth = IPyth(pyth_);
        priceId = priceId_;
        _description = description_;
    }

    function decimals() external view returns (uint8) {
        PythStructs.Price memory p = pyth.getPriceUnsafe(priceId);
        return _decimalsFromExpo(p.expo);
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PythStructs.Price memory p = pyth.getPriceUnsafe(priceId);
        require(p.price > 0, "bad price");
        _decimalsFromExpo(p.expo);

        roundId = uint80(p.publishTime);
        answer = int256(p.price);
        startedAt = p.publishTime;
        updatedAt = p.publishTime;
        answeredInRound = roundId;
    }

    function _decimalsFromExpo(int32 expo) internal pure returns (uint8) {
        require(expo <= 0, "bad expo");
        uint256 d = uint256(uint32(-expo));
        require(d <= 18, "expo>18");
        return uint8(d);
    }
}
