// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";
import {CustomPriceFeed} from "../src/CustomPriceFeed.sol";

contract CustomPriceFeedTest is GRAIFixture {
    function test_CustomPriceFeedWorksThroughRouter() public {
        address oracleSigner = makeAddr("oracleSigner");
        CustomPriceFeed feed = new CustomPriceFeed(8, "MOCK/USD", oracleSigner, admin);

        vm.prank(oracleSigner);
        feed.setPrice(5e8); // $5

        (uint256 price, uint8 dec) = oracle.getPrice(address(feed));
        assertEq(price, 5e8);
        assertEq(dec, 8);
    }

    function test_CustomPriceFeedAclEnforced() public {
        CustomPriceFeed feed = new CustomPriceFeed(8, "MOCK/USD", makeAddr("oracleSigner"), admin);
        vm.expectRevert(bytes("not oracle"));
        vm.prank(alice);
        feed.setPrice(5e8);
    }
}
