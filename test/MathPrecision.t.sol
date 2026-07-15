// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract MathPrecisionProbe is GRAIFixture {
  /// Micro redeem is allowed when NAV covers mint-price value.
  function test_MicroRedeemSucceeds() public {
    _mint(alice, usdc, 100e6);
    _mint(alice, weth, 1e18);

    uint256 before = graiToken.balanceOf(alice);
    vm.prank(alice);
    graiToken.redeem(1);
    assertEq(graiToken.balanceOf(alice), before - 1);
  }

  /// Redeem burns GRAI and reduces totalValue by the redeemed USD share.
  function test_RedeemReducesTotalValue() public {
    _mint(alice, usdc, 100e6);
    uint256 tv0 = grai.grai().totalValue();
    uint256 stBefore = grai.grai().balanceOf(alice);

    vm.prank(alice);
    graiToken.redeem(1);

    assertEq(grai.grai().balanceOf(alice), stBefore - 1);
    assertEq(grai.grai().totalValue(), tv0 - 1);
  }

  /// Mint works again after an asset is drained, delisted and re-listed.
  function test_MintAfterAssetRelistWorks() public {
    _mint(alice, usdc, 100e6);

    vm.startPrank(admin);
    graiToken.setPaused(address(usdc), true);
    vm.stopPrank();

    _redeem(alice, graiToken.balanceOf(alice));

    vm.startPrank(admin);
    graiToken.removeAsset(address(usdc), 0);
    _setChainlinkFeed(address(usdc), address(usdcFeed));
    graiToken.addAsset(address(usdc), DEFAULT_YIELD_SPLIT);
    vm.stopPrank();

    assertEq(grai.grai().seniorNAV(), 0);

    _mint(bob, usdc, 100e6);
    assertEq(grai.grai().seniorNAV(), 100e6);
    assertEq(grai.grai().balanceOf(bob), 100e6);
  }
}
