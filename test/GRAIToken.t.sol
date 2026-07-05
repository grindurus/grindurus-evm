// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";

contract GRAITokenTest is GRAIFixture {
    function test_TokenMetadata() public view {
        assertEq(grai.name(), "Grinders Artificial Index");
        assertEq(grai.symbol(), "GRAI");
        assertEq(grai.decimals(), 18);
    }

    function test_TokenURI() public {
        string memory uri = "https://example.com/grai.json";
        vm.prank(admin);
        grai.setTokenURI(uri);
        assertEq(grai.tokenURI(), uri);
    }

    function test_MintRequiresRegisteredAsset() public {
        vm.expectRevert(bytes("unknown asset"));
        vm.prank(alice);
        grai.mint(alice, 1e18);
    }
}
