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
        NONE,
        CUSTOM,
        CHAINLINK,
        PYTH
    }

    struct Feed {
        FeedType feedType;
        address asset;
        address source;
        uint8 decimals;
        bytes32 data;
        /// @notice When true, blocks `deposit` for this asset only (not distribute / claim).
        bool paused;
        int256 storedPrice;
        uint256 storedUpdatedAt;
        uint256 maxStaleness;
    }

    function setFeed(address asset, Feed calldata feed) external;

    function getPrice(address asset) external view returns (uint256 price, uint8 priceDecimals);

    function usdValue(address asset, uint256 amount) external view returns (uint256);
}
