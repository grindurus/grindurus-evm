// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MathPrecisionProbe is GRAIFixture {
    /// Deposit is 1 GRAI per $1 of deposited value (USD_DECIMALS = 6).
    function test_DepositIsOneToOneUsd() public {
        _deposit(alice, usdc, 100e6);
        _deposit(alice, weth, 1e18);
        assertEq(grai.balanceOf(alice), 100e6 + 2000e6);
        assertEq(grai.totalValue(), 2100e6);
    }

    /// Auction payment scales linearly with fill size at t=0.
    function test_AuctionPaymentProRataAtStart() public {
        vm.startPrank(admin);
        grai.setSettlementAsset(address(usdc));
        _setAssetConfig(address(weth), 0, false);
        vm.stopPrank();

        deal(address(weth), alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        (uint256 out1, uint256 pay1) = grai.previewFill(address(weth), 0.25e18, block.timestamp);
        (uint256 out2, uint256 pay2) = grai.previewFill(address(weth), 0.75e18, block.timestamp);
        assertEq(out1, 0.25e18);
        assertEq(out2, 0.75e18);
        assertEq(pay1, 500e6);
        assertEq(pay2, 1500e6);
        assertEq(pay1 + pay2, 2000e6);
    }

    /// Deposit works again after an asset is drained, delisted and re-listed.
    function test_DepositAfterAssetRelistWorks() public {
        _deposit(alice, usdc, 100e6);

        // Idle USDC may sit on GRAI when grinders == this; drain it before delist.
        uint256 idle = IERC20(address(usdc)).balanceOf(address(grai));
        if (idle > 0) {
            deal(address(usdc), address(grai), 0, true);
        }

        vm.startPrank(admin);
        _setAssetConfig(address(usdc), DEFAULT_TREASURY_SHARE, true);
        _clearFeed(address(usdc)); // delist (paused + drained)
        _setChainlinkFeed(address(usdc), address(usdcFeed)); // re-list
        _setAssetConfig(address(usdc), DEFAULT_TREASURY_SHARE, false);
        vm.stopPrank();

        _deposit(bob, usdc, 100e6);
        assertEq(grai.balanceOf(bob), 100e6);
        assertEq(grai.totalValue(), 200e6);
    }
}
