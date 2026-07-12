// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {SeniorToken} from "../src/SeniorToken.sol";
import {ISeniorToken} from "../src/interfaces/ISeniorToken.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJuniorToken} from "../src/interfaces/IJuniorToken.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";

contract GRAIVaultTest is GRAIFixture {
    function test_AddAssetRegistersAsset() public view {
        assertEq(grai.getVaultsData().length, 2);
        (bool exists,,,,,,) = grai.assets(address(usdc));
        assertTrue(exists);
        assertEq(grai.seniorToken().grai(), address(grai));
        assertEq(grai.juniorToken().grai(), address(grai));
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(IGRAI.AssetExists.selector);
        grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
    }

    function test_FirstMintBootstrapsAtParity() public {
        uint256 depositValue = _mint(alice, usdc, 100e6);

        assertEq(depositValue, 100e6);
        assertEq(grai.balanceOf(alice), 0);
        assertEq(grai.totalValue(), 100e6);

        // 50/50 split
        assertEq(grai.seniorToken().balance(address(usdc)), 50e6);
        assertEq(grai.juniorToken().balance(address(usdc)), 50e6);

        ISeniorToken senior = grai.seniorToken();
        IJuniorToken junior = grai.juniorToken();
        assertEq(senior.balanceOf(alice), 50e6);
        assertEq(senior.totalValue(), 50e6);
        assertEq(senior.totalSupply(), 50e6);
        assertEq(junior.balanceOf(alice), 50e6);
        assertEq(junior.totalValue(), 50e6);
        assertEq(junior.totalSupply(), 50e6);
    }

    function test_PausedMintReverts() public {
        vm.prank(admin);
        grai.setPaused(address(usdc), true);

        vm.startPrank(alice);
        usdc.approve(address(grai), 100e6);
        vm.expectRevert(IGRAI.MintingPaused.selector);
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_SecondMintUsesNav() public {
        _mint(alice, usdc, 100e6);
        uint256 depositValue = _mint(bob, usdc, 100e6);
        assertEq(depositValue, 100e6);
        assertEq(grai.totalValue(), 200e6);
        assertEq(grai.seniorToken().balanceOf(bob), 50e6);
    }

    function test_MintWethDifferentDecimals() public {
        uint256 graiOut = _mint(alice, weth, 1e18); // 1 WETH @ $2000
        assertEq(graiOut, 2000e6); // $2000
        assertEq(grai.totalValue(), 2000e6);
    }

    function test_AllocateMovesJuniorToCustody() public {
        _mint(alice, usdc, 100e6); // junior holds 50 USDC

        _allocate(address(usdc), custodian, 50e6);

        assertEq(grai.juniorToken().balance(address(usdc)), 0);
        assertEq(usdc.balanceOf(custodian), 1_000e6 + 50e6);
        assertEq(juniorTokenNft.allocatedAmount(custodian, address(usdc)), 50e6);
    }

    function test_Allocate_revertsUnknownCustodian() public {
        _mint(alice, usdc, 100e6);

        address unknown = makeAddr("unknownCustody");
        vm.prank(admin);
        vm.expectRevert(IJuniorToken.UnknownCustodian.selector);
        juniorTokenNft.allocate(address(usdc), unknown, 50e6);
    }

    function test_DeallocateReturnsPrincipalToJuniorReserve() public {
        _mint(alice, usdc, 100e6);

        _allocate(address(usdc), custodian, 50e6);

        uint256 reserveBefore = grai.juniorToken().balance(address(usdc));
        uint256 seniorBefore = grai.seniorToken().balance(address(usdc));
        uint256 custodianBefore = usdc.balanceOf(custodian);

        vm.startPrank(custodian);
        usdc.approve(address(juniorTokenNft), 30e6);
        juniorTokenNft.deallocate(address(usdc), 30e6);
        vm.stopPrank();

        assertEq(juniorTokenNft.allocatedAmount(custodian, address(usdc)), 20e6);
        assertEq(juniorTokenNft.activeAmount(address(usdc)), 20e6);
        assertEq(grai.juniorToken().balance(address(usdc)), reserveBefore + 30e6);
        assertEq(grai.seniorToken().balance(address(usdc)), seniorBefore);
        assertEq(usdc.balanceOf(custodian), custodianBefore - 30e6);
    }

    function test_DeallocateZerosLedgerWhenExceedsAllocation() public {
        _mint(alice, usdc, 100e6);

        _allocate(address(usdc), custodian, 50e6);

        vm.startPrank(custodian);
        usdc.approve(address(juniorTokenNft), 60e6);
        juniorTokenNft.deallocate(address(usdc), 60e6);
        vm.stopPrank();

        assertEq(juniorTokenNft.allocatedAmount(custodian, address(usdc)), 0);
        assertEq(juniorTokenNft.activeAmount(address(usdc)), 0);
    }

    function test_DistributeRaisesNavAndPaysTreasury() public {
        _mint(alice, usdc, 100e6); // NAV $100
        _allocate(address(usdc), custodian, 50e6);

        // custodian returns 20 USDC yield, split 80/20
        vm.startPrank(custodian);
        usdc.approve(address(grai), 20e6);
        grai.distribute(address(usdc), 20e6);
        vm.stopPrank();

        // 16 -> senior (NAV +$16), 4 -> protocol owner
        assertEq(usdc.balanceOf(admin), 4e6);
        assertEq(usdc.balanceOf(juniorToken), 0);
        assertEq(grai.totalValue(), 116e6);

        ISeniorToken senior = grai.seniorToken();
        assertEq(senior.totalSupply(), 50e6);
        assertEq(senior.totalValue(), 66e6);

        assertEq(grai.seniorToken().balance(address(usdc)), 50e6 + 16e6);
    }

    function test_BurnRedeemsSeniorIdleShare() public {
        _mint(alice, usdc, 100e6);
        _allocate(address(usdc), custodian, 50e6);

        vm.startPrank(custodian);
        usdc.approve(address(grai), 20e6);
        grai.distribute(address(usdc), 20e6);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        grai.burn(50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - before, 66e6);
        assertEq(grai.seniorToken().balanceOf(alice), 0);
        assertEq(grai.totalValue(), 50e6);
    }

    function test_PartialBurn() public {
        _mint(alice, usdc, 100e6);
        vm.startPrank(alice);
        grai.burn(40e6);
        vm.stopPrank();

        assertEq(grai.seniorToken().balanceOf(alice), 10e6);
        assertEq(grai.totalValue(), 60e6);
    }

    function test_NavViewPricesSeniorIdle() public {
        _mint(alice, usdc, 100e6); // senior idle 50 USDC = $50
        _mint(alice, weth, 1e18); // senior idle 0.5 WETH = $1000
        IGRAI.VaultSnapshot[] memory vaults = grai.getVaultsData();
        uint256 total;
        for (uint256 i; i < vaults.length; ++i) {
            if (vaults[i].seniorBalance > 0) {
                total += grai.usdValue(vaults[i].asset, vaults[i].seniorBalance);
            }
        }
        assertEq(total, 50e6 + 1000e6);
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
        vm.expectRevert(IPriceOracleRouter.StalePrice.selector);
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_NegativePriceReverts() public {
        usdcFeed.setAnswer(-1);
        vm.startPrank(alice);
        usdc.approve(address(grai), 100e6);
        vm.expectRevert(IPriceOracleRouter.BadPrice.selector);
        grai.mint(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_RemoveAssetSweepsAndDelists() public {
        _mint(alice, usdc, 100e6); // senior 50, junior 50

        vm.startPrank(admin);
        grai.setPaused(address(usdc), true);
        grai.removeAsset(address(usdc), 0);
        vm.stopPrank();

        assertEq(grai.getVaultsData().length, 1);
        assertEq(usdc.balanceOf(admin), 100e6);
        assertEq(grai.juniorToken().balance(address(usdc)), 0);
        assertEq(grai.totalValue(), 0);
        assertEq(grai.seniorToken().totalValue(), 0);
        assertEq(grai.juniorToken().totalValue(), 0);
        assertEq(grai.totalValue(), grai.seniorToken().totalValue() + grai.juniorToken().totalValue());
    }

    function test_MintWithEther() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        grai.addAsset(address(0), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 depositValue = grai.mint{value: amount}(address(0), amount);

        assertEq(depositValue, 2000e6);
        assertEq(grai.seniorToken().balance(address(0)), amount / 2);
        assertEq(grai.juniorToken().balance(address(0)), amount / 2);
    }

    function test_BurnRedeemsEther() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        grai.addAsset(address(0), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        grai.mint{value: amount}(address(0), amount);

        uint256 before = alice.balance;
        vm.prank(alice);
        grai.burn(1000e6);

        assertEq(grai.seniorToken().balanceOf(alice), 0);
        assertEq(alice.balance - before, amount / 2); // senior idle half
    }

    function test_UpgradePreservesState() public {
        _mint(alice, usdc, 100e6);

        uint256 seniorBefore = grai.seniorToken().balance(address(usdc));
        uint256 juniorBefore = grai.juniorToken().balance(address(usdc));

        SeniorToken implV2 = new SeniorToken();
        ISeniorToken senior = grai.seniorToken();
        vm.prank(admin);
        SeniorToken(payable(address(senior))).upgradeToAndCall(address(implV2), "");

        assertEq(grai.seniorToken().grai(), address(grai));
        assertEq(grai.seniorToken().balance(address(usdc)), seniorBefore);
        assertEq(grai.juniorToken().balance(address(usdc)), juniorBefore);
    }
}
