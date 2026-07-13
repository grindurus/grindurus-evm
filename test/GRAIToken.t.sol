// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract GRAITokenTest is GRAIFixture {
    function test_TokenMetadata() public view {
        assertEq(grai.name(), "Grinders Custodians");
        assertEq(grai.symbol(), "GRINDERS");
    }

    function test_TokenURI() public view {
        assertEq(graiToken.tokenURI(), "https://grindurus.xyz/metadata.json");
    }

    function test_MintRequiresRegisteredAsset() public {
        address unknown = makeAddr("unknownAsset");
        vm.expectRevert(IGRAI.AssetUnknown.selector);
        vm.prank(alice);
        graiToken.deposit(unknown, 1e18);
    }

    function test_SweepRecoversStrayERC20() public {
        usdc.mint(address(grai), 10e6);
        vm.prank(admin);
        grai.sweep(address(usdc));
        assertEq(usdc.balanceOf(address(grai)), 0);
        assertEq(usdc.balanceOf(admin), 10e6);
    }
}
