// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) private _prices;
    mapping(bytes32 => bool) private _known;

    function setPrice(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        _prices[id] = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
        _known[id] = true;
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        require(_known[id], "price feed not found");
        return _prices[id];
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory) {
        require(_known[id], "price feed not found");
        PythStructs.Price memory p = _prices[id];
        require(block.timestamp - p.publishTime <= age, "stale price");
        return p;
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}
}
