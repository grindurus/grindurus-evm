// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPriceOracleRouter {
    error FeedTypeZero();
    error UnknownFeedType();
    error FeedExists();
    error SourceZero();
    error StalenessZero();
    error PriceIdZero();
    error FeedDataZero();
    error AssetMismatch();
    error BadCall();
    error BadPrice();
    error RoundIncomplete();
    error StalePrice();
    error BadExpo();
    error ExpoTooLarge();

    enum FeedType {
        None,
        Custom,
        Chainlink,
        Pyth
    }

    struct Feed {
        FeedType feedType;
        address asset;
        address source;
        bytes32 data;
        uint8 decimals;
        int256 storedPrice;
        uint256 storedUpdatedAt;
        uint256 maxStaleness;
    }

    function setFeed(address asset, Feed calldata feed) external;

    function getPrice(address asset) external view returns (uint256 price, uint8 priceDecimals);

    function usdValue(address asset, uint256 amount) external view returns (uint256);
}
