// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";

contract GRAITokenTest is GRAIFixture {
    function test_TokenMetadata() public view {
        assertEq(grai.name(), "Grinders Artificial Index");
        assertEq(grai.symbol(), "GRAI");
        assertEq(grai.decimals(), 18);
    }

    function test_OnlyVaultCanMint() public {
        vm.expectRevert();
        vm.prank(alice);
        grai.mint(alice, 1e18);
    }
}
