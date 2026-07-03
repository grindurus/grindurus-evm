// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
}

// Minimal IPyth subset (dependency-free, same idea as AggregatorV3Interface).
interface IPyth {
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory price);

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory price);

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
