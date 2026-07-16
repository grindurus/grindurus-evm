// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract GRAIVaultTest is GRAIFixture {
    function test_AddAssetRegistersAsset() public view {
        (uint16 usdcSplit,, uint32 usdcId) = graiToken.assets(address(usdc));
        (uint16 wethSplit,, uint32 wethId) = graiToken.assets(address(weth));
        assertEq(usdcSplit, DEFAULT_YIELD_SPLIT);
        assertEq(wethSplit, DEFAULT_YIELD_SPLIT);
        assertEq(usdcId, 0);
        assertEq(wethId, 1);
        assertEq(graiToken.assetList(usdcId), address(usdc));
        assertEq(graiToken.assetList(wethId), address(weth));
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
        assertEq(token.seniorNAV(), 100e6);
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
        assertEq(grai.grai().seniorNAV(), 200e6);
        assertEq(grai.grai().balanceOf(bob), 100e6);
    }

    function test_MintWethDifferentDecimals() public {
        uint256 graiOut = _mint(alice, weth, 1e18); // 1 WETH @ $2000
        assertEq(graiOut, 2000e6);
        assertEq(grai.grai().seniorNAV(), 2000e6);
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
        assertEq(token.seniorNAV(), 116e6);
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
        assertEq(grai.grai().seniorNAV(), 0);
    }

    function test_PartialBurn() public {
        _mint(alice, usdc, 100e6);
        _redeem(alice, 40e6);

        assertEq(grai.grai().balanceOf(alice), 60e6);
        assertEq(grai.grai().seniorNAV(), 60e6);
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

    function test_RemoveAssetRequiresZeroBalance() public {
        _mint(alice, usdc, 100e6);

        vm.startPrank(admin);
        graiToken.setPaused(address(usdc), true);
        vm.expectRevert(IGRAI.AssetBalanceNonZero.selector);
        graiToken.removeAsset(address(usdc), 0);
        vm.stopPrank();

        _redeem(alice, graiToken.balanceOf(alice));

        vm.startPrank(admin);
        graiToken.removeAsset(address(usdc), 0);
        vm.stopPrank();

        (uint16 usdcSplit,,) = graiToken.assets(address(usdc));
        (uint16 wethSplit,, uint32 wethId) = graiToken.assets(address(weth));
        assertEq(usdcSplit, 0);
        assertEq(wethSplit, DEFAULT_YIELD_SPLIT);
        assertEq(wethId, 0);
        assertEq(graiToken.assetList(0), address(weth));
        assertEq(grai.grai().balance(address(usdc)), 0);
        assertEq(grai.grai().seniorNAV(), 0);
    }

    function test_MintWithEther() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        (, uint256 depositValue) = graiToken.deposit{value: amount}(address(0), amount);

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

    // --- Scenario cases (current: distribute→book, maxRedeem by idle NAV) ---

    /// 1. Deposit 100 USDC + 1 ETH → full redeem returns both.
    function test_Scenario_RedeemReturnsUsdcAndEth() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        _mint(alice, usdc, 100e6);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2100e6);
        assertEq(graiToken.maxRedeem(), 2100e6);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(usdc.balanceOf(alice) - usdcBefore, 100e6);
        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.balanceOf(alice), 0);
    }

    /// 2. Take half to Grinders → maxRedeem = idle NAV ($1050), not sticky book ($2100).
    function test_Scenario_MaxRedeemAfterPartialTake() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        _mint(alice, usdc, 100e6);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        vm.startPrank(address(grai));
        graiToken.take(address(usdc), address(grai), 50e6);
        graiToken.take(address(0), address(grai), 0.5 ether);
        vm.stopPrank();

        assertEq(graiToken.totalValue(), 2100e6);
        assertEq(graiToken.seniorNAV(), 1050e6);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, 1e6);
        assertEq(graiToken.maxRedeem(), 1050e6);
    }

    /// 3. Take all USDC → idle NAV 0 → maxRedeem 0.
    function test_Scenario_MaxRedeemZeroAfterFullTake() public {
        _mint(alice, usdc, 100e6);
        vm.prank(address(grai));
        graiToken.take(address(usdc), address(grai), 100e6);

        assertEq(graiToken.totalValue(), 100e6);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// Deposit 1 ETH → take all → price $1500 → Grinders `put` 1 ETH → maxRedeem by idle NAV.
    function test_Scenario_MaxRedeemAfterGrindersPutEth() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        // after deposit @ $2000
        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        vm.prank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);

        // all idle with Grinders
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.used(address(0)), 1 ether);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        wethFeed.setAnswer(1500e8);
        // still no idle in vault
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // Grinders returns the 1 ETH
        vm.prank(address(grai));
        graiToken.put{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.used(address(0)), 0);
        // sticky book untouched; idle NAV = 1 ETH @ $1500
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 1500e6);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, 1e6);
        assertEq(graiToken.maxRedeem(), 1500e6);

        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        // maxRedeem drains full seniorBalance; 500 GRAI left against empty idle
        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balanceOf(alice), 500e6);
        assertEq(graiToken.totalValue(), 500e6);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// Deposit 1 ETH at $1000 + 1000 USDC → take all → ETH $1000 to $500 → put all → redeem(maxRedeem).
    /// Caps idle exit at mark NAV ($1500) but drains full idle basket; 500 GRAI residual on sticky book.
    function test_Scenario_MaxRedeem_EthUsdc_TakePut_PriceHalf() public {
        vm.startPrank(admin);
        wethFeed.setAnswer(1000e8);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // 1) deposit 1 ETH @ $1000 + 1000 USDC
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);
        assertEq(graiToken.totalValue(), 1000e6);
        assertEq(graiToken.seniorNAV(), 1000e6);

        _mint(alice, usdc, 1000e6);
        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(graiToken.balance(address(usdc)), 1000e6);

        // 2) grinder take all
        vm.startPrank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);
        graiToken.take(address(usdc), address(grai), 1000e6);
        vm.stopPrank();

        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(usdc.balanceOf(address(grai)), 1000e6);
        assertEq(graiToken.used(address(0)), 1 ether);
        assertEq(graiToken.used(address(usdc)), 1000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 3) ETH $1000 → $500 (still no idle)
        wethFeed.setAnswer(500e8);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);
        assertEq(graiToken.totalValue(), 2000e6);

        // 4) grinder put all
        vm.startPrank(address(grai));
        graiToken.put{value: 1 ether}(address(0), 1 ether);
        usdc.approve(address(graiToken), 1000e6);
        graiToken.put(address(usdc), 1000e6);
        vm.stopPrank();

        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(graiToken.balance(address(usdc)), 1000e6);
        assertEq(graiToken.used(address(0)), 0);
        assertEq(graiToken.used(address(usdc)), 0);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 1500e6); // 1 ETH@$500 + 1000 USDC
        assertEq(graiToken.maxRedeem(), 1500e6);

        // 5) redeem(maxRedeem) — drains full idle, burns only NAV-capped GRAI
        uint256 ethBefore = alice.balance;
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 cap = graiToken.maxRedeem();
        assertEq(cap, 1500e6);
        _redeem(alice, cap);

        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 1000e6);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balanceOf(alice), 500e6);
        assertEq(graiToken.totalValue(), 500e6);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// Deposit 1 ETH → take → price stays $2000 → Grinders `put` 1 ETH → full redeem.
    function test_Scenario_RedeemAfterGrindersPutEthAtParity() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // 1. deposit 1 ETH @ $2000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        // 2. take
        vm.prank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);

        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.used(address(0)), 1 ether);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 3. price → $2000 (parity with mint book)
        wethFeed.setAnswer(2000e8);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 4. Grinders put 1 ETH
        vm.prank(address(grai));
        graiToken.put{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.used(address(0)), 0);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, 1e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        // 5. redeem(maxRedeem())
        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balanceOf(alice), 0);
        assertEq(graiToken.totalValue(), 0);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// Deposit 1 ETH → take → price $2500 → Grinders `put` 1 ETH → full redeem (NAV > book).
    function test_Scenario_RedeemAfterGrindersPutEthPriceUp() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // 1. deposit 1 ETH @ $2000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);
        assertEq(alice.balance, 0);
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);

        // 2. take all
        vm.prank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(alice.balance, 0);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.used(address(0)), 1 ether);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 3. price → $2500
        wethFeed.setAnswer(2500e8);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 4. Grinders put 1 ETH
        vm.prank(address(grai));
        graiToken.put{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(alice.balance, 0);
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.used(address(0)), 0);
        // sticky book $2000; idle NAV = 1 ETH @ $2500 = $2500 → full exit allowed
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.seniorNAV(), 2500e6);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, 1e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        // 5. redeem(maxRedeem)
        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.balanceOf(alice), 0);
        assertEq(graiToken.totalValue(), 0);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// Shared: deposit at mintEthUsd → take → price → distribute 0.1 → redeem(max) → put 1 ETH → redeem(max).
    /// Senior yield split 80% → vault idle 0.08 ETH; Grinders keep the 1 ETH principal until put.
    function _scenarioTakeDistributeRedeemPutRedeem(
        int256 mintEthUsd,
        uint256 expectedMintGrai,
        int256 ethUsd,
        uint256 expectedNav,
        uint256 expectedTv,
        uint256 expectedMintPrice,
        uint256 expectedMaxRedeem1,
        uint256 expectedGraiAfter1,
        uint256 expectedMaxRedeem2,
        uint256 expectedGraiAfter2
    ) internal {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // 1. deposit 1 ETH @ mintEthUsd
        wethFeed.setAnswer(mintEthUsd);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), expectedMintGrai);
        assertEq(graiToken.totalValue(), expectedMintGrai);
        assertEq(alice.balance, 0);
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);

        // 2. take all
        vm.prank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);
        assertEq(graiToken.balanceOf(alice), expectedMintGrai);
        assertEq(alice.balance, 0);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.maxRedeem(), 0);

        // 3. price move
        wethFeed.setAnswer(ethUsd);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // 4. distribute 0.1 ETH (80% senior = 0.08 idle)
        uint256 treasuryBefore = admin.balance;
        vm.deal(custodian, 0.1 ether);
        vm.prank(custodian);
        graiToken.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        assertEq(graiToken.balance(address(0)), 0.08 ether);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(admin.balance - treasuryBefore, 0.02 ether);
        assertEq(graiToken.seniorNAV(), expectedNav);
        assertEq(graiToken.totalValue(), expectedTv);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, expectedMintPrice);
        assertEq(graiToken.maxRedeem(), expectedMaxRedeem1);
        assertEq(graiToken.balanceOf(alice), expectedMintGrai);
        assertEq(alice.balance, 0);

        // 5. redeem(maxRedeem) → drains all 0.08 ETH idle
        uint256 ethBefore1 = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore1, 0.08 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.balanceOf(alice), expectedGraiAfter1);
        assertEq(graiToken.maxRedeem(), 0);

        // 6. Grinders put 1 ETH principal back
        vm.prank(address(grai));
        graiToken.put{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.used(address(0)), 0);
        assertEq(graiToken.balanceOf(alice), expectedGraiAfter1);
        assertEq(alice.balance, 0.08 ether);
        assertEq(graiToken.maxRedeem(), expectedMaxRedeem2);

        // 7. redeem(maxRedeem) → drains the returned 1 ETH
        uint256 ethBefore2 = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore2, 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 0);
        assertEq(graiToken.balanceOf(alice), expectedGraiAfter2);
        assertEq(graiToken.maxRedeem(), 0);
        assertEq(alice.balance, 1.08 ether);
    }

    function test_Scenario_TakeDistributeRedeem_Price2500() public {
        // mint @ $2000; yield @ $2500 → full exit after put
        _scenarioTakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 2500e8, 200e6, 2200e6, 1_100_000, 181_818_182, 1_818_181_818, 1_818_181_818, 0
        );
    }

    function test_Scenario_TakeDistributeRedeem_Price2000() public {
        // mint @ $2000; yield @ $2000 → full exit after put
        _scenarioTakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 2000e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 1_851_851_851, 0
        );
    }

    function test_Scenario_TakeDistributeRedeem_Price1500() public {
        // mint @ $2000; yield @ $1500 → leave ~471.70 GRAI after put+redeem
        _scenarioTakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 1500e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 1_415_094_339, 471_698_113
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price500() public {
        // mint @ $1000; spot $500 → after put leave ~480.77 GRAI
        _scenarioTakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 500e8, 40e6, 1040e6, 1_040_000, 38_461_539, 961_538_461, 480_769_231, 480_769_230
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price1000() public {
        // mint @ $1000; spot $1000 → full exit after put
        _scenarioTakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 1000e8, 80e6, 1080e6, 1_080_000, 74_074_074, 925_925_926, 925_925_925, 1
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price1500() public {
        // mint @ $1000; spot $1500 → full exit after put (NAV > remaining book)
        _scenarioTakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 1500e8, 120e6, 1120e6, 1_120_000, 107_142_858, 892_857_142, 892_857_142, 0
        );
    }

    /// ETH+USDC: deposit → take → price → distribute → redeem → put basket → redeem.
    function _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
        int256 ethUsd,
        uint256 expectedNavAfterDist,
        uint256 expectedTvAfterDist,
        uint256 expectedMintPriceAfterDist,
        uint256 expectedMax1,
        uint256 expectedGraiAfter1,
        uint256 putEth,
        uint256 putUsdc,
        uint256 expectedMax2,
        uint256 expectedGraiAfter2
    ) internal {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // 1. deposit 1 ETH @ $1000 + 1000 USDC → 2000 GRAI
        wethFeed.setAnswer(1000e8);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        _mint(alice, usdc, 1000e6);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(alice.balance, 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(graiToken.balance(address(usdc)), 1000e6);

        // 2. take all
        vm.startPrank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);
        graiToken.take(address(usdc), address(grai), 1000e6);
        vm.stopPrank();

        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(usdc.balanceOf(address(grai)), 1000e6);
        assertEq(graiToken.maxRedeem(), 0);

        // 3. ETH price move
        wethFeed.setAnswer(ethUsd);

        // 4. distribute 0.1 ETH + 50 USDC (senior 80% → 0.08 ETH + 40 USDC)
        uint256 treasuryEthBefore = admin.balance;
        uint256 treasuryUsdcBefore = usdc.balanceOf(admin);
        vm.deal(custodian, 0.1 ether);
        usdc.mint(custodian, 50e6);
        vm.startPrank(custodian);
        graiToken.distribute{value: 0.1 ether}(address(0), 0.1 ether);
        usdc.approve(address(graiToken), 50e6);
        graiToken.distribute(address(usdc), 50e6);
        vm.stopPrank();

        assertEq(admin.balance - treasuryEthBefore, 0.02 ether);
        assertEq(usdc.balanceOf(admin) - treasuryUsdcBefore, 10e6);
        assertEq(graiToken.balance(address(0)), 0.08 ether);
        assertEq(graiToken.balance(address(usdc)), 40e6);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(usdc.balanceOf(address(grai)), 1000e6);
        assertEq(graiToken.seniorNAV(), expectedNavAfterDist);
        assertEq(graiToken.totalValue(), expectedTvAfterDist);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, expectedMintPriceAfterDist);
        assertEq(graiToken.maxRedeem(), expectedMax1);

        // 5. redeem(maxRedeem) → all idle yield basket
        uint256 ethBefore1 = alice.balance;
        uint256 usdcBefore1 = usdc.balanceOf(alice);
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore1, 0.08 ether);
        assertEq(usdc.balanceOf(alice) - usdcBefore1, 40e6);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balanceOf(alice), expectedGraiAfter1);
        assertEq(graiToken.maxRedeem(), 0);

        // 6. Grinders put basket (fund extras beyond taken principal if needed)
        if (putEth > grai.balance(address(0))) {
            vm.deal(address(grai), putEth);
        }
        uint256 gUsdc = usdc.balanceOf(address(grai));
        if (putUsdc > gUsdc) {
            usdc.mint(address(grai), putUsdc - gUsdc);
        }

        vm.startPrank(address(grai));
        if (putUsdc > 0) {
            usdc.approve(address(graiToken), putUsdc);
            graiToken.put(address(usdc), putUsdc);
        }
        if (putEth > 0) {
            graiToken.put{value: putEth}(address(0), putEth);
        }
        vm.stopPrank();

        assertEq(graiToken.balance(address(0)), putEth);
        assertEq(graiToken.balance(address(usdc)), putUsdc);
        assertEq(grai.balance(address(0)), putEth >= 1 ether ? 0 : 1 ether - putEth);
        assertEq(usdc.balanceOf(address(grai)), putUsdc >= 1000e6 ? 0 : 1000e6 - putUsdc);
        assertEq(graiToken.maxRedeem(), expectedMax2);

        // 7. redeem(maxRedeem) → drains put basket
        uint256 ethBefore2 = alice.balance;
        uint256 usdcBefore2 = usdc.balanceOf(alice);
        _redeem(alice, graiToken.maxRedeem());

        assertEq(alice.balance - ethBefore2, putEth);
        assertEq(usdc.balanceOf(alice) - usdcBefore2, putUsdc);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balanceOf(alice), expectedGraiAfter2);
        assertEq(graiToken.maxRedeem(), 0);
        assertEq(alice.balance, 0.08 ether + putEth);
        assertEq(usdc.balanceOf(alice), 40e6 + putUsdc);
    }

    // --- legacy partial put (0.5 ETH + 1500 USDC) ---
    function test_Scenario_EthUsdc_TakeDistributeRedeemPut_Price500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 0.5 ether, 1500e6, 1_682_692_308, 240_384_615
        );
    }

    function test_Scenario_EthUsdc_TakeDistributeRedeemPut_Price1000() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 0.5 ether, 1500e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_TakeDistributeRedeemPut_Price1500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 0.5 ether, 1500e6, 1_851_851_851, 0
        );
    }

    // --- put matrix: (2 ETH,0) / (1 ETH,1000 USDC) / (0,2000 USDC) × price $500/$1000/$1500 ---
    function test_Scenario_EthUsdc_Put2Eth_Price500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 2 ether, 0, 961_538_462, 961_538_461
        );
    }

    function test_Scenario_EthUsdc_Put2Eth_Price1000() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 2 ether, 0, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put2Eth_Price1500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 2 ether, 0, 1_851_851_851, 0
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 1 ether, 1000e6, 1_442_307_693, 480_769_230
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price1000() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 1 ether, 1000e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price1500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 1 ether, 1000e6, 1_851_851_851, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 0, 2000e6, 1_923_076_923, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price1000() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 0, 2000e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price1500() public {
        _scenarioEthUsdcTakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 0, 2000e6, 1_851_851_851, 0
        );
    }

    // 4. ETH price rise 2000 -> 2500: maxRedeem = full supply (NAV > book).
    function test_Scenario_MaxRedeemOnPriceRise() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        wethFeed.setAnswer(2500e8);

        assertEq(graiToken.seniorNAV(), 2500e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());
        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.balanceOf(alice), 0);
    }

    // 5. ETH price drop 2000 -> 1500: maxRedeem capped by NAV; partial exit.
    function test_Scenario_MaxRedeemOnPriceDrop() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        wethFeed.setAnswer(1500e8);

        assertEq(graiToken.seniorNAV(), 1500e6);
        assertEq(graiToken.maxRedeem(), 1500e6);

        uint256 ethBefore = alice.balance;
        _redeem(alice, graiToken.maxRedeem());

        assertEq(graiToken.balanceOf(alice), 500e6);
        // Redeeming maxRedeem claims 100% of idle (cap is the asset-share denominator).
        assertEq(alice.balance - ethBefore, 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.totalValue(), 500e6);
        assertEq(graiToken.maxRedeem(), 0);
    }

    // Deposit 1 ETH @ $2000 → take all → price $1500 → distribute 0.1 ETH.
    // 1st redeem (partial of max): pro-rata idle. 2nd redeem (maxRedeem): drains remaining seniorBalance.
    function test_Scenario_PriceDropThenDistributeEth_MaxRedeemTakesAllIdle() public {
        vm.startPrank(admin);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);

        // All principal to Grinders
        vm.prank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(grai.balance(address(0)), 1 ether);
        assertEq(graiToken.used(address(0)), 1 ether);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        wethFeed.setAnswer(1500e8);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // Distribute 0.1 ETH: senior 80% = 0.08 ETH @ $1500 → +$120 book, idle NAV = $120
        vm.deal(custodian, 0.1 ether);
        vm.prank(custodian);
        graiToken.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        assertEq(graiToken.balance(address(0)), 0.08 ether);
        assertEq(admin.balance, 0.02 ether);
        assertEq(graiToken.totalValue(), 2120e6); // 2000 + 120
        assertEq(graiToken.seniorNAV(), 120e6);
        uint256 supply_ = graiToken.totalSupply();
        uint256 price_ = supply_ == 0 ? 1e6 : (graiToken.totalValue() * 1e6) / supply_;
        assertEq(price_, 1_060_000);

        uint256 max1 = graiToken.maxRedeem();
        assertEq(max1, 113_207_548); // ≈ 120 * 2000 / 2120 GRAI

        // --- 1st redeem: half of maxRedeem → pro-rata share of idle ---
        uint256 half = max1 / 2; // 56_603_774 GRAI
        assertEq(half, 56_603_774);
        uint256 ethBefore1 = alice.balance;
        _redeem(alice, half);

        // receives 0.04 ETH, burns 56.603774 GRAI → balance 1943.396226 GRAI
        assertEq(alice.balance - ethBefore1, 0.04 ether);
        assertEq(graiToken.balanceOf(alice), 1_943_396_226);
        assertEq(graiToken.balance(address(0)), 0.04 ether);
        assertGt(graiToken.maxRedeem(), 0);

        // --- 2nd redeem: full maxRedeem → drains entire remaining seniorBalance ---
        uint256 max2 = graiToken.maxRedeem();
        assertEq(max2, 56_603_774);
        uint256 ethBefore2 = alice.balance;
        _redeem(alice, max2);

        // receives remaining 0.04 ETH, burns 56.603774 GRAI → balance 1886.792452 GRAI
        assertEq(alice.balance - ethBefore2, 0.04 ether);
        assertEq(graiToken.balanceOf(alice), 1_886_792_452);
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// 6. Take + distribute yield → maxRedeem by yield NAV; redeem burns sticky book share.
    function test_Scenario_MaxRedeemAfterTakeAndDistribute() public {
        MockERC20 sol = new MockERC20("Solana", "SOL", 9);
        MockAggregator solFeed = new MockAggregator(8, 100e8); // $100

        vm.startPrank(admin);
        _setChainlinkFeed(address(sol), address(solFeed));
        graiToken.addAsset(address(sol), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        _mint(alice, usdc, 100e6);
        vm.prank(address(grai));
        graiToken.take(address(usdc), address(grai), 100e6);

        usdc.mint(custodian, 10e6);
        sol.mint(custodian, 0.01e9);
        vm.startPrank(custodian);
        usdc.approve(address(graiToken), 10e6);
        graiToken.distribute(address(usdc), 10e6); // senior 8 USDC
        sol.approve(address(graiToken), 0.01e9);
        graiToken.distribute(address(sol), 0.01e9); // senior 0.008 SOL = $0.8
        vm.stopPrank();

        assertEq(graiToken.balance(address(usdc)), 8e6);
        assertEq(graiToken.balance(address(sol)), 8_000_000);
        assertEq(graiToken.totalValue(), 108_800_000); // 100 + 8 + 0.8
        assertEq(graiToken.seniorNAV(), 8_800_000);

        uint256 maxOut = graiToken.maxRedeem();
        // byNav = ((NAV+1)*1e6 - 1) / mintPrice ≈ 8.088e6 (sticky book 108.8)
        assertEq(maxOut, 8_088_236);
        assertLt(maxOut, 100e6);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 solBefore = sol.balanceOf(alice);
        _redeem(alice, maxOut);

        // Redeeming maxOut claims 100% of idle yields.
        assertEq(usdc.balanceOf(alice) - usdcBefore, 8e6);
        assertEq(sol.balanceOf(alice) - solBefore, 8_000_000);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balance(address(sol)), 0);
        assertEq(graiToken.balanceOf(alice), 100e6 - maxOut);
        assertEq(graiToken.totalValue(), 108_800_000 - (maxOut * 108_800_000) / 100e6);
        assertEq(graiToken.maxRedeem(), 0);
    }

    /// 7. User1 leaves yield unclaimed; User2 deposits — pays higher mint price (fewer GRAI).
    function test_Scenario_NewDepositorPaysForUnclaimedYield() public {
        MockERC20 sol = new MockERC20("Solana", "SOL", 9);
        MockAggregator solFeed = new MockAggregator(8, 100e8);

        vm.startPrank(admin);
        _setChainlinkFeed(address(sol), address(solFeed));
        graiToken.addAsset(address(sol), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        _mint(alice, usdc, 100e6);
        vm.prank(address(grai));
        graiToken.take(address(usdc), address(grai), 100e6);

        usdc.mint(custodian, 10e6);
        sol.mint(custodian, 0.01e9);
        vm.startPrank(custodian);
        usdc.approve(address(graiToken), 10e6);
        graiToken.distribute(address(usdc), 10e6);
        sol.approve(address(graiToken), 0.01e9);
        graiToken.distribute(address(sol), 0.01e9);
        vm.stopPrank();

        _mint(bob, usdc, 100e6);
        uint256 bobGrai = graiToken.balanceOf(bob);
        uint256 expectedBob = (uint256(100e6) * uint256(100e6)) / uint256(108_800_000);
        assertEq(bobGrai, expectedBob);
        assertLt(bobGrai, 100e6);
        assertEq(graiToken.balanceOf(alice), 100e6);

        // Protocol-wide NAV gate; balance check still limits each account on redeem
        uint256 byNav = graiToken.maxRedeem();
        assertGt(byNav, 0);
        assertLe(byNav, graiToken.totalSupply());
    }

    function test_FlatAskFills() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 payment = 50e6;
        uint256 duration = 1 days;
        uint256 listAmount = 50e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, payment, payment, duration, listAmount);
        uint256 treasuryBefore = graiToken.balanceOf(admin);

        vm.prank(alice);
        graiToken.ask(address(usdc), payment, payment, duration, listAmount);

        (address askAsset, uint256 remaining,,,, uint256 startTime,,) = graiToken.asks(alice);
        assertEq(askAsset, address(usdc));
        assertEq(remaining, lot);
        assertGt(startTime, 0);
        assertEq(graiToken.balanceOf(admin) - treasuryBefore, tax);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), payment);
        graiToken.fulfillAsk(alice, lot, payment);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, payment);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax - lot);
        assertEq(graiToken.balanceOf(bob), lot);
        (,,,, , uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    function test_DutchAskFillsAtFloor() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 maxPayment = 50e6;
        uint256 minPayment = (maxPayment * 95) / 100;
        uint256 duration = 1 days;
        uint256 listAmount = 50e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, maxPayment, minPayment, duration, listAmount);

        vm.prank(alice);
        graiToken.ask(address(usdc), maxPayment, minPayment, duration, listAmount);

        vm.warp(block.timestamp + duration);
        (, uint256 _payMin) = graiToken.previewFulfillAsk(alice, lot);
        assertEq(_payMin, minPayment);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), minPayment);
        graiToken.fulfillAsk(alice, lot, minPayment);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, minPayment);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax - lot);
        assertEq(graiToken.balanceOf(bob), lot);
    }

    function test_FlatAskPartialFill() public {
        _mint(alice, usdc, 101e6);
        usdc.mint(bob, 100e6);

        uint256 payment = 100e6;
        uint256 duration = 1 days;
        uint256 listAmount = 100e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, payment, payment, duration, listAmount);
        uint256 buy1 = lot / 2;
        uint256 buy2 = lot - buy1;

        vm.prank(alice);
        graiToken.ask(address(usdc), payment, payment, duration, listAmount);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 pay1 = (payment * buy1) / lot;

        vm.startPrank(bob);
        usdc.approve(address(graiToken), payment);
        graiToken.fulfillAsk(alice, buy1, pay1);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(bob), buy1);
        assertEq(graiToken.balanceOf(alice), 101e6 - tax - buy1);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, pay1);
        (, uint256 remaining,,,,,,) = graiToken.asks(alice);
        assertEq(remaining, buy2);

        uint256 pay2 = (payment * buy2) / lot;
        vm.prank(bob);
        graiToken.fulfillAsk(alice, buy2, pay2);

        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, pay1 + pay2);
        (,,,, , uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    function test_SecondAskOverwrites() public {
        _mint(alice, usdc, 200e6);

        uint256 duration = 1 days;
        uint256 list1 = 50e6;
        (uint256 lot1, uint256 tax1) = graiToken.previewAsk(alice, 50e6, 50e6, duration, list1);
        vm.prank(alice);
        graiToken.ask(address(usdc), 50e6, 50e6, duration, list1);

        (,,,, , uint256 start1,, uint32 id1) = graiToken.asks(alice);
        assertGt(start1, 0);
        assertEq(graiToken.asksList(id1), alice);
        assertEq(graiToken.balanceOf(alice), 200e6 - tax1);

        uint256 list2 = 80e6;
        uint256 pay2 = 70e6;
        (uint256 lot2, uint256 tax2) = graiToken.previewAsk(alice, pay2, pay2, duration, list2);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        graiToken.ask(address(usdc), pay2, pay2, duration, list2);

        (, uint256 rem, uint256 initial, uint256 maxPay,, uint256 start2,, uint32 id2) = graiToken.asks(alice);
        assertEq(id2, id1); // same asksList slot
        assertEq(graiToken.asksList(id2), alice);
        assertEq(rem, lot2);
        assertEq(initial, lot2);
        assertEq(maxPay, pay2);
        assertEq(start2, block.timestamp);
        assertEq(graiToken.balanceOf(alice), 200e6 - tax1 - tax2);
        // first listing params fully replaced
        assertTrue(lot2 != lot1 || tax2 != tax1);
    }

    function test_TransferDoesNotShrinkAsk_BidRequiresBalance() public {
        _mint(alice, usdc, 100e6);

        uint256 duration = 1 days;
        uint256 listAmount = 50e6;
        uint256 maxPayment = 50e6;
        uint256 minPayment = 40e6;
        (uint256 lot,) = graiToken.previewAsk(alice, maxPayment, minPayment, duration, listAmount);

        vm.prank(alice);
        graiToken.ask(address(usdc), maxPayment, minPayment, duration, listAmount);

        uint256 send = lot / 4;
        vm.prank(alice);
        assertTrue(graiToken.transfer(bob, send));

        // No transfer-hook: ask lot is unchanged after a plain transfer.
        (, uint256 remaining, uint256 initial, uint256 maxAfter, uint256 minAfter, uint256 startTime,,) =
            graiToken.asks(alice);
        assertEq(remaining, lot);
        assertEq(initial, lot);
        assertEq(maxAfter, maxPayment);
        assertEq(minAfter, minPayment);
        assertGt(startTime, 0);

        // Dump unlisted + part of listed so seller holds less than the open lot.
        uint256 dump = graiToken.balanceOf(alice) - (lot / 2);
        vm.prank(alice);
        assertTrue(graiToken.transfer(bob, dump));
        assertLt(graiToken.balanceOf(alice), lot);

        // previewFulfillAsk / bid clamp to seller balance — payment shrinks, fill succeeds.
        uint256 held = graiToken.balanceOf(alice);
        (, uint256 payFullLot) = graiToken.previewFulfillAsk(alice, lot);
        (, uint256 payHeld) = graiToken.previewFulfillAsk(alice, held);
        assertEq(payFullLot, payHeld);
        assertLt(payHeld, maxPayment);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), payFullLot);
        graiToken.fulfillAsk(alice, lot, payFullLot);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(alice), 0);
        assertEq(graiToken.balanceOf(bob), held + send + dump);
        (,,,, , uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    // Deposit 1 ETH at $1000 -> ask 500 GRAI for 500 USDC (flat) -> bob fills entire lot.
    function test_Ask500_FulfillAll() public {
        address treasury = admin;
        _enableEthAt1000();

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        uint256 treasury0 = graiToken.balanceOf(treasury);

        // 1) deposit 1 ETH @ $1000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);

        // 2) ask 500 GRAI for 500 USDC
        uint256 duration = 1 days;
        uint256 listAmount = 500e6;
        uint256 askPayment = 500e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, askPayment, askPayment, duration, listAmount);
        assertEq(tax, 13_698);
        assertEq(lot, 499_986_302);

        vm.prank(alice);
        graiToken.ask(address(usdc), askPayment, askPayment, duration, listAmount);
        assertEq(graiToken.balanceOf(alice), 1000e6 - tax);
        assertEq(graiToken.balanceOf(treasury) - treasury0, tax);

        // 3) fulfill all
        vm.startPrank(bob);
        usdc.approve(address(graiToken), askPayment);
        graiToken.fulfillAsk(alice, type(uint256).max, askPayment);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(alice), 1000e6 - tax - lot);
        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + askPayment);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - askPayment);
        (,,,,, uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    // Deposit 1 ETH at $1000 -> ask 500 GRAI for 500 USDC (flat) -> bob fills half, ask stays open.
    function test_Ask500_FulfillPartial() public {
        address treasury = admin;
        _enableEthAt1000();

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        uint256 treasury0 = graiToken.balanceOf(treasury);

        // 1) deposit 1 ETH @ $1000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);

        // 2) ask 500 GRAI for 500 USDC
        uint256 duration = 1 days;
        uint256 listAmount = 500e6;
        uint256 askPayment = 500e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, askPayment, askPayment, duration, listAmount);
        assertEq(tax, 13_698);
        assertEq(lot, 499_986_302);

        vm.prank(alice);
        graiToken.ask(address(usdc), askPayment, askPayment, duration, listAmount);
        assertEq(graiToken.balanceOf(alice), 1000e6 - tax);
        assertEq(graiToken.balanceOf(treasury) - treasury0, tax);

        // 3) fulfill partial (half lot → 250 USDC)
        uint256 fill = lot / 2;
        (, uint256 pay) = graiToken.previewFulfillAsk(alice, fill);
        assertEq(pay, 250e6);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay);
        graiToken.fulfillAsk(alice, fill, pay);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(alice), 1000e6 - tax - fill);
        assertEq(graiToken.balanceOf(bob), fill);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + pay);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - pay);

        (, uint256 rem,, uint256 maxPay,,,,) = graiToken.asks(alice);
        assertEq(rem, lot - fill);
        assertEq(maxPay, 250e6);
    }

    function _enableEthAt1000() internal {
        vm.startPrank(admin);
        wethFeed.setAnswer(1000e8);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();
    }

    // Deposit 1 ETH at $1000 -> bob bids 500 GRAI for 500 USDC (flat after tax) -> alice fills entire lot.
    //
    // tax = 13_698, maxNet = 499_986_302 (1d). Bid lot = 500e6 GRAI (tax is USDC, not GRAI).
    //
    // | step | event                         | alice GRAI | bob GRAI | treasury USDC | alice USDC        | bob USDC          | bid rem | bid maxNet    |
    // |------|-------------------------------|------------|----------|---------------|-------------------|-------------------|---------|---------------|
    // | 0    | start                         | 0          | 0        | 0             | 1000e6            | 1000e6            | -       | -             |
    // | 1    | alice deposit 1 ETH @ $1000   | 1000e6     | 0        | 0             | 1000e6            | 1000e6            | -       | -             |
    // | 2    | bob bid 500 GRAI / 500 USDC   | 1000e6     | 0        | 13698         | 1000e6            | 999986302         | 500e6   | 499986302     |
    // | 3    | alice fulfill all             | 500e6      | 500e6    | 13698         | 1000e6+499986302  | 500e6             | cleared | -             |
    function test_Bid500_FulfillAll() public {
        address treasury = admin;
        _enableEthAt1000();

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        uint256 treasuryUsdc0 = usdc.balanceOf(treasury);

        // 1) alice deposits 1 ETH @ $1000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);

        // 2) bob bids 500 GRAI for 500 USDC (flat dutch = maxNet)
        uint256 duration = 1 days;
        uint256 graiWanted = 500e6;
        uint256 maxPayment = 500e6;

        vm.startPrank(bob);
        usdc.approve(address(graiToken), maxPayment);
        (uint256 lot, uint256 tax) =
            graiToken.previewBid(bob, address(usdc), maxPayment, 0, duration, graiWanted);
        assertEq(lot, graiWanted);
        assertEq(tax, 13_698);
        uint256 maxNet = maxPayment - tax;
        assertEq(maxNet, 499_986_302);
        graiToken.bid(address(usdc), maxPayment, maxNet, duration, graiWanted);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury) - treasuryUsdc0, tax);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - tax);
        (, uint256 rem,, uint256 maxStored,,,,) = graiToken.bids(bob);
        assertEq(rem, lot);
        assertEq(maxStored, maxNet);

        // 3) alice fulfill all
        vm.prank(alice);
        graiToken.fulfillBid(bob, type(uint256).max, maxNet);

        assertEq(graiToken.balanceOf(alice), 500e6);
        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + maxNet);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - maxPayment);
        (,,,,, uint256 startAfter,,) = graiToken.bids(bob);
        assertEq(startAfter, 0);
    }

    // Deposit 1 ETH at $1000 -> bob bids 500 GRAI for 500 USDC -> alice fills half, bid stays open.
    //
    // | step | event                         | alice GRAI | bob GRAI | treasury USDC | alice USDC        | bob USDC          | bid rem | bid maxNet    |
    // |------|-------------------------------|------------|----------|---------------|-------------------|-------------------|---------|---------------|
    // | 0    | start                         | 0          | 0        | 0             | 1000e6            | 1000e6            | -       | -             |
    // | 1    | alice deposit 1 ETH @ $1000   | 1000e6     | 0        | 0             | 1000e6            | 1000e6            | -       | -             |
    // | 2    | bob bid 500 GRAI / 500 USDC   | 1000e6     | 0        | 13698         | 1000e6            | 999986302         | 500e6   | 499986302     |
    // | 3    | alice fulfill half            | 750e6      | 250e6    | 13698         | 1000e6+249993151  | 749993151         | 250e6   | 249993151     |
    //
    // Step 3 payment = maxNet/2 = 249_993_151; bob USDC = 1000e6 - tax - pay.
    function test_Bid500_FulfillPartial() public {
        address treasury = admin;
        _enableEthAt1000();

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        uint256 treasuryUsdc0 = usdc.balanceOf(treasury);

        // 1) alice deposits 1 ETH @ $1000
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);

        // 2) bob bids 500 GRAI for 500 USDC
        uint256 duration = 1 days;
        uint256 graiWanted = 500e6;
        uint256 maxPayment = 500e6;

        vm.startPrank(bob);
        usdc.approve(address(graiToken), maxPayment);
        (uint256 lot, uint256 tax) =
            graiToken.previewBid(bob, address(usdc), maxPayment, 0, duration, graiWanted);
        assertEq(lot, graiWanted);
        assertEq(tax, 13_698);
        uint256 maxNet = maxPayment - tax;
        assertEq(maxNet, 499_986_302);
        graiToken.bid(address(usdc), maxPayment, maxNet, duration, graiWanted);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury) - treasuryUsdc0, tax);

        // 3) alice fulfill partial (half lot)
        uint256 fill = lot / 2;
        (, uint256 pay) = graiToken.previewFulfillBid(bob, alice, fill);
        assertEq(pay, maxNet / 2);
        assertEq(pay, 249_993_151);

        vm.prank(alice);
        graiToken.fulfillBid(bob, fill, pay);

        assertEq(graiToken.balanceOf(alice), 1000e6 - fill);
        assertEq(graiToken.balanceOf(bob), fill);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + pay);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - tax - pay);

        (, uint256 rem,, uint256 maxStored,,,,) = graiToken.bids(bob);
        assertEq(rem, lot - fill);
        assertEq(maxStored, maxNet - pay);
    }

    // Soft-escrow auction walkthrough (flat 500 USDC ask for half of a 1 ETH at 1000 USD mint).
    //
    // Balances after each step (GRAI 6dp / USDC 6dp; tax from previewAsk(500e6, 1d) = 13_698):
    //
    // | step | event                            | alice GRAI | bob GRAI  | charlie GRAI | alice USDC | bob USDC | ask rem GRAI | ask max USDC |
    // |------|----------------------------------|------------|-----------|--------------|------------|----------|--------------|--------------|
    // | 0    | start                            | 0          | 0         | 0            | 1000e6     | 1000e6   | -            | -            |
    // | 1    | deposit 1 ETH at 1000 USD        | 1000e6     | 0         | 0            | 1000e6     | 1000e6   | -            | -            |
    // | 2    | ask 500e6 GRAI for 500 USDC      | 999986302  | 0         | 0            | 1000e6     | 1000e6   | 499986302    | 500e6        |
    // | 3    | bob buys 250 USDC (1/2 lot)      | 749993151  | 249993151 | 0            | 1250e6     | 750e6    | 249993151    | 250e6        |
    // | 4    | alice -> charlie 1/2 wallet GRAI | 374996576  | 249993151 | 374996575    | 1250e6     | 750e6    | 249993151    | 250e6        |
    // | 5    | bob fills remaining ask          | 125003425  | 499986302 | 374996575    | 1500e6     | 500e6    | cleared      | -            |
    //
    // Step 5: after step 4 alice still holds more GRAI than ask remaining, so fill is not balance-clamped;
    // payment is the scaled ask max (250 USDC).
    function test_Scenario_AskHalf_PartialBid_Transfer_FillRest() public {
        address charlie = makeAddr("charlie");
        address treasury = admin; // GRAI.initialize sets treasury = admin

        vm.startPrank(admin);
        wethFeed.setAnswer(1000e8);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 aliceUsdc0 = usdc.balanceOf(alice); // 1000e6 from fixture
        uint256 bobUsdc0 = usdc.balanceOf(bob); // 1000e6 from fixture

        // --- 1. alice deposits 1 ETH at 1000 USD ---
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);

        assertEq(graiToken.balanceOf(alice), 1000e6);
        assertEq(graiToken.balanceOf(bob), 0);
        assertEq(graiToken.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdc0);
        assertEq(usdc.balanceOf(bob), bobUsdc0);

        // --- 2. alice asks half GRAI for 500 USDC (flat dutch) ---
        uint256 duration = 1 days;
        uint256 listAmount = 500e6;
        uint256 askPayment = 500e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, askPayment, askPayment, duration, listAmount);
        assertEq(tax, 13_698);
        assertEq(lot, 499_986_302);

        uint256 treasuryGrai0 = graiToken.balanceOf(treasury);
        vm.prank(alice);
        graiToken.ask(address(usdc), askPayment, askPayment, duration, listAmount);

        assertEq(graiToken.balanceOf(alice), 1000e6 - tax);
        assertEq(graiToken.balanceOf(treasury) - treasuryGrai0, tax);
        (, uint256 rem2,, uint256 max2,,,,) = graiToken.asks(alice);
        assertEq(rem2, lot);
        assertEq(max2, askPayment);

        // --- 3. bob buys 250 USDC of the ask (half of flat price -> half lot) ---
        uint256 fill1 = lot / 2;
        (, uint256 pay1) = graiToken.previewFulfillAsk(alice, fill1);
        assertEq(pay1, 250e6);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay1);
        graiToken.fulfillAsk(alice, fill1, pay1);
        vm.stopPrank();

        uint256 aliceGrai3 = 1000e6 - tax - fill1;
        assertEq(graiToken.balanceOf(alice), aliceGrai3);
        assertEq(aliceGrai3, 749_993_151);
        assertEq(graiToken.balanceOf(bob), fill1);
        assertEq(graiToken.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + pay1);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - pay1);

        (, uint256 rem3,, uint256 max3,,,,) = graiToken.asks(alice);
        assertEq(rem3, lot - fill1);
        assertEq(max3, 250e6);

        // --- 4. alice transfers half of remaining wallet GRAI to charlie (ask unchanged) ---
        uint256 toCharlie = aliceGrai3 / 2;
        vm.prank(alice);
        assertTrue(graiToken.transfer(charlie, toCharlie));

        uint256 aliceGrai4 = aliceGrai3 - toCharlie;
        assertEq(graiToken.balanceOf(alice), aliceGrai4);
        assertEq(aliceGrai4, 374_996_576);
        assertEq(graiToken.balanceOf(charlie), toCharlie);
        assertEq(toCharlie, 374_996_575);
        assertEq(graiToken.balanceOf(bob), fill1);
        (, uint256 rem4,, uint256 max4,,,,) = graiToken.asks(alice);
        assertEq(rem4, rem3);
        assertEq(max4, max3);
        assertGt(aliceGrai4, rem4); // still enough to cover the open ask

        // --- 5. bob fills remaining ask for full remaining payment ---
        (, uint256 pay2) = graiToken.previewFulfillAsk(alice, rem4);
        assertEq(pay2, 250e6);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay2);
        graiToken.fulfillAsk(alice, rem4, pay2);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(alice), aliceGrai4 - rem4);
        assertEq(graiToken.balanceOf(alice), 125_003_425);
        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(graiToken.balanceOf(charlie), toCharlie);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + pay1 + pay2);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - pay1 - pay2);
        (,,,,, uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    // Listing tax goes to treasury; filling the ask still pays the full maxPayment.
    //
    // | step | event                         | alice GRAI | bob GRAI  | treasury GRAI | alice USDC | bob USDC | ask rem   | payment |
    // |------|-------------------------------|------------|-----------|---------------|------------|----------|-----------|---------|
    // | 0    | start                         | 0          | 0         | 0             | 1000e6     | 1000e6   | -         | -       |
    // | 1    | deposit 1 ETH at 1000 USD     | 1000e6     | 0         | 0             | 1000e6     | 1000e6   | -         | -       |
    // | 2    | ask 1000 GRAI for 1000 USDC   | lot        | 0         | tax           | 1000e6     | 1000e6   | lot       | -       |
    // | 3    | bob bids 1000 GRAI (→ lot)    | 0          | lot       | tax           | 2000e6     | 0        | cleared   | 1000e6  |
    //
    // tax = 27_397, lot = 999_972_603 (1d listing). Bid amount 1000e6 clamps to lot; USDC payment stays 1000e6.
    function test_Scenario_AskFull_Tax_BidGrossPaysFull() public {
        address treasury = admin;

        vm.startPrank(admin);
        wethFeed.setAnswer(1000e8);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        uint256 treasury0 = graiToken.balanceOf(treasury);

        // --- 1. alice deposits 1 ETH at 1000 USD ---
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        assertEq(graiToken.balanceOf(alice), 1000e6);

        // --- 2. ask all 1000 GRAI for 1000 USDC (flat) ---
        uint256 duration = 1 days;
        uint256 listAmount = 1000e6;
        uint256 askPayment = 1000e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, askPayment, askPayment, duration, listAmount);
        assertEq(tax, 27_397);
        assertEq(lot, 999_972_603);

        vm.prank(alice);
        graiToken.ask(address(usdc), askPayment, askPayment, duration, listAmount);

        assertEq(graiToken.balanceOf(alice), lot);
        assertEq(graiToken.balanceOf(treasury) - treasury0, tax);
        (, uint256 rem,, uint256 maxPay,,,,) = graiToken.asks(alice);
        assertEq(rem, lot);
        assertEq(maxPay, askPayment);
        // Full-lot preview uses net lot as basis → full ask payment (tax does not reduce USDC).
        (, uint256 payLot) = graiToken.previewFulfillAsk(alice, lot);
        assertEq(payLot, askPayment);
        (, uint256 payGross) = graiToken.previewFulfillAsk(alice, listAmount);
        assertEq(payGross, askPayment);

        // --- 3. bob bids for gross 1000 GRAI; fill clamps to lot, alice gets full 1000 USDC ---
        assertEq(usdc.balanceOf(bob), bobUsdc0);
        // fixture bob has 1000e6; need enough for the full payment
        assertGe(bobUsdc0, askPayment);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), askPayment);
        graiToken.fulfillAsk(alice, listAmount, askPayment);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(alice), 0);
        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(graiToken.balanceOf(treasury) - treasury0, tax);
        assertEq(usdc.balanceOf(alice), aliceUsdc0 + askPayment);
        assertEq(usdc.balanceOf(bob), bobUsdc0 - askPayment);
        (,,,,, uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    // Real PnL: idle stays, fresh 100 USDC profit via distribute. TV/idle rise together — no redeem race.
    //
    // yieldSplit = 80%. Numbers in USDC/GRAI 6dp.
    //
    // | step | event                      | alice GRAI | bob GRAI | supply | TV   | idle USDC | maxRedeem | note                         |
    // |------|----------------------------|------------|----------|--------|------|-----------|-----------|------------------------------|
    // | 1    | both mint 1000 USDC        | 1000       | 1000     | 2000   | 2000 | 2000      | 2000      |                              |
    // | 2    | distribute(100) real yield | 1000       | 1000     | 2000   | 2080 | 2080      | 2000*     | +80 senior, +20 treasury     |
    // | 3a   | alice redeem 1000 (half)   | 0          | 1000     | 1000   | 1040 | 1040      | 1000      | alice +1040 USDC (half idle) |
    // | 3b   | bob redeem 1000            | 0          | 0        | 0      | 0    | 0         | 0         | bob +1040 USDC               |
    //
    // * maxRedeem = supply while idle NAV == book (parity after yield). Each 50% GRAI → 50% of 2080 = 1040.
    //   vs deposit 1000: each earns +40 USDC senior yield share (80 of 100 PnL / 2).
    function test_Scenario_DistributeRealYield_ProRata() public {
        _mint(alice, usdc, 1000e6);
        _mint(bob, usdc, 1000e6);
        assertEq(graiToken.totalSupply(), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.balance(address(usdc)), 2000e6);
        assertEq(graiToken.used(address(usdc)), 0);

        // Fresh PnL (not taken principal): mint 100 USDC to grinders and distribute
        usdc.mint(address(grai), 100e6);
        uint256 treasury0 = usdc.balanceOf(admin);
        vm.startPrank(address(grai));
        usdc.approve(address(graiToken), 100e6);
        graiToken.distribute(address(usdc), 100e6);
        vm.stopPrank();

        uint256 seniorShare = (uint256(100e6) * DEFAULT_YIELD_SPLIT) / BPS; // 80e6
        uint256 treasuryShare = 100e6 - seniorShare; // 20e6
        assertEq(seniorShare, 80e6);
        assertEq(usdc.balanceOf(admin) - treasury0, treasuryShare);

        assertEq(graiToken.balance(address(usdc)), 2000e6 + seniorShare); // 2080e6
        assertEq(graiToken.seniorNAV(), 2080e6);
        assertEq(graiToken.totalValue(), 2000e6 + seniorShare); // 2080e6 — idle and book match
        assertEq(graiToken.used(address(usdc)), 0);
        // Full supply still liquid: no sticky gap after real yield on top of idle
        assertEq(graiToken.maxRedeem(), 2000e6);

        // New mint is more expensive: $2080 → 2000 GRAI (parity at new book)
        usdc.mint(bob, 2080e6); // bob needs more USDC for fair check deposit from charlie
        address charlie = makeAddr("charlie");
        usdc.mint(charlie, 208e6);
        vm.startPrank(charlie);
        usdc.approve(address(graiToken), 208e6);
        (uint256 charlieGrai,) = graiToken.deposit(address(usdc), 208e6);
        vm.stopPrank();
        // 208 * 2000 / 2080 = 200 GRAI exactly
        assertEq(charlieGrai, 200e6);
        assertEq(graiToken.totalSupply(), 2200e6);
        assertEq(graiToken.totalValue(), 2288e6); // 2080 + 208

        // Reset narrative focus: redeem alice/bob only after rolling charlie out of the picture is messy.
        // Instead assert pro-rata on the pre-charlie vault by checking preview before charlie... 
        // Simpler path: don't include charlie in redeem — burn charlie first or use separate asserts above only.
        // Re-check alice/bob claim on vault without charlie by comparing against state before charlie.
        // (charlie already deposited — unwind charlie redeem)
        uint256 charlieCap = graiToken.balanceOf(charlie);
        uint256 charlieUsdc0 = usdc.balanceOf(charlie);
        vm.prank(charlie);
        graiToken.redeem(charlieCap);
        // After charlie full exit at matching book, back near alice/bob-only vault (+dust)
        assertEq(usdc.balanceOf(charlie) - charlieUsdc0, 208e6);
        assertEq(graiToken.totalSupply(), 2000e6);
        assertEq(graiToken.totalValue(), 2080e6);
        assertEq(graiToken.balance(address(usdc)), 2080e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        // Alice and bob each redeem half supply → each gets half idle including yield
        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        _redeem(alice, 1000e6);
        _redeem(bob, 1000e6);

        uint256 aliceGot = usdc.balanceOf(alice) - aliceUsdc0;
        uint256 bobGot = usdc.balanceOf(bob) - bobUsdc0;
        assertEq(aliceGot, 1040e6);
        assertEq(bobGot, 1040e6);
        assertEq(aliceGot, bobGot); // equal holders → equal exit, no race surplus
        assertEq(aliceGot - 1000e6, 40e6); // +40 USDC yield each (80 senior / 2)
        assertEq(graiToken.totalSupply(), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // Contrast with double-count race: here redeemer does NOT drain more than their share
        assertLt(aliceGot, 1600e6);
    }

    // Double-count: take principal → distribute as "yield" (TV += again). Redeem race drains all idle.
    //
    // yieldSplit = 80%. Numbers in USDC/GRAI 6dp.
    //
    // | step | event                         | alice GRAI | bob GRAI | supply | TV    | idle USDC | maxRedeem | alice USDCΔ | bob USDCΔ |
    // |------|-------------------------------|------------|----------|--------|-------|-----------|-----------|-------------|-----------|
    // | 1    | both mint 1000 USDC           | 1000       | 1000     | 2000   | 2000  | 2000      | 2000      | -1000       | -1000     |
    // | 2    | take all to Grinders          | 1000       | 1000     | 2000   | 2000  | 0         | 0         | 0           | 0         |
    // | 3    | distribute 2000 as "yield"    | 1000       | 1000     | 2000   | 3600  | 1600*     | ~888.89   | 0           | 0         |
    // | 4a   | alice redeem(maxRedeem) first | ~111.11    | 1000     | ~1111  | ~2000 | 0         | 0         | +1600       | 0         |
    // | 4b   | bob holds                     | —          | 1000     | —      | —     | 0         | 0         | —           | 0 (stuck)|
    //
    // * treasury skim 400. Alice extracts 1600 idle for burning ~889 GRAI.
    //   Fair 50/50 of leftover idle = 800; honest put+redeem her 1000 GRAI = 1000 USDC.
    //   Race premium: 1600/800 = 2.00× vs fair split, 1600/1000 = 1.60× vs honest exit.
    function test_Scenario_DoubleCount_RedeemRaceBeatsHold() public {
        _mint(alice, usdc, 1000e6);
        _mint(bob, usdc, 1000e6);
        assertEq(graiToken.balanceOf(alice), 1000e6);
        assertEq(graiToken.balanceOf(bob), 1000e6);
        assertEq(graiToken.totalSupply(), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);

        // take all idle principal out (sticky TV)
        vm.prank(address(grai));
        graiToken.take(address(usdc), address(grai), 2000e6);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);
        assertEq(graiToken.totalValue(), 2000e6);
        assertEq(graiToken.used(address(usdc)), 2000e6);

        // recirculate same principal via distribute → TV mints again, treasury skim
        uint256 treasuryUsdc0 = usdc.balanceOf(admin);
        vm.startPrank(address(grai));
        usdc.approve(address(graiToken), 2000e6);
        graiToken.distribute(address(usdc), 2000e6);
        vm.stopPrank();

        uint256 seniorShare = (uint256(2000e6) * DEFAULT_YIELD_SPLIT) / BPS; // 1600e6
        uint256 treasuryShare = 2000e6 - seniorShare; // 400e6
        assertEq(seniorShare, 1600e6);
        assertEq(usdc.balanceOf(admin) - treasuryUsdc0, treasuryShare);
        assertEq(graiToken.balance(address(usdc)), seniorShare);
        assertEq(graiToken.totalValue(), 2000e6 + seniorShare); // 3600e6

        uint256 supply = graiToken.totalSupply();
        uint256 tv = graiToken.totalValue();
        uint256 cap = graiToken.maxRedeem();
        uint256 expectedCap = ((seniorShare + 1) * supply - 1) / tv;
        assertEq(cap, expectedCap);
        assertEq(cap, 888_888_889); // ~888.89 GRAI of 2000

        // Counterfactuals
        uint256 fairSplitOfIdle = seniorShare / 2; // 800e6 — equal holders of remaining idle
        uint256 honestPutAliceUsdc = 1000e6; // her deposit back if put+full redeem path

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 aliceGrai0 = graiToken.balanceOf(alice);
        _redeem(alice, cap);
        uint256 aliceGot = usdc.balanceOf(alice) - aliceUsdc0;

        // Race winner drains 100% of idle for burning only maxRedeem GRAI
        assertEq(aliceGot, seniorShare);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balanceOf(alice), aliceGrai0 - cap);
        assertEq(graiToken.balanceOf(bob), 1000e6);
        assertEq(graiToken.maxRedeem(), 0);
        assertEq(graiToken.seniorNAV(), 0);

        // How much better than hold/fair outcomes
        assertEq(aliceGot, fairSplitOfIdle * 2); // 2.00× fair share of leftover idle
        assertEq(aliceGot * 1000 / honestPutAliceUsdc, 1600); // 1.60× honest full exit of her 1000
        assertEq(aliceGot - fairSplitOfIdle, 800e6); // +800 USDC vs bob's equal split
        assertEq(aliceGot - honestPutAliceUsdc, 600e6); // +600 USDC vs putting principal back honestly

        // Holder left with residual GRAI and nothing claimable from current idle
        assertGt(graiToken.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(bob), 0); // fixture USDC spent on mint; no redeem proceeds
    }

    // Flat 100 USDC / 100 GRAI ask, three partial fills; lot scales with remaining each time.
    //
    // | step | event              | rem GRAI     | graiInitial  | maxPayment           | payment      |
    // |------|--------------------|--------------|--------------|----------------------|--------------|
    // | 1    | ask 100e6 @ 100e6  | lot          | lot          | 100e6                | -            |
    // | 2    | bid 30e6           | lot-30e6     | scaled       | 100e6*(lot-30)/lot   | previewFulfillAsk   |
    // | 3    | bid 40e6           | rem2-40e6    | scaled       | max2*(rem2-40)/rem2  | previewFulfillAsk   |
    // | 4    | bid remainder      | cleared      | -            | -                    | previewFulfillAsk   |
    function test_Ask100_PartialBids_30_40_Rest() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 200e6);

        uint256 duration = 1 days;
        uint256 listAmount = 100e6;
        uint256 askPayment = 100e6;
        (uint256 lot, uint256 tax) = graiToken.previewAsk(alice, askPayment, askPayment, duration, listAmount);

        // --- 1. ask 100 USDC for 100 GRAI ---
        vm.prank(alice);
        graiToken.ask(address(usdc), askPayment, askPayment, duration, listAmount);

        (, uint256 rem1, uint256 init1, uint256 max1, uint256 min1, uint256 start1,,) = graiToken.asks(alice);
        assertEq(rem1, lot);
        assertEq(init1, lot);
        assertEq(max1, askPayment);
        assertEq(min1, askPayment);
        assertGt(start1, 0);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax);

        // --- 2. bid 30 GRAI; pay previewFulfillAsk; lot scales ---
        uint256 buy1 = 30e6;
        (uint256 out1, uint256 pay1) = graiToken.previewFulfillAsk(alice, buy1);
        assertEq(out1, buy1);
        // flat dutch @ t0: payment = askPayment * buy1 / lot (~30 USDC, tax makes it slightly > 30e6)
        assertEq(pay1, (askPayment * buy1) / lot);

        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay1);
        graiToken.fulfillAsk(alice, buy1, pay1);
        vm.stopPrank();

        uint256 remAfter1 = lot - buy1;
        (, uint256 rem2, uint256 init2, uint256 max2, uint256 min2,,,) = graiToken.asks(alice);
        assertEq(rem2, remAfter1);
        assertEq(init2, (lot * remAfter1) / lot); // == remAfter1
        assertEq(max2, (askPayment * remAfter1) / lot);
        assertEq(min2, (askPayment * remAfter1) / lot);
        assertEq(usdc.balanceOf(alice) - aliceUsdc0, pay1);
        assertEq(graiToken.balanceOf(bob), buy1);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax - buy1);

        // --- 3. bid 40 GRAI; pay previewFulfillAsk; lot scales again ---
        uint256 buy2 = 40e6;
        (uint256 out2, uint256 pay2) = graiToken.previewFulfillAsk(alice, buy2);
        assertEq(out2, buy2);
        assertEq(pay2, (max2 * buy2) / init2);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay2);
        graiToken.fulfillAsk(alice, buy2, pay2);
        vm.stopPrank();

        uint256 remAfter2 = remAfter1 - buy2;
        (, uint256 rem3, uint256 init3, uint256 max3, uint256 min3,,,) = graiToken.asks(alice);
        assertEq(rem3, remAfter2);
        assertEq(init3, (init2 * remAfter2) / remAfter1);
        assertEq(max3, (max2 * remAfter2) / remAfter1);
        assertEq(min3, (min2 * remAfter2) / remAfter1);
        assertEq(graiToken.balanceOf(bob), buy1 + buy2);
        assertEq(usdc.balanceOf(alice) - aliceUsdc0, pay1 + pay2);

        // --- 4. bid remainder; pay previewFulfillAsk; ask clears ---
        (uint256 out3, uint256 pay3) = graiToken.previewFulfillAsk(alice, rem3);
        assertEq(out3, rem3);
        assertEq(pay3, (max3 * rem3) / init3);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), pay3);
        graiToken.fulfillAsk(alice, rem3, pay3);
        vm.stopPrank();

        (,,,,, uint256 startAfter,,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax - lot);
        assertEq(usdc.balanceOf(alice) - aliceUsdc0, pay1 + pay2 + pay3);
        // Full flat fill ends at the listed ask payment (integer dust from successive scales may round down).
        assertLe(pay1 + pay2 + pay3, askPayment);
        assertGe(pay1 + pay2 + pay3, askPayment - 3); // at most a few wei of USDC round-down
    }

    function test_BidRevertsWhenAskPaymentRaisedAboveMax() public {
        _mint(alice, usdc, 200e6);
        usdc.mint(bob, 200e6);

        uint256 duration = 1 days;
        uint256 listAmount = 100e6;
        uint256 payLow = 50e6;
        uint256 payHigh = 100e6;
        (uint256 lot,) = graiToken.previewAsk(alice, payLow, payLow, duration, listAmount);

        vm.prank(alice);
        graiToken.ask(address(usdc), payLow, payLow, duration, listAmount);

        (, uint256 quote) = graiToken.previewFulfillAsk(alice, lot);
        assertEq(quote, payLow);

        // Seller spoofs: overwrite ask at a higher price before bob's tx lands.
        vm.prank(alice);
        graiToken.ask(address(usdc), payHigh, payHigh, duration, listAmount);
        (, uint256 quoteHigh) = graiToken.previewFulfillAsk(alice, lot);
        assertEq(quoteHigh, payHigh);

        vm.startPrank(bob);
        usdc.approve(address(graiToken), payHigh);
        vm.expectRevert(IGRAI.PaymentExceedsMax.selector);
        graiToken.fulfillAsk(alice, lot, payLow); // bob's paymentMax still based on old quote
        vm.stopPrank();
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

    function test_Lock_BelowQuorum() public {
        _mint(alice, usdc, 100e6);

        vm.prank(alice);
        graiToken.lock(94e6);

        (uint256 lockedAmount,) = graiToken.liquidationLocks(alice);
        assertEq(lockedAmount, 94e6);
        assertEq(graiToken.totalLiquidationLocked(), 94e6);
        assertEq(graiToken.balanceOf(alice), 6e6);
        assertEq(graiToken.balanceOf(address(graiToken)), 94e6);
        (, bool usdcPaused,) = graiToken.assets(address(usdc));
        assertFalse(usdcPaused);
        assertFalse(graiToken.hasQuorum());

        vm.expectRevert(IGRAI.LiquidationQuorumNotMet.selector);
        graiToken.openLiquidation();
    }

    function test_Unlock_ReturnsWithFee() public {
        _mint(alice, usdc, 100e6);

        vm.prank(alice);
        graiToken.lock(50e6);

        // Flat only at t0.
        (uint256 net0, uint256 fee0) = graiToken.previewUnlock(alice, 20e6);
        assertEq(fee0, (20e6 * uint256(graiToken.UNLOCK_FEE_BPS())) / BPS);
        assertEq(net0, 20e6 - fee0);

        vm.warp(block.timestamp + 365 days);

        (uint256 net, uint256 fee) = graiToken.previewUnlock(alice, 20e6);
        uint256 flat = (20e6 * uint256(graiToken.UNLOCK_FEE_BPS())) / BPS;
        uint256 timeTax = (20e6 * uint256(graiToken.UNLOCK_APR_BPS())) / BPS; // 1 year
        assertEq(fee, flat + timeTax);
        assertEq(net, 20e6 - fee);

        uint256 treasuryBefore = graiToken.balanceOf(admin);
        vm.prank(alice);
        graiToken.unlock(20e6);

        (uint256 lockedAmount,) = graiToken.liquidationLocks(alice);
        assertEq(lockedAmount, 30e6);
        assertEq(graiToken.totalLiquidationLocked(), 30e6);
        assertEq(graiToken.balanceOf(alice), 50e6 + net);
        assertEq(graiToken.balanceOf(admin) - treasuryBefore, fee);
        assertEq(graiToken.balanceOf(address(graiToken)), 30e6);
    }

    function test_Liquidate_QuorumPausesAndRecallsCustodians() public {
        _mint(alice, usdc, 100e6);
        _mint(bob, usdc, 100e6);

        // Senior capital parked at custodian via grinders.
        vm.prank(address(grai));
        graiToken.take(address(usdc), address(grai), 80e6);
        _allocate(address(usdc), custodian, 80e6);

        assertEq(usdc.balanceOf(custodian), 1_000e6 + 80e6);
        assertEq(graiToken.used(address(usdc)), 80e6);
        assertEq(grai.allocated(custodian, address(usdc)), 80e6);

        // 95% of 200e6 supply = 190e6
        vm.prank(alice);
        graiToken.lock(100e6);
        (, bool pausedBeforeQuorum,) = graiToken.assets(address(usdc));
        assertFalse(pausedBeforeQuorum);

        vm.prank(bob);
        graiToken.lock(100e6);
        assertEq(graiToken.totalLiquidationLocked(), 200e6);
        assertTrue(graiToken.hasQuorum());

        vm.prank(alice);
        graiToken.openLiquidation();

        (, bool usdcPaused,) = graiToken.assets(address(usdc));
        (, bool wethPaused,) = graiToken.assets(address(weth));
        assertTrue(usdcPaused);
        assertTrue(wethPaused);
        assertTrue(graiToken.liquidation());

        // Paginated custodian sweep (anyone).
        grai.liquidate(0, grai.totalSupply());

        // Custodian swept back to senior idle.
        assertEq(usdc.balanceOf(custodian), 0);
        assertEq(grai.allocated(custodian, address(usdc)), 0);
        assertEq(grai.active(address(usdc)), 0);
        assertEq(grai.balance(address(usdc)), 0);
        assertEq(graiToken.used(address(usdc)), 0);
        // Idle: 200e6 deposits + 1000e6 seed.
        assertEq(graiToken.balance(address(usdc)), 1_200e6);
    }

    function test_Bid_SoftEscrow_FulfillBuysGrai() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 maxPayment = 50e6;
        uint256 duration = 1 days;
        uint256 graiWanted = 40e6;

        vm.startPrank(bob);
        usdc.approve(address(graiToken), maxPayment);
        (uint256 lot, uint256 tax) = graiToken.previewBid(bob, address(usdc), maxPayment, 0, duration, graiWanted);
        assertEq(lot, graiWanted);
        assertTrue(tax > 0);
        uint256 minPayment = maxPayment - tax; // flat dutch after tax
        graiToken.bid(address(usdc), maxPayment, minPayment, duration, graiWanted);
        vm.stopPrank();

        assertEq(usdc.balanceOf(admin), tax); // tax to treasury
        (,, uint256 graiInitial, uint256 maxNet,,,,) = graiToken.bids(bob);
        assertEq(graiInitial, graiWanted);
        assertEq(maxNet, maxPayment - tax);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobGraiBefore = graiToken.balanceOf(bob);

        vm.prank(alice);
        graiToken.fulfillBid(bob, graiWanted, maxNet);

        assertEq(graiToken.balanceOf(bob) - bobGraiBefore, graiWanted);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, maxNet);
        (,,,,,, uint256 startTime,) = graiToken.bids(bob);
        assertEq(startTime, 0); // cleared
    }

    function test_Bid_RevertsWithoutAllowance() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        vm.prank(bob);
        vm.expectRevert(IGRAI.InsufficientAllowance.selector);
        graiToken.bid(address(usdc), 50e6, 0, 1 days, 40e6);
    }

    function test_Bid_EthEscrow_FulfillBuysGrai() public {
        _mint(alice, usdc, 100e6);
        vm.deal(bob, 100 ether);

        uint256 maxPayment = 1 ether;
        uint256 duration = 1 days;
        uint256 graiWanted = 40e6;

        (uint256 lot, uint256 tax) = graiToken.previewBid(bob, address(0), maxPayment, 0, duration, graiWanted);
        assertEq(lot, graiWanted);
        uint256 minPayment = maxPayment - tax;

        // Listing: Harberger tax only.
        vm.prank(bob);
        graiToken.bid{value: tax}(address(0), maxPayment, minPayment, duration, graiWanted);

        assertEq(admin.balance, tax);
        (,,, uint256 maxNet,,,,) = graiToken.bids(bob);
        assertEq(maxNet, maxPayment - tax);
        assertEq(address(graiToken).balance, 0); // no purchase escrow

        uint256 aliceEthBefore = alice.balance;
        // Fill: buyer pays dutch ETH, seller is peer.
        vm.prank(bob);
        graiToken.fulfillBid{value: maxNet}(alice, graiWanted, maxNet);

        assertEq(alice.balance - aliceEthBefore, maxNet);
        assertEq(graiToken.balanceOf(bob), graiWanted);
        (,,,,,, uint256 startTime,) = graiToken.bids(bob);
        assertEq(startTime, 0);
    }

    /// Deposit 1 ETH at $1000 + 1000 USDC → take all → allocate custodians → lock → openLiquidation
    /// → liquidate (idle back on vault) → unlock → Alice & Bob redeem.
    function test_Scenario_LockOpenUnlockRedeem_EthUsdc_TakeAll() public {
        vm.startPrank(admin);
        wethFeed.setAnswer(1000e8);
        _setChainlinkFeed(address(0), address(wethFeed));
        graiToken.addAsset(address(0), DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        // Drop fixture seed so liquidate only returns taken capital.
        deal(address(usdc), custodian, 0);

        _logBalances("0.start");

        // 1) deposit 1 ETH @ $1000 + 1000 USDC (Alice)
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        graiToken.deposit{value: 1 ether}(address(0), 1 ether);
        _mint(alice, usdc, 1000e6);
        assertEq(graiToken.balanceOf(alice), 2000e6);
        assertEq(graiToken.totalValue(), 2000e6);
        _logBalances("1.deposit");

        // 2) grinders take all → allocate to custodian (junior park)
        vm.startPrank(address(grai));
        graiToken.take(address(0), address(grai), 1 ether);
        graiToken.take(address(usdc), address(grai), 1000e6);
        vm.stopPrank();
        _allocate(address(0), custodian, 1 ether);
        _allocate(address(usdc), custodian, 1000e6);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);
        _logBalances("2.take+allocate");

        // 3) two users: Bob unlocked float; Alice locks 95% for quorum
        vm.prank(alice);
        assertTrue(graiToken.transfer(bob, 100e6));
        vm.prank(alice);
        graiToken.lock(1900e6);
        assertTrue(graiToken.hasQuorum());
        _logBalances("3.lock");

        // 4) openLiquidation + paginated recall → idle back on vault
        vm.prank(alice);
        graiToken.openLiquidation();
        assertTrue(graiToken.liquidation());
        grai.liquidate(0, grai.totalSupply());
        assertEq(graiToken.balance(address(0)), 1 ether);
        assertEq(graiToken.balance(address(usdc)), 1000e6);
        assertEq(graiToken.seniorNAV(), 2000e6);
        assertEq(graiToken.maxRedeem(), 2000e6);
        _logBalances("4.open+liquidate");

        // 5) Alice unlocks for free (fee waived while liquidation)
        (uint256 net, uint256 fee) = graiToken.previewUnlock(alice, 1900e6);
        assertEq(fee, 0);
        assertEq(net, 1900e6);
        vm.prank(alice);
        graiToken.unlock(1900e6);
        assertEq(graiToken.balanceOf(alice), 1900e6);
        _logBalances("5.unlock");

        // 6) Alice then Bob redeem their balances (pro-rata idle vs maxRedeem)
        uint256 aliceEthBefore = alice.balance;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobEthBefore = bob.balance;
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        uint256 aliceBal = graiToken.balanceOf(alice);
        uint256 bobBal = graiToken.balanceOf(bob);
        _redeem(alice, aliceBal);
        _logBalances("6a.aliceRedeem");
        _redeem(bob, bobBal);
        _logBalances("6b.bobRedeem");

        // Full idle drained; sticky book burned with supply.
        assertEq(graiToken.balance(address(0)), 0);
        assertEq(graiToken.balance(address(usdc)), 0);
        assertEq(graiToken.balanceOf(alice), 0);
        assertEq(graiToken.balanceOf(bob), 0);
        assertEq(graiToken.seniorNAV(), 0);
        assertEq(graiToken.maxRedeem(), 0);

        // Pro-rata: Alice 1900/2000, Bob 100/2000 of 1 ETH + 1000 USDC
        assertEq(alice.balance - aliceEthBefore, (1 ether * 1900) / 2000);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, (1000e6 * 1900) / 2000);
        assertEq(bob.balance - bobEthBefore, (1 ether * 100) / 2000);
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, (1000e6 * 100) / 2000);
    }

    function _logBalances(string memory step) internal view {
        console2.log("========", step);
        console2.log("TV", graiToken.totalValue());
        console2.log("NAV", graiToken.seniorNAV());
        console2.log("maxRedeem", graiToken.maxRedeem());
        console2.log("supply", graiToken.totalSupply());
        console2.log("locked", graiToken.totalLiquidationLocked());
        console2.log("liquidation", graiToken.liquidation());
        console2.log("alice GRAI", graiToken.balanceOf(alice));
        console2.log("bob GRAI", graiToken.balanceOf(bob));
        console2.log("vault ETH", graiToken.balance(address(0)));
        console2.log("vault USDC", graiToken.balance(address(usdc)));
        console2.log("custodian ETH", custodian.balance);
        console2.log("custodian USDC", usdc.balanceOf(custodian));
        console2.log("grinders ETH", grai.balance(address(0)));
        console2.log("grinders USDC", usdc.balanceOf(address(grai)));
        console2.log("used ETH", graiToken.used(address(0)));
        console2.log("used USDC", graiToken.used(address(usdc)));
    }
}
