// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCustomOracle} from "./mocks/MockCustomOracle.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";

contract CustomPriceFeedTest is GRAIFixture {
    function test_CustomPriceFeedWorksThroughRouter() public {
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);
        MockCustomOracle custom = new MockCustomOracle();
        custom.setPrice(address(mock), 5e8, 8);

        vm.prank(admin);
        grai.setFeed(
            address(mock),
            IPriceOracleRouter.Feed({
                feedType: IPriceOracleRouter.FeedType.CUSTOM,
                asset: address(mock),
                source: address(custom),
                decimals: 0,
                data: bytes32(MockCustomOracle.getPrice.selector),

            paused: false,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );

        (uint256 price, uint8 dec) = grai.getPrice(address(mock));
        assertEq(price, 5e8);
        assertEq(dec, 8);
    }

    function test_CustomPriceFeedStaleReverts() public {
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);
        MockCustomOracle custom = new MockCustomOracle();
        custom.setPrice(address(mock), 5e8, 8);

        vm.prank(admin);
        grai.setFeed(
            address(mock),
            IPriceOracleRouter.Feed({
                feedType: IPriceOracleRouter.FeedType.CUSTOM,
                asset: address(mock),
                source: address(custom),
                decimals: 0,
                data: bytes32(MockCustomOracle.getPrice.selector),

            paused: false,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );

        vm.warp(block.timestamp + DEFAULT_MAX_STALENESS + 1);
        vm.expectRevert(IPriceOracleRouter.StalePrice.selector);
        grai.getPrice(address(mock));
    }

    function test_CustomPriceFeedFutureUpdatedAtReverts() public {
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);
        MockCustomOracle custom = new MockCustomOracle();
        custom.setPrice(address(mock), 5e8, 8);
        custom.setUpdatedAt(address(mock), block.timestamp + 1);

        vm.prank(admin);
        grai.setFeed(
            address(mock),
            IPriceOracleRouter.Feed({
                feedType: IPriceOracleRouter.FeedType.CUSTOM,
                asset: address(mock),
                source: address(custom),
                decimals: 0,
                data: bytes32(MockCustomOracle.getPrice.selector),

            paused: false,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );

        vm.expectRevert(IPriceOracleRouter.StalePrice.selector);
        grai.getPrice(address(mock));
    }

    function test_CustomPriceFeedBadCallReverts() public {
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);

        vm.prank(admin);
        grai.setFeed(
            address(mock),
            IPriceOracleRouter.Feed({
                feedType: IPriceOracleRouter.FeedType.CUSTOM,
                asset: address(mock),
                source: makeAddr("noCode"),
                decimals: 0,
                data: bytes32(uint256(1)),

            paused: false,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );

        vm.expectRevert(IPriceOracleRouter.BadCall.selector);
        grai.getPrice(address(mock));
    }
}
