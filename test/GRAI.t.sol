// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {console2} from "forge-std/console2.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

/// @dev Yield-asset Dutch auction scenarios: distribute → 1y auction → fill for hedgeAsset.
contract GRAITest is GRAIFixture {
    address yielder = makeAddr("yielder");
    MockAggregator ethFeed;

    function _logState(string memory label) internal view {
        console2.log("====================", label);
        console2.log("totalSupply (GRAI 1e6):", grai.totalSupply());
        console2.log("totalValue ($ 1e6):  ", grai.totalValue());
        console2.log("hedgeAsset:            ", grai.hedgeAsset());
        console2.log("idle ETH (wei):        ", address(grai).balance);
        console2.log("idle USDC (1e6):       ", usdc.balanceOf(address(grai)));
        console2.log("idle WETH (wei):       ", weth.balanceOf(address(grai)));
        console2.log("auctions:              ", grai.getAuctions().length);
        console2.log("alice GRAI (1e6):      ", grai.balanceOf(alice));
        console2.log("alice USDC (1e6):      ", usdc.balanceOf(alice));
        console2.log("bob USDC (1e6):        ", usdc.balanceOf(bob));
        console2.log("bob WETH (wei):        ", weth.balanceOf(bob));
    }

    function _setupEthAndHedgeUsdc() internal {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        ethFeed = new MockAggregator(8, 1000e8);
        _setChainlinkFeed(address(0), address(ethFeed));
        _setAssetConfig(address(0), 10_000, false);
        _setAssetConfig(address(usdc), 10_000, false);
        grai.setHedgeAsset(address(usdc));
        vm.stopPrank();
    }

    function _refreshFeeds() internal {
        if (address(ethFeed) != address(0)) ethFeed.setUpdatedAt(block.timestamp);
        usdcFeed.setUpdatedAt(block.timestamp);
        wethFeed.setUpdatedAt(block.timestamp);
    }

    function test_DistributeCreatesYearAuctionAtOraclePrice() public {
        _setupEthAndHedgeUsdc();
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        grai.mint{value: 1 ether}(address(0), 1 ether);
        vm.stopPrank();

        // Distribute 0.1 ETH @ $1000 → yieldShare 0.1 ETH, fair value $100 = 100e6 USDC.
        vm.deal(yielder, 0.1 ether);
        vm.prank(yielder);
        grai.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        (
            address asset,
            uint256 remaining,
            uint256 initial,
            uint256 maxPayment,
            uint256 minPayment,
            uint256 startTime
        ) = grai.auctions(address(0));

        assertEq(asset, address(0));
        assertEq(remaining, 0.1 ether);
        assertEq(initial, 0.1 ether);
        assertEq(maxPayment, 100e6);
        assertEq(minPayment, 0);
        assertEq(startTime, block.timestamp);
        assertEq(grai.getAuctions().length, 1);

        (uint256 amountOut, uint256 payment) = grai.previewFill(address(0), type(uint256).max, block.timestamp);
        assertEq(amountOut, 0.1 ether);
        assertEq(payment, 100e6);
        _logState("after distribute ETH yield");
    }

    function test_FillAuctionHalfYearAndAfterYear() public {
        _setupEthAndHedgeUsdc();
        vm.deal(yielder, 0.1 ether);
        vm.prank(yielder);
        grai.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        // t = 0.5y → price ≈ 50 USDC for full lot (preview uses stored maxPayment; no oracle read).
        uint256 tHalf = block.timestamp + 365 days / 2;
        (, uint256 payHalf) = grai.previewFill(address(0), type(uint256).max, tHalf);
        assertEq(payHalf, 50e6);

        vm.warp(tHalf);
        _refreshFeeds();
        usdc.mint(bob, 50e6);
        uint256 bobEthBefore = bob.balance;
        _fill(bob, address(0), type(uint256).max, 50e6);

        assertEq(bob.balance - bobEthBefore, 0.1 ether);
        assertEq(usdc.balanceOf(address(grai)), 50e6);
        assertEq(grai.getAuctions().length, 0);

        // Fresh auction, then wait full year → payment 0
        vm.deal(yielder, 0.1 ether);
        vm.prank(yielder);
        grai.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        (, uint256 payZero) = grai.previewFill(address(0), type(uint256).max, block.timestamp);
        assertEq(payZero, 0);

        uint256 bobEth2 = bob.balance;
        _fill(bob, address(0), type(uint256).max, 0);
        assertEq(bob.balance - bobEth2, 0.1 ether);
        assertEq(grai.getAuctions().length, 0);
    }

    function test_DistributeMergesAndRestartsAuction() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        _setAssetConfig(address(weth), 10_000, false);
        grai.setHedgeAsset(address(usdc));
        vm.stopPrank();

        weth.mint(yielder, 2e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 2e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        (,,, uint256 max1,, uint256 start1) = grai.auctions(address(weth));
        assertEq(max1, 2000e6); // 1 WETH @ $2000

        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();

        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        (, uint256 remaining, uint256 initial, uint256 max2,, uint256 start2) = grai.auctions(address(weth));
        assertEq(remaining, 2e18);
        assertEq(initial, 2e18);
        assertEq(max2, 4000e6);
        assertGt(start2, start1);
        assertEq(start2, block.timestamp);
    }

    function test_DistributeHedgeAssetSkipsAuction() public {
        vm.startPrank(admin);
        grai.setHedgeAsset(address(usdc));
        _setAssetConfig(address(usdc), 8_000, false);
        vm.stopPrank();

        usdc.mint(yielder, 100e6);
        vm.startPrank(yielder);
        usdc.approve(address(grai), 100e6);
        grai.distribute(address(usdc), 100e6);
        vm.stopPrank();

        // 80% yield stays as insurance; 20% to treasury (admin)
        assertEq(usdc.balanceOf(address(grai)), 80e6);
        assertEq(usdc.balanceOf(admin), 20e6);
        assertEq(grai.getAuctions().length, 0);
    }

    function test_PartialFillAuction() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), 10_000, false);
        grai.setHedgeAsset(address(usdc));
        vm.stopPrank();

        weth.mint(yielder, 1e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        usdc.mint(bob, 1000e6);
        // Buy half WETH at t=0 → payment 1000 USDC
        _fill(bob, address(weth), 0.5e18, 1000e6);

        assertEq(weth.balanceOf(bob), 0.5e18);
        assertEq(usdc.balanceOf(address(grai)), 1000e6);

        (, uint256 remaining, uint256 initial, uint256 maxPayment,,) = grai.auctions(address(weth));
        assertEq(remaining, 0.5e18);
        assertEq(initial, 1e18);
        assertEq(maxPayment, 2000e6);
        assertEq(grai.getAuctions().length, 1);
    }

    function test_MintIsOneToOneUsd() public {
        _mint(alice, usdc, 1000e6);
        assertEq(grai.balanceOf(alice), 1000e6);
        assertEq(grai.totalValue(), 1000e6);

        _mint(alice, weth, 1e18);
        assertEq(grai.balanceOf(alice), 1000e6 + 2000e6);
        assertEq(grai.totalValue(), 3000e6);
    }

    function test_SetHedgeAssetRequiresFeed() public {
        address unknown = makeAddr("unknown");
        vm.prank(admin);
        vm.expectRevert(IGRAI.AssetUnknown.selector);
        grai.setHedgeAsset(unknown);
    }

    function test_FillRevertsWhenPaymentMaxTooLow() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), 10_000, false);
        grai.setHedgeAsset(address(usdc));
        vm.stopPrank();

        weth.mint(yielder, 1e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        usdc.mint(bob, 2000e6);
        vm.startPrank(bob);
        usdc.approve(address(grai), 2000e6);
        vm.expectRevert(IGRAI.Slippage.selector);
        grai.fill(address(weth), type(uint256).max, 1999e6);
        vm.stopPrank();
    }

    function test_RedeemOnlyDuringLiquidationAndProRata() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        _mint(alice, usdc, 100e6);
        _mint(bob, usdc, 100e6);

        vm.prank(alice);
        vm.expectRevert(IGRAI.LiquidationClosed.selector);
        grai.redeem(100e6);

        vm.prank(alice);
        grai.vote(100e6);
        vm.prank(bob);
        grai.vote(100e6);
        vm.prank(admin);
        grai.liquidate();
        assertEq(grai.liquidationAt(), block.timestamp);

        // Unlock voted shares once liquidation has opened.
        vm.prank(alice);
        grai.vote(0);
        vm.prank(bob);
        grai.vote(0);

        // Simulate Grinders returning liquidated USDC directly to GRAI.
        deal(address(usdc), address(grai), 200e6, true);

        (,, uint32 liquidationPeriod, uint32 redeemPeriod) = grai.config();

        vm.prank(alice);
        vm.expectRevert(IGRAI.LiquidationDelay.selector);
        grai.redeem(100e6);

        vm.warp(block.timestamp + liquidationPeriod);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        grai.redeem(100e6);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);
        assertEq(grai.totalValue(), 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        grai.redeem(100e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6);
        assertEq(grai.totalValue(), 0);
        assertEq(grai.totalSupply(), 0);

        vm.prank(admin);
        vm.expectRevert(IGRAI.RedeemPeriodActive.selector);
        grai.liquidate();

        vm.warp(block.timestamp + redeemPeriod);
        vm.prank(admin);
        grai.liquidate();
        assertFalse(grai.liquidation());
        assertEq(grai.liquidationAt(), 0);
        (,, bool paused,) = grai.assets(address(usdc));
        assertFalse(paused);
    }

    function test_LiquidationCancelsAuctionsIntoRedemptionBasket() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), 10_000, false);
        grai.setHedgeAsset(address(usdc));
        vm.stopPrank();

        _mint(alice, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);

        weth.mint(yielder, 1e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();
        assertEq(grai.getAuctions().length, 1);

        vm.prank(admin);
        grai.liquidate();
        assertEq(grai.getAuctions().length, 0);
        (,, uint32 liquidationPeriod,) = grai.config();
        vm.warp(block.timestamp + liquidationPeriod);

        vm.prank(alice);
        grai.vote(0);
        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        grai.redeem(100e6);
        assertEq(weth.balanceOf(alice) - wethBefore, 1e18);
    }
}
