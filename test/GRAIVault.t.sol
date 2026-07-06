// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GRAIFixture} from "./GRAIFixture.sol";

contract GRAIVaultTest is GRAIFixture {
    function test_AddAssetRegistersAsset() public view {
        assertEq(grai.assetCount(), 2);
        (bool exists,,,,,) = grai.assets(address(usdc));
        assertTrue(exists);
        assertEq(grai.seniorVault().PROPRIETOR(), address(grai));
        assertEq(grai.juniorVault().PROPRIETOR(), address(grai));
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("exists"));
        grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
    }

    function test_FirstMintBootstrapsAtParity() public {
        uint256 graiOut = _mint(alice, usdc, 100e6);

        // first deposit: 1 GRAI == $1 -> 100 GRAI (18 decimals)
        assertEq(graiOut, 100e18);
        assertEq(grai.balanceOf(alice), 100e18);
        assertEq(grai.totalValue(), 100e18);

        // 50/50 split
        assertEq(grai.seniorVault().balance(address(usdc)), 50e6);
        assertEq(grai.juniorVault().balance(address(usdc)), 50e6);
    }

    function test_PausedMintReverts() public {
        vm.prank(admin);
        grai.setPaused(address(usdc), true);

        vm.startPrank(alice);
        usdc.approve(address(grai), 100e6);
        vm.expectRevert(bytes("paused"));
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_SecondMintUsesNav() public {
        _mint(alice, usdc, 100e6); // NAV $100, supply 100
        // bob deposits another 100 USDC at NAV price ($1/GRAI) -> 100 GRAI
        uint256 graiOut = _mint(bob, usdc, 100e6);
        assertEq(graiOut, 100e18);
        assertEq(grai.totalValue(), 200e18);
    }

    function test_MintWethDifferentDecimals() public {
        uint256 graiOut = _mint(alice, weth, 1e18); // 1 WETH @ $2000
        assertEq(graiOut, 2000e18); // $2000
        assertEq(grai.totalValue(), 2000e18);
    }

    function test_AllocateMovesJuniorToCustody() public {
        _mint(alice, usdc, 100e6); // junior holds 50 USDC

        vm.prank(admin);
        grai.allocate(address(usdc), custody, 50e6);

        assertEq(grai.juniorVault().balance(address(usdc)), 0);
        assertEq(usdc.balanceOf(custody), 1_000e6 + 50e6);
        assertEq(grai.allocatedAmount(custody, address(usdc)), 50e6);
    }

    function test_DistributeRaisesNavAndPaysTreasury() public {
        _mint(alice, usdc, 100e6); // NAV $100
        vm.prank(admin);
        grai.allocate(address(usdc), custody, 50e6);

        // custody returns 20 USDC yield, split 80/20
        vm.startPrank(custody);
        usdc.approve(address(grai), 20e6);
        grai.distribute(address(usdc), 20e6);
        vm.stopPrank();

        // 16 -> senior (NAV +$16), 4 -> treasury
        assertEq(usdc.balanceOf(treasury), 4e6);
        assertEq(grai.totalValue(), 116e18);

        assertEq(grai.seniorVault().balance(address(usdc)), 50e6 + 16e6);
    }

    function test_BurnRedeemsSeniorIdleShare() public {
        _mint(alice, usdc, 100e6); // 100 GRAI, NAV $100
        vm.prank(admin);
        grai.allocate(address(usdc), custody, 50e6);

        vm.startPrank(custody);
        usdc.approve(address(grai), 20e6);
        grai.distribute(address(usdc), 20e6); // NAV -> $116, senior idle = 66 USDC
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        grai.burn(100e18);
        vm.stopPrank();

        // redeem = grai/supply * seniorIdle = 100/100 * 66 = 66 USDC
        assertEq(usdc.balanceOf(alice) - before, 66e6);
        assertEq(grai.balanceOf(alice), 0);
        assertEq(grai.totalValue(), 0);
    }

    function test_PartialBurn() public {
        _mint(alice, usdc, 100e6); // 100 GRAI, senior idle 50 USDC
        vm.startPrank(alice);
        grai.burn(40e18);
        vm.stopPrank();

        // redeem = 40/100 * 50 = 20 USDC
        assertEq(grai.balanceOf(alice), 60e18);
        assertEq(grai.totalValue(), 60e18);
    }

    function test_NavViewPricesSeniorIdle() public {
        _mint(alice, usdc, 100e6); // senior idle 50 USDC = $50
        _mint(alice, weth, 1e18); // senior idle 0.5 WETH = $1000
        assertEq(grai.nav(), 50e18 + 1000e18);
    }

    function test_GetVaultsSnapshot() public {
        _mint(alice, usdc, 100e6);
        _assertFirstVaultSnapshot(address(usdc), 50e6, 50e6);
    }

    function test_StalePriceReverts() public {
        // move time forward beyond MAX_STALENESS without refreshing the feed
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(alice);
        usdc.approve(address(grai), 100e6);
        vm.expectRevert(bytes("stale price"));
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_NegativePriceReverts() public {
        usdcFeed.setAnswer(-1);
        vm.startPrank(alice);
        usdc.approve(address(grai), 100e6);
        vm.expectRevert(bytes("bad price"));
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_RemoveAssetSweepsAndDelists() public {
        _mint(alice, usdc, 100e6); // senior 50, junior 50

        vm.startPrank(admin);
        grai.setPaused(address(usdc), true);
        grai.removeAsset(address(usdc), 0);
        vm.stopPrank();

        assertEq(grai.assetCount(), 1);
        // both tranche balances swept to admin
        assertEq(usdc.balanceOf(admin), 100e6);
    }

    function test_MintWithEther() public {
        vm.startPrank(admin);
        oracle.addChainlinkFeed(address(0), address(wethFeed));
        grai.addAsset(address(0), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 graiOut = grai.mint{value: amount}(address(0), amount);

        assertEq(graiOut, 2000e18); // 1 ETH @ $2000
        assertEq(grai.seniorVault().balance(address(0)), amount / 2);
        assertEq(grai.juniorVault().balance(address(0)), amount / 2);
    }

    function test_BurnRedeemsEther() public {
        vm.startPrank(admin);
        oracle.addChainlinkFeed(address(0), address(wethFeed));
        grai.addAsset(address(0), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        grai.mint{value: amount}(address(0), amount);

        uint256 before = alice.balance;
        vm.prank(alice);
        grai.burn(2000e18);

        assertEq(grai.balanceOf(alice), 0);
        assertEq(alice.balance - before, amount / 2); // senior idle half
    }
}
