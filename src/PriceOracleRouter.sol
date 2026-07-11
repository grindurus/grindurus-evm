// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {IPyth, PythStructs} from "./interfaces/IPyth.sol";

/// @title PriceOracleRouter
/// @notice Asset-keyed oracle router for Chainlink, Pyth, and custom on-chain price feeds.
/// @dev Registers one feed per asset via `setFeed`; re-registration reverts. Each feed carries its own
///      `maxStaleness` and must return a positive price with a fresh timestamp. Feed types: `1` custom,
///      `2` Chainlink (`source` = aggregator), `3` Pyth (`source` = Pyth contract, `data` = price id).
///      Custom feed call shape is documented on `_custom`.
contract PriceOracleRouter is IPriceOracleRouter {
    uint8 internal constant FEED_NONE = 0;
    uint8 internal constant FEED_CUSTOM = 1;
    uint8 internal constant FEED_CHAINLINK = 2;
    uint8 internal constant FEED_PYTH = 3;

    mapping(address asset => Feed) public feeds;

    function setFeed(address asset, Feed calldata feed) public virtual {
        if (feed.feedType == FEED_NONE) revert FeedTypeZero();
        if (feed.feedType > FEED_PYTH) revert UnknownFeedType();
        if (feeds[asset].feedType != FEED_NONE) revert FeedExists();
        if (feed.source == address(0)) revert SourceZero();
        if (feed.maxStaleness == 0) revert StalenessZero();
        if (feed.feedType == FEED_PYTH && feed.data == bytes32(0)) revert PriceIdZero();
        if (feed.feedType == FEED_CUSTOM && feed.data == bytes32(0)) revert FeedDataZero();
        if (feed.asset != asset) revert AssetMismatch();
        feeds[asset] = feed;
        emit FeedAdd(asset, feed.feedType);
    }

    function getPrice(address asset) public view returns (uint256 price, uint8 priceDecimals) {
        Feed storage f = feeds[asset];
        uint8 feedType = f.feedType;
        if (feedType == FEED_CUSTOM) return _custom(f);
        if (feedType == FEED_CHAINLINK) return _chainlink(f);
        if (feedType == FEED_PYTH) return _pyth(f);
        revert UnknownFeedType();
    }

    /// @dev Custom feed: staticcall to `source` with selector `bytes4(data)` and `asset` as the only argument.
    ///
    /// Register via `setFeed`:
    ///   feedType = FEED_CUSTOM (1)
    ///   source   = custom oracle contract address
    ///   data     = bytes32(functionSelector) — e.g. bytes32(IOracle.getPrice.selector)
    ///   asset    = address passed as the call argument (must equal the mapping key)
    ///   maxStaleness = max age of `updatedAt` in seconds
    ///
    /// Oracle must implement a view/pure function `fn(address asset)` returning ABI-encoded:
    ///   (uint256 price, uint8 priceDecimals, uint256 updatedAt)
    ///
    /// Example oracle:
    ///   function getPrice(address asset) external view returns (uint256, uint8, uint256);
    ///
    /// Example registration:
    ///   setFeed(TOKEN, Feed({
    ///       feedType: 1,
    ///       asset: TOKEN,
    ///       source: address(customOracle),
    ///       data: bytes32(customOracle.getPrice.selector),
    ///       decimals: 0,
    ///       storedPrice: 0,
    ///       storedUpdatedAt: 0,
    ///       maxStaleness: 1 hours
    ///   }));
    function _custom(Feed storage f) internal view returns (uint256 price, uint8 priceDecimals) {
        (bool ok, bytes memory ret) = f.source.staticcall(abi.encodeWithSelector(bytes4(f.data), f.asset));
        if (!ok || ret.length < 96) revert BadCall();
        uint256 updatedAt;
        (price, priceDecimals, updatedAt) = abi.decode(ret, (uint256, uint8, uint256));
        if (price == 0) revert BadPrice();
        if (updatedAt == 0) revert RoundIncomplete();
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice();
    }

    function _chainlink(Feed storage f) internal view returns (uint256 price, uint8 priceDecimals) {
        AggregatorV3Interface agg = AggregatorV3Interface(f.source);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (updatedAt == 0) revert RoundIncomplete();
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), agg.decimals());
    }

    function _pyth(Feed storage f) internal view returns (uint256 price, uint8 priceDecimals) {
        PythStructs.Price memory p = IPyth(f.source).getPriceUnsafe(f.data);
        if (p.price <= 0) revert BadPrice();
        if (p.expo > 0) revert BadExpo();
        uint256 decimals = uint256(uint32(-p.expo));
        if (decimals > 18) revert ExpoTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        priceDecimals = uint8(decimals);
        if (p.publishTime == 0) revert RoundIncomplete();
        if (block.timestamp - p.publishTime > f.maxStaleness) revert StalePrice();
        return (uint256(int256(p.price)), priceDecimals);
    }
}
