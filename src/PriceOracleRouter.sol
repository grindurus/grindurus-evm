// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {IPyth, PythStructs} from "./interfaces/IPyth.sol";

/// Unified upgradeable oracle router: maps each asset to a Chainlink, Pyth, or custom feed.
contract PriceOracleRouter is IPriceOracleRouter, OwnableUpgradeable, UUPSUpgradeable {
    uint256 public maxStaleness;

    bytes32 public constant FEED_CHAINLINK = keccak256("FEED_CHAINLINK");
    bytes32 public constant FEED_PYTH = keccak256("FEED_PYTH");
    bytes32 public constant FEED_CUSTOM = keccak256("FEED_CUSTOM");

    struct Feed {
        bytes32 feedType;
        address source;
        bytes32 data;
        uint8 decimals;
        int256 storedPrice;
        uint256 storedUpdatedAt;
    }

    mapping(address asset => Feed) public feeds;

    /// @dev Storage gap for future upgrades.
    uint256[48] private __gap;

    event FeedAdd(address indexed asset, bytes32 feedType);
    event CustomOracleUpdate(address indexed asset, address indexed oracle);
    event CustomPriceSet(address indexed asset, int256 price, uint256 updatedAt);
    event MaxStalenessUpdate(uint256 maxStaleness);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        require(owner != address(0), "admin=0");
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        maxStaleness = 1 hours;
    }

    function setMaxStaleness(uint256 newMaxStaleness) external onlyOwner {
        require(newMaxStaleness > 0, "staleness=0");
        maxStaleness = newMaxStaleness;
        emit MaxStalenessUpdate(newMaxStaleness);
    }

    function addChainlinkFeed(address asset, address aggregator) external onlyOwner {
        require(aggregator != address(0), "aggregator=0");
        require(feeds[asset].feedType == bytes32(0), "exists");
        feeds[asset] = Feed({
            feedType: FEED_CHAINLINK,
            source: aggregator,
            data: bytes32(0),
            decimals: 0,
            storedPrice: 0,
            storedUpdatedAt: 0
        });
        emit FeedAdd(asset, FEED_CHAINLINK);
    }

    function addPythFeed(address asset, address pyth, bytes32 priceId) external onlyOwner {
        require(pyth != address(0), "pyth=0");
        require(priceId != bytes32(0), "id=0");
        require(feeds[asset].feedType == bytes32(0), "exists");
        feeds[asset] = Feed({
            feedType: FEED_PYTH,
            source: pyth,
            data: priceId,
            decimals: 0,
            storedPrice: 0,
            storedUpdatedAt: 0
        });
        emit FeedAdd(asset, FEED_PYTH);
    }

    function addCustomFeed(address asset, uint8 decimals, address oracle) external onlyOwner {
        require(oracle != address(0), "oracle=0");
        require(feeds[asset].feedType == bytes32(0), "exists");
        feeds[asset] = Feed({
            feedType: FEED_CUSTOM,
            source: oracle,
            data: bytes32(0),
            decimals: decimals,
            storedPrice: 0,
            storedUpdatedAt: 0
        });
        emit FeedAdd(asset, FEED_CUSTOM);
    }

    function setCustomOracle(address asset, address oracle) external onlyOwner {
        require(feeds[asset].feedType == FEED_CUSTOM, "not custom");
        require(oracle != address(0), "oracle=0");
        feeds[asset].source = oracle;
        emit CustomOracleUpdate(asset, oracle);
    }

    function setCustomPrice(address asset, int256 price) external {
        Feed storage f = feeds[asset];
        require(f.feedType == FEED_CUSTOM, "not custom");
        require(msg.sender == f.source, "not oracle");
        require(price > 0, "bad price");
        f.storedPrice = price;
        f.storedUpdatedAt = block.timestamp;
        emit CustomPriceSet(asset, price, block.timestamp);
    }

    function getPrice(address asset) public view returns (uint256 price, uint8 priceDecimals) {
        Feed storage f = feeds[asset];
        bytes32 feedType = f.feedType;
        if (feedType == FEED_CHAINLINK) return _chainlink(f.source);
        if (feedType == FEED_PYTH) return _pyth(f.source, f.data);
        if (feedType == FEED_CUSTOM) return _custom(f);
        revert("unknown asset");
    }

    function _chainlink(address aggregator) internal view returns (uint256 price, uint8 priceDecimals) {
        AggregatorV3Interface agg = AggregatorV3Interface(aggregator);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        require(answer > 0, "bad price");
        require(updatedAt != 0, "round incomplete");
        require(block.timestamp - updatedAt <= maxStaleness, "stale price");
        return (uint256(answer), agg.decimals());
    }

    function _pyth(address pyth, bytes32 priceId) internal view returns (uint256 price, uint8 priceDecimals) {
        PythStructs.Price memory p = IPyth(pyth).getPriceUnsafe(priceId);
        require(p.price > 0, "bad price");
        priceDecimals = _decimalsFromExpo(p.expo);
        require(p.publishTime != 0, "round incomplete");
        require(block.timestamp - p.publishTime <= maxStaleness, "stale price");
        return (uint256(int256(p.price)), priceDecimals);
    }

    function _custom(Feed storage f) internal view returns (uint256 price, uint8 priceDecimals) {
        require(f.storedPrice > 0, "bad price");
        require(f.storedUpdatedAt != 0, "round incomplete");
        require(block.timestamp - f.storedUpdatedAt <= maxStaleness, "stale price");
        return (uint256(f.storedPrice), f.decimals);
    }

    function _decimalsFromExpo(int32 expo) internal pure returns (uint8) {
        require(expo <= 0, "bad expo");
        uint256 d = uint256(uint32(-expo));
        require(d <= 18, "expo>18");
        return uint8(d);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
