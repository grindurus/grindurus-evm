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

    function test_DutchRedemptionDiscountAtFloor() public {
        _mint(alice, usdc, 100e6);

        vm.startPrank(alice);
        uint256 auctionId = graiToken.place(address(usdc), 50e6);
        vm.stopPrank();

        uint256 startPrice = graiToken.mintPrice();
        uint256 floorPrice = (startPrice * (BPS - graiToken.AUCTION_DISCOUNT_BPS())) / BPS;

        vm.warp(block.timestamp + graiToken.AUCTION_DURATION());
        usdcFeed.setAnswer(1e8);
        assertEq(graiToken.auctionPrice(auctionId), floorPrice);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        graiToken.bid(auctionId);

        assertEq(usdc.balanceOf(alice) - before, (50e6 * 95) / 100);
        assertEq(graiToken.balanceOf(alice), 50e6);
        assertEq(graiToken.totalValue(), 52_500_000);
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
