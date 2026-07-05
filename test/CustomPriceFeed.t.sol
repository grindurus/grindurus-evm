// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CustomPriceFeedTest is GRAIFixture {
    function test_CustomPriceFeedWorksThroughRouter() public {
        address oracleSigner = makeAddr("oracleSigner");
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);

        vm.startPrank(admin);
        oracle.addCustomFeed(address(mock), 8, oracleSigner);
        vm.stopPrank();

        vm.prank(oracleSigner);
        oracle.setCustomPrice(address(mock), 5e8); // $5

        (uint256 price, uint8 dec) = oracle.getPrice(address(mock));
        assertEq(price, 5e8);
        assertEq(dec, 8);
    }

    function test_CustomPriceFeedAclEnforced() public {
        MockERC20 mock = new MockERC20("Mock", "MOCK", 18);

        vm.prank(admin);
        oracle.addCustomFeed(address(mock), 8, makeAddr("oracleSigner"));

        vm.expectRevert(bytes("not oracle"));
        vm.prank(alice);
        oracle.setCustomPrice(address(mock), 5e8);
    }
}
