// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract MathPrecisionProbe is GRAIFixture {
  /// Micro-burn where every per-asset share floors to 0 is blocked by DustBurn.
  function test_DustBurnRevertsOnMicroBurn() public {
    _mint(alice, usdc, 100e6);
    _mint(alice, weth, 1e18);

    vm.prank(alice);
    vm.expectRevert(IGRAI.DustBurn.selector);
    grai.burn(1);
  }

  /// Burn reduces protocol NAV by the senior-tranche value burned.
  function test_BurnNavWithoutRedeem() public {
    _mint(alice, usdc, 100e6);
    uint256 tv0 = grai.totalValue();
    uint256 stBefore = grai.seniorToken().balanceOf(alice);

    vm.prank(alice);
    grai.burn(1);

    assertEq(grai.seniorToken().balanceOf(alice), stBefore - 1);
    assertEq(grai.totalValue(), tv0 - 1);
  }

  /// Mint works again after an asset is delisted and re-listed.
  function test_MintAfterAssetRelistWorks() public {
    _mint(alice, usdc, 100e6);

    vm.startPrank(admin);
    grai.setPaused(address(usdc), true);
    grai.removeAsset(address(usdc), 0);
    grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
    vm.stopPrank();

    assertEq(grai.totalValue(), 0);
    assertEq(grai.seniorToken().totalValue(), 0);
    assertEq(grai.juniorToken().totalValue(), 0);

    _mint(bob, usdc, 100e6);
    assertEq(grai.totalValue(), 100e6);
    assertEq(grai.seniorToken().balanceOf(bob), 50e6);
  }
}
