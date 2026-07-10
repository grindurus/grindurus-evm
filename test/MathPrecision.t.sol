// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract MathPrecisionProbe is GRAIFixture {
    /// Multi-asset micro-burns: burnValue>0 but every asset share floors to 0 →
    /// totalValue drifts below sum(assets[i].totalValue).
    function test_BurnDustDesyncsAssetBooksFromTotalValue() public {
        _mint(alice, usdc, 100e6);
        _mint(alice, weth, 1e18); // TV = 100e18 + 2000e18

        uint256 tv0 = grai.totalValue();
        (,,,, uint256 usdcBook0,) = grai.assets(address(usdc));
        (,,,, uint256 wethBook0,) = grai.assets(address(weth));
        assertEq(usdcBook0 + wethBook0, tv0);

        vm.startPrank(alice);
        // 500 one-wei burns: each burnValue=1, both shares floor to 0
        for (uint256 i; i < 500; ++i) {
            grai.burn(1);
        }
        vm.stopPrank();

        uint256 tv1 = grai.totalValue();
        (,,,, uint256 usdcBook1,) = grai.assets(address(usdc));
        (,,,, uint256 wethBook1,) = grai.assets(address(weth));

        assertEq(tv1, tv0 - 500, "totalValue reduced by burnValue dust");
        assertEq(usdcBook1, usdcBook0, "usdc book unchanged");
        assertEq(wethBook1, wethBook0, "weth book unchanged");
        assertEq(usdcBook1 + wethBook1, tv0, "sum books stale");
        assertGt(usdcBook1 + wethBook1, tv1, "invariant broken: sum books > totalValue");
    }

    /// After desync, removing assets one-by-one can make the next removeAsset underflow.
    function test_RemoveAssetUnderflowsAfterDustDesync() public {
        _mint(alice, usdc, 100e6);
        _mint(alice, weth, 1e18);

        vm.startPrank(alice);
        for (uint256 i; i < 1000; ++i) {
            grai.burn(1);
        }
        vm.stopPrank();

        uint256 tv = grai.totalValue();
        (,,,, uint256 usdcBook,) = grai.assets(address(usdc));
        (,,,, uint256 wethBook,) = grai.assets(address(weth));
        // usdcBook=100e18, wethBook=2000e18, tv = 2100e18-1000
        assertGt(usdcBook + wethBook, tv);

        vm.startPrank(admin);
        grai.setPaused(address(usdc), true);
        // hintId: usdc is index 0 in fixture
        grai.removeAsset(address(usdc), 0);
        // totalValue -= usdcBook → tv' = tv - 100e18 = 2000e18 - 1000
        // wethBook still 2000e18 > tv'
        grai.setPaused(address(weth), true);
        // weth is now index 0 after usdc removed
        vm.expectRevert(); // arithmetic underflow on totalValue -= a.totalValue
        grai.removeAsset(address(weth), 0);
        vm.stopPrank();
    }

    /// Burn reduces NAV but redeem floors to 0 for small graiAmount.
    function test_BurnNavWithoutRedeem() public {
        _mint(alice, usdc, 100e6);
        uint256 tv0 = grai.totalValue();
        uint256 bal0 = usdc.balanceOf(alice);

        vm.prank(alice);
        grai.burn(1e12); // below redeem threshold 2e12 for 50e6 senior / 100e18 supply

        assertEq(grai.totalValue(), tv0 - 1e12);
        assertEq(usdc.balanceOf(alice), bal0); // no tokens out
    }

    /// mint bootstrap path when totalValue==0 but supply>0 (via removeAsset).
    function test_MintBootstrapWithExistingSupplySteals() public {
        uint256 aliceGrai = _mint(alice, usdc, 100e6);

        vm.startPrank(admin);
        grai.setPaused(address(usdc), true);
        grai.removeAsset(address(usdc), 0);
        // re-add usdc so bob can mint
        grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        // feed mapping survives removeAsset; do not setFeed again
        vm.stopPrank();

        assertEq(grai.totalValue(), 0);
        assertEq(grai.totalSupply(), aliceGrai);

        uint256 bobGrai = _mint(bob, usdc, 100e6);
        // bootstrap: graiOut == depositValue despite existing supply
        assertEq(bobGrai, 100e18);
        assertEq(grai.totalSupply(), aliceGrai + bobGrai);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        // alice burns half supply claim on bob's senior deposit
        vm.prank(alice);
        grai.burn(aliceGrai);
        // redeem = aliceGrai/(alice+bob) * senior = 100/200 * 50e6 = 25e6
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 25e6);
    }
}
