// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

contract CustomPriceFeed is AggregatorV3Interface, Ownable {
    uint8 public immutable feedDecimals;
    string private _description;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    address public oracle;

    event OracleUpdated(address indexed oracle);
    event AnswerUpdated(int256 indexed answer, uint80 indexed roundId, uint256 updatedAt);

    constructor(uint8 decimals_, string memory description_, address oracle_, address owner_) Ownable(owner_) {
        require(oracle_ != address(0), "oracle=0");
        feedDecimals = decimals_;
        _description = description_;
        oracle = oracle_;
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "oracle=0");
        oracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    function setPrice(int256 price) external {
        require(msg.sender == oracle, "not oracle");
        require(price > 0, "bad price");
        _answer = price;
        _updatedAt = block.timestamp;
        unchecked {
            _roundId += 1;
        }
        emit AnswerUpdated(price, _roundId, block.timestamp);
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
