// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";

contract GRAIVaultTest is GRAIFixture {
    function test_AddAssetRegistersAsset() public view {
        (bool usdcExists,,) = graiToken.assets(address(usdc));
        (bool wethExists,,) = graiToken.assets(address(weth));
        assertTrue(usdcExists);
        assertTrue(wethExists);
        assertTrue(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(grai)));
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(IGRAI.AssetExists.selector);
        graiToken.addAsset(address(usdc), DEFAULT_YIELD_SPLIT);
    }

    function test_FirstMintBootstrapsAtParity() public {
        uint256 depositValue = _mint(alice, usdc, 100e6);

        assertEq(depositValue, 100e6);
        assertEq(grai.grai().balance(address(usdc)), 100e6);
        assertEq(grai.balance(address(usdc)), 0);

        IGRAI token = grai.grai();
        assertEq(token.balanceOf(alice), 100e6);
        assertEq(token.totalNAV(), 100e6);
        assertEq(token.totalSupply(), 100e6);
    }

    function test_PausedMintReverts() public {
        vm.prank(admin);
        graiToken.setPaused(address(usdc), true);

        vm.startPrank(alice);
        usdc.approve(address(graiToken), 100e6);
        vm.expectRevert(IGrinders.MintingPaused.selector);
        graiToken.deposit(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_SecondMintUsesNav() public {
        _mint(alice, usdc, 100e6);
        uint256 depositValue = _mint(bob, usdc, 100e6);
        assertEq(depositValue, 100e6);
        assertEq(grai.grai().totalNAV(), 200e6);
        assertEq(grai.grai().balanceOf(bob), 100e6);
    }

    function test_MintWethDifferentDecimals() public {
        uint256 graiOut = _mint(alice, weth, 1e18); // 1 WETH @ $2000
        assertEq(graiOut, 2000e6);
        assertEq(grai.grai().totalNAV(), 2000e6);
    }

    function test_AllocateMovesJuniorToCustody() public {
        _mint(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);

        _allocate(address(usdc), custodian, 50e6);

        assertEq(grai.balance(address(usdc)), 0);
        assertEq(usdc.balanceOf(custodian), 1_000e6 + 50e6);
        assertEq(grai.allocated(custodian, address(usdc)), 50e6);
    }

    function test_Allocate_revertsUnknownCustodian() public {
        _fundGrinders(usdc, 50e6);

        address unknown = makeAddr("unknownCustody");
        vm.prank(admin);
        vm.expectRevert(IGrinders.UnknownCustodian.selector);
        grai.allocate(unknown, address(usdc), 50e6);
    }

    function test_DeallocateReturnsPrincipalToJuniorReserve() public {
        _fundGrinders(usdc, 50e6);
        _allocate(address(usdc), custodian, 50e6);

        uint256 reserveBefore = grai.balance(address(usdc));
        uint256 seniorBefore = grai.grai().balance(address(usdc));
        uint256 custodianBefore = usdc.balanceOf(custodian);

        vm.startPrank(custodian);
        usdc.approve(address(grai), 30e6);
        grai.deallocate(address(usdc), 30e6);
        vm.stopPrank();

        assertEq(grai.allocated(custodian, address(usdc)), 20e6);
        assertEq(grai.active(address(usdc)), 20e6);
        assertEq(grai.balance(address(usdc)), reserveBefore + 30e6);
        assertEq(grai.grai().balance(address(usdc)), seniorBefore);
        assertEq(usdc.balanceOf(custodian), custodianBefore - 30e6);
    }

    function test_DeallocateZerosLedgerWhenExceedsAllocation() public {
        _fundGrinders(usdc, 50e6);
        _allocate(address(usdc), custodian, 50e6);

        vm.startPrank(custodian);
        usdc.approve(address(grai), 60e6);
        grai.deallocate(address(usdc), 60e6);
        vm.stopPrank();

        assertEq(grai.allocated(custodian, address(usdc)), 0);
        assertEq(grai.active(address(usdc)), 0);
    }

    function test_DistributeRaisesNavAndPaysTreasury() public {
        _mint(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);
        _allocate(address(usdc), custodian, 50e6);

        vm.startPrank(custodian);
        usdc.approve(address(grai.grai()), 20e6);
        grai.grai().distribute(address(usdc), 20e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(admin), 4e6);
        assertEq(grai.balance(address(usdc)), 0);

        IGRAI token = grai.grai();
        assertEq(token.totalSupply(), 100e6);
        assertEq(token.totalNAV(), 116e6);
        assertEq(grai.grai().balance(address(usdc)), 116e6);
    }

    function test_BurnRedeemsSeniorIdleShare() public {
        _mint(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);
        _allocate(address(usdc), custodian, 50e6);

        vm.startPrank(custodian);
        usdc.approve(address(grai.grai()), 20e6);
        grai.grai().distribute(address(usdc), 20e6);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        _redeem(alice, 100e6);

        assertEq(usdc.balanceOf(alice) - before, 116e6);
        assertEq(grai.grai().balanceOf(alice), 0);
        assertEq(grai.grai().totalNAV(), 0);
    }

    function test_PartialBurn() public {
        _mint(alice, usdc, 100e6);
        _redeem(alice, 40e6);

        assertEq(grai.grai().balanceOf(alice), 60e6);
        assertEq(grai.grai().totalNAV(), 60e6);
    }

    function test_NavViewPricesSeniorIdle() public {
        _mint(alice, usdc, 100e6);
        _mint(alice, weth, 1e18);
        assertEq(grai.grai().balance(address(usdc)), 100e6);
        assertEq(grai.grai().balance(address(weth)), 1e18);
        assertEq(graiToken.usdValue(address(usdc), grai.grai().balance(address(usdc))), 100e6);
        assertEq(graiToken.usdValue(address(weth), grai.grai().balance(address(weth))), 2000e6);
    }

    function test_GetVaultsSnapshot() public {
        _mint(alice, usdc, 100e6);
        _assertFirstVaultSnapshot(address(usdc), 100e6, 0);
    }

    function test_StalePriceReverts() public {
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(alice);
        usdc.approve(address(graiToken), 100e6);
        vm.expectRevert(IPriceOracleRouter.StalePrice.selector);
        graiToken.deposit(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_NegativePriceReverts() public {
        usdcFeed.setAnswer(-1);
        vm.startPrank(alice);
        usdc.approve(address(graiToken), 100e6);
        vm.expectRevert(IPriceOracleRouter.BadPrice.selector);
        graiToken.deposit(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_RemoveAssetSweepsAndDelists() public {
        _mint(alice, usdc, 100e6);

        vm.startPrank(admin);
        graiToken.setPaused(address(usdc), true);
        graiToken.removeAsset(address(usdc), 0);
        vm.stopPrank();

        (bool usdcExists,,) = graiToken.assets(address(usdc));
        (bool wethExists,,) = graiToken.assets(address(weth));
        assertFalse(usdcExists);
        assertTrue(wethExists);
        assertEq(usdc.balanceOf(admin), 100e6);
        assertEq(grai.balance(address(usdc)), 0);
        assertEq(grai.grai().totalNAV(), 0);
    }

    function test_MintWithEther() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 depositValue = graiToken.deposit{value: amount}(address(0), amount);

        assertEq(depositValue, 2000e6);
        assertEq(grai.grai().balance(address(0)), amount);
        assertEq(grai.balance(address(0)), 0);
    }

    function test_BurnRedeemsEther() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        graiToken.deposit{value: amount}(address(0), amount);

        uint256 before = alice.balance;
        _redeem(alice, 2000e6);

        assertEq(grai.grai().balanceOf(alice), 0);
        assertEq(alice.balance - before, amount);
    }

    function test_FlatAskFills() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 payment = 50e6;
        uint256 duration = 1 days;
        uint256 tax = graiToken.harbergerTax(50e6, duration);
        uint256 treasuryBefore = graiToken.balanceOf(admin);

        vm.prank(alice);
        uint256 auctionId = graiToken.ask(address(usdc), payment, payment, duration, 50e6);

        assertEq(graiToken.auctionIds(0), auctionId);
        assertEq(graiToken.balanceOf(admin) - treasuryBefore, tax);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), payment);
        graiToken.bid(auctionId, 50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, payment);
        assertEq(graiToken.balanceOf(alice), 50e6 - tax);
        assertEq(graiToken.balanceOf(bob), 50e6);
        (address seller,,,,,,,,)= graiToken.auctions(auctionId);
        assertEq(seller, address(0));
        vm.expectRevert();
        graiToken.auctionIds(0);
    }

    function test_DutchAskFillsAtFloor() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 maxPayment = 50e6;
        uint256 minPayment = (maxPayment * 95) / 100;
        uint256 duration = 1 days;
        uint256 tax = graiToken.harbergerTax(50e6, duration);

        vm.prank(alice);
        uint256 auctionId = graiToken.ask(address(usdc), maxPayment, minPayment, duration, 50e6);

        vm.warp(block.timestamp + duration);
        assertEq(graiToken.auctionPrice(auctionId), minPayment);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), minPayment);
        graiToken.bid(auctionId, 50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, minPayment);
        assertEq(graiToken.balanceOf(alice), 50e6 - tax);
        assertEq(graiToken.balanceOf(bob), 50e6);
    }

    function test_FlatAskPartialFill() public {
        _mint(alice, usdc, 101e6);
        usdc.mint(bob, 100e6);

        uint256 payment = 100e6;
        uint256 duration = 1 days;
        uint256 tax = graiToken.harbergerTax(100e6, duration);

        vm.prank(alice);
        uint256 auctionId = graiToken.ask(address(usdc), payment, payment, duration, 100e6);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), 100e6);
        graiToken.bid(auctionId, 50e6);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(bob), 50e6);
        assertEq(graiToken.balanceOf(alice), 101e6 - tax - 50e6);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 50e6);
        (,, uint256 remaining,,,,,,) = graiToken.auctions(auctionId);
        assertEq(remaining, 50e6);

        vm.prank(bob);
        graiToken.bid(auctionId, 50e6);

        assertEq(graiToken.balanceOf(bob), 100e6);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 100e6);
        (address seller,,,,,,,,)= graiToken.auctions(auctionId);
        assertEq(seller, address(0));
    }

    function test_CancelAfterDuration() public {
        _mint(alice, usdc, 101e6);
        usdc.mint(bob, 100e6);

        uint256 duration = 1 days;
        uint256 tax = graiToken.harbergerTax(100e6, duration);

        vm.prank(alice);
        uint256 auctionId = graiToken.ask(address(usdc), 100e6, 100e6, duration, 100e6);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), 50e6);
        graiToken.bid(auctionId, 50e6);
        vm.stopPrank();

        vm.expectRevert(IGRAI.AuctionNotExpired.selector);
        vm.prank(alice);
        graiToken.bid(auctionId, 0);

        vm.warp(block.timestamp + duration);

        vm.expectRevert(IGRAI.NotSeller.selector);
        vm.prank(bob);
        graiToken.bid(auctionId, 0);

        vm.prank(alice);
        graiToken.bid(auctionId, 0);

        assertEq(graiToken.balanceOf(alice), 101e6 - tax - 50e6);
        (address seller,,,,,,,,)= graiToken.auctions(auctionId);
        assertEq(seller, address(0));
    }

    function test_AuctionListSwapPop() public {
        _mint(alice, usdc, 200e6);
        usdc.mint(bob, 200e6);

        uint256 duration = 1 days;
        vm.startPrank(alice);
        uint256 id1 = graiToken.ask(address(usdc), 50e6, 50e6, duration, 50e6);
        uint256 id2 = graiToken.ask(address(usdc), 50e6, 50e6, duration, 50e6);
        vm.stopPrank();
        assertEq(graiToken.auctionIds(0), id1);
        assertEq(graiToken.auctionIds(1), id2);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), 50e6);
        graiToken.bid(id1, type(uint256).max);
        vm.stopPrank();

        assertEq(graiToken.auctionIds(0), id2);
        vm.expectRevert();
        graiToken.auctionIds(1);
    }

    function test_UpgradePreservesState() public {
        _mint(alice, usdc, 100e6);

        uint256 seniorBefore = grai.grai().balance(address(usdc));
        uint256 juniorBefore = grai.balance(address(usdc));

        GRAI implV2 = new GRAI();
        IGRAI token = grai.grai();
        vm.prank(admin);
        GRAI(payable(address(token))).upgradeToAndCall(address(implV2), "");

        assertTrue(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(grai)));
        assertEq(grai.grai().balance(address(usdc)), seniorBefore);
        assertEq(grai.balance(address(usdc)), juniorBefore);
    }
}
