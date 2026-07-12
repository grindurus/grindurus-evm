// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract GRAITokenTest is GRAIFixture {
    function test_TokenMetadata() public view {
        assertEq(grai.name(), "Grinders Artificial Index");
        assertEq(grai.symbol(), "GRAI");
        assertEq(grai.decimals(), 6);
    }

    function test_TokenURI() public {
        string memory uri = "https://example.com/grai.json";
        vm.prank(admin);
        grai.setTokenURI(uri);
        assertEq(grai.tokenURI(), uri);
    }

    function test_MintRequiresRegisteredAsset() public {
        vm.expectRevert(IGRAI.AssetUnknown.selector);
        vm.prank(alice);
        grai.mint(alice, 1e18);
    }

    function test_SweepRecoversStrayERC20() public {
        usdc.mint(address(grai), 10e6);
        vm.prank(admin);
        grai.sweep(address(usdc), juniorToken);
        assertEq(usdc.balanceOf(address(grai)), 0);
        assertEq(usdc.balanceOf(juniorToken), 10e6);
    }
}
