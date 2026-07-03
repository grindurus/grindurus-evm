// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";
import {PythPriceFeed} from "../src/PythPriceFeed.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PythPriceFeedTest is GRAIFixture {
    bytes32 constant PYTH_WETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function _deployPythFeed(int64 price, int32 expo) internal returns (MockPyth pyth, PythPriceFeed feed) {
        pyth = new MockPyth();
        pyth.setPrice(PYTH_WETH_USD, price, expo, block.timestamp);
        feed = new PythPriceFeed(address(pyth), PYTH_WETH_USD, "WETH/USD");
    }

    function test_PythFeedReadsThroughRouter() public {
        // $2000 with Pyth's typical expo of -8 -> answer 2000e8, 8 decimals
        (, PythPriceFeed feed) = _deployPythFeed(2000e8, -8);
        (uint256 price, uint8 dec) = oracle.getPrice(address(feed));
        assertEq(price, 2000e8);
        assertEq(dec, 8);
    }

    function test_PythFeedMintsCorrectValue() public {
        (, PythPriceFeed feed) = _deployPythFeed(2000e8, -8);

        // register a fresh asset priced by Pyth
        MockERC20 wbtcLike = new MockERC20("Pyth WETH", "pWETH", 18);
        vm.prank(admin);
        vault.addAsset(address(wbtcLike), address(feed));

        wbtcLike.mint(alice, 1e18);
        uint256 graiOut = _mint(alice, wbtcLike, 1e18); // 1 token @ $2000
        assertEq(graiOut, 2000e18);
    }

    function test_PythFeedHandlesDifferentExpo() public {
        // expo -5 -> 5 decimals; $2000 => 2000 * 1e5
        (, PythPriceFeed feed) = _deployPythFeed(2000e5, -5);
        (uint256 price, uint8 dec) = oracle.getPrice(address(feed));
        assertEq(price, 2000e5);
        assertEq(dec, 5);
    }

    function test_PythFeedStalePriceRevertsViaRouter() public {
        (, PythPriceFeed feed) = _deployPythFeed(2000e8, -8);
        vm.warp(block.timestamp + 2 hours); // beyond router MAX_STALENESS
        vm.expectRevert(bytes("stale price"));
        oracle.getPrice(address(feed));
    }

    function test_PythFeedNegativePriceReverts() public {
        (MockPyth pyth, PythPriceFeed feed) = _deployPythFeed(2000e8, -8);
        pyth.setPrice(PYTH_WETH_USD, -1, -8, block.timestamp);
        vm.expectRevert(bytes("bad price"));
        oracle.getPrice(address(feed));
    }

    function test_PythFeedPositiveExpoReverts() public {
        (MockPyth pyth, PythPriceFeed feed) = _deployPythFeed(2000e8, -8);
        pyth.setPrice(PYTH_WETH_USD, 2000, 2, block.timestamp);
        vm.expectRevert(bytes("bad expo"));
        oracle.getPrice(address(feed));
    }

    function test_PythFeedZeroConfigReverts() public {
        MockPyth pyth = new MockPyth();
        vm.expectRevert(bytes("pyth=0"));
        new PythPriceFeed(address(0), PYTH_WETH_USD, "WETH/USD");
        vm.expectRevert(bytes("id=0"));
        new PythPriceFeed(address(pyth), bytes32(0), "WETH/USD");
    }
}
