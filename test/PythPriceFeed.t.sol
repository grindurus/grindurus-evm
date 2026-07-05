// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PythPriceFeedTest is GRAIFixture {
    bytes32 constant PYTH_WETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function _deployPythFeed(int64 price, int32 expo) internal returns (MockPyth pyth, MockERC20 asset) {
        pyth = new MockPyth();
        asset = new MockERC20("Pyth WETH", "pWETH", 18);
        pyth.setPrice(PYTH_WETH_USD, price, expo, block.timestamp);
        vm.prank(admin);
        oracle.addPythFeed(address(asset), address(pyth), PYTH_WETH_USD);
    }

    function test_PythFeedReadsThroughRouter() public {
        (, MockERC20 asset) = _deployPythFeed(2000e8, -8);
        (uint256 price, uint8 dec) = oracle.getPrice(address(asset));
        assertEq(price, 2000e8);
        assertEq(dec, 8);
    }

    function test_PythFeedMintsCorrectValue() public {
        (, MockERC20 asset) = _deployPythFeed(2000e8, -8);

        vm.prank(admin);
        grai.addAsset(address(asset), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);

        asset.mint(alice, 1e18);
        uint256 graiOut = _mint(alice, asset, 1e18); // 1 token @ $2000
        assertEq(graiOut, 2000e18);
    }

    function test_PythFeedHandlesDifferentExpo() public {
        (, MockERC20 asset) = _deployPythFeed(2000e5, -5);
        (uint256 price, uint8 dec) = oracle.getPrice(address(asset));
        assertEq(price, 2000e5);
        assertEq(dec, 5);
    }

    function test_PythFeedStalePriceRevertsViaRouter() public {
        (, MockERC20 asset) = _deployPythFeed(2000e8, -8);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(bytes("stale price"));
        oracle.getPrice(address(asset));
    }

    function test_PythFeedNegativePriceReverts() public {
        (MockPyth pyth, MockERC20 asset) = _deployPythFeed(2000e8, -8);
        pyth.setPrice(PYTH_WETH_USD, -1, -8, block.timestamp);
        vm.expectRevert(bytes("bad price"));
        oracle.getPrice(address(asset));
    }

    function test_PythFeedPositiveExpoReverts() public {
        (MockPyth pyth, MockERC20 asset) = _deployPythFeed(2000e8, -8);
        pyth.setPrice(PYTH_WETH_USD, 2000, 2, block.timestamp);
        vm.expectRevert(bytes("bad expo"));
        oracle.getPrice(address(asset));
    }

    function test_PythFeedZeroConfigReverts() public {
        MockERC20 asset = new MockERC20("Pyth WETH", "pWETH", 18);
        vm.startPrank(admin);
        vm.expectRevert(bytes("pyth=0"));
        oracle.addPythFeed(address(asset), address(0), PYTH_WETH_USD);
        vm.expectRevert(bytes("id=0"));
        oracle.addPythFeed(address(asset), address(0x1), bytes32(0));
        vm.stopPrank();
    }
}
