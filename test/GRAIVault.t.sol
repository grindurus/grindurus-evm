// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    function _scenario_TakeDistributeRedeemPutRedeem(
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
        _scenario_TakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 2500e8, 200e6, 2200e6, 1_100_000, 181_818_182, 1_818_181_818, 1_818_181_818, 0
        );
    }

    function test_Scenario_TakeDistributeRedeem_Price2000() public {
        // mint @ $2000; yield @ $2000 → full exit after put
        _scenario_TakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 2000e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 1_851_851_851, 0
        );
    }

    function test_Scenario_TakeDistributeRedeem_Price1500() public {
        // mint @ $2000; yield @ $1500 → leave ~471.70 GRAI after put+redeem
        _scenario_TakeDistributeRedeemPutRedeem(
            2000e8, 2000e6, 1500e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 1_415_094_340, 471_698_112
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price500() public {
        // mint @ $1000; spot $500 → after put leave ~480.77 GRAI
        _scenario_TakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 500e8, 40e6, 1040e6, 1_040_000, 38_461_539, 961_538_461, 480_769_231, 480_769_230
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price1000() public {
        // mint @ $1000; spot $1000 → full exit after put
        _scenario_TakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 1000e8, 80e6, 1080e6, 1_080_000, 74_074_074, 925_925_926, 925_925_926, 0
        );
    }

    function test_Scenario_Mint1000_TakeDistributeRedeem_Price1500() public {
        // mint @ $1000; spot $1500 → full exit after put (NAV > remaining book)
        _scenario_TakeDistributeRedeemPutRedeem(
            1000e8, 1000e6, 1500e8, 120e6, 1120e6, 1_120_000, 107_142_858, 892_857_142, 892_857_142, 0
        );
    }

    /// ETH+USDC: deposit → take → price → distribute → redeem → put basket → redeem.
    function _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
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
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 0.5 ether, 1500e6, 1_682_692_308, 240_384_615
        );
    }

    function test_Scenario_EthUsdc_TakeDistributeRedeemPut_Price1000() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 0.5 ether, 1500e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_TakeDistributeRedeemPut_Price1500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 0.5 ether, 1500e6, 1_851_851_851, 0
        );
    }

    // --- put matrix: (2 ETH,0) / (1 ETH,1000 USDC) / (0,2000 USDC) × price $500/$1000/$1500 ---
    function test_Scenario_EthUsdc_Put2Eth_Price500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 2 ether, 0, 961_538_462, 961_538_461
        );
    }

    function test_Scenario_EthUsdc_Put2Eth_Price1000() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 2 ether, 0, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put2Eth_Price1500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 2 ether, 0, 1_851_851_851, 0
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 1 ether, 1000e6, 1_442_307_693, 480_769_230
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price1000() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 1 ether, 1000e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put1Eth1000Usdc_Price1500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1500e8, 160e6, 2160e6, 1_080_000, 148_148_149, 1_851_851_851, 1 ether, 1000e6, 1_851_851_851, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            500e8, 80e6, 2080e6, 1_040_000, 76_923_077, 1_923_076_923, 0, 2000e6, 1_923_076_923, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price1000() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
            1000e8, 120e6, 2120e6, 1_060_000, 113_207_548, 1_886_792_452, 0, 2000e6, 1_886_792_452, 0
        );
    }

    function test_Scenario_EthUsdc_Put2000Usdc_Price1500() public {
        _scenario_EthUsdc_TakeDistributeRedeemPutRedeem(
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
        uint256 tax = graiToken.previewTax(listAmount, duration);
        uint256 lot = listAmount - tax;
        uint256 treasuryBefore = graiToken.balanceOf(admin);

        vm.prank(alice);
        graiToken.ask(address(usdc), payment, payment, duration, listAmount);

        (address askAsset, uint256 remaining,,,, uint256 startTime,) = graiToken.asks(alice);
        assertEq(askAsset, address(usdc));
        assertEq(remaining, lot);
        assertGt(startTime, 0);
        assertEq(graiToken.balanceOf(admin) - treasuryBefore, tax);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), payment);
        graiToken.bid(alice, lot);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, payment);
        assertEq(graiToken.balanceOf(alice), 100e6 - tax - lot);
        assertEq(graiToken.balanceOf(bob), lot);
        (,,,, , uint256 startAfter,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    function test_DutchAskFillsAtFloor() public {
        _mint(alice, usdc, 100e6);
        usdc.mint(bob, 100e6);

        uint256 maxPayment = 50e6;
        uint256 minPayment = (maxPayment * 95) / 100;
        uint256 duration = 1 days;
        uint256 listAmount = 50e6;
        uint256 tax = graiToken.previewTax(listAmount, duration);
        uint256 lot = listAmount - tax;

        vm.prank(alice);
        graiToken.ask(address(usdc), maxPayment, minPayment, duration, listAmount);

        vm.warp(block.timestamp + duration);
        assertEq(graiToken.previewBid(alice, lot), minPayment);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(graiToken), minPayment);
        graiToken.bid(alice, lot);
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
        uint256 tax = graiToken.previewTax(listAmount, duration);
        uint256 lot = listAmount - tax;
        uint256 buy1 = lot / 2;
        uint256 buy2 = lot - buy1;

        vm.prank(alice);
        graiToken.ask(address(usdc), payment, payment, duration, listAmount);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 pay1 = (payment * buy1) / lot;

        vm.startPrank(bob);
        usdc.approve(address(graiToken), payment);
        graiToken.bid(alice, buy1);
        vm.stopPrank();

        assertEq(graiToken.balanceOf(bob), buy1);
        assertEq(graiToken.balanceOf(alice), 101e6 - tax - buy1);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, pay1);
        (, uint256 remaining,,,,,) = graiToken.asks(alice);
        assertEq(remaining, buy2);

        uint256 pay2 = (payment * buy2) / lot;
        vm.prank(bob);
        graiToken.bid(alice, buy2);

        assertEq(graiToken.balanceOf(bob), lot);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, pay1 + pay2);
        (,,,, , uint256 startAfter,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
    }

    function test_SecondAskReverts() public {
        _mint(alice, usdc, 200e6);

        uint256 duration = 1 days;
        vm.prank(alice);
        graiToken.ask(address(usdc), 50e6, 50e6, duration, 50e6);

        vm.prank(alice);
        vm.expectRevert(IGRAI.AskExists.selector);
        graiToken.ask(address(usdc), 50e6, 50e6, duration, 50e6);
    }

    function test_TransferShrinksAsk() public {
        _mint(alice, usdc, 100e6);

        uint256 duration = 1 days;
        uint256 listAmount = 50e6;
        uint256 maxPayment = 50e6;
        uint256 minPayment = 40e6;
        uint256 tax = graiToken.previewTax(listAmount, duration);
        uint256 lot = listAmount - tax;

        vm.prank(alice);
        graiToken.ask(address(usdc), maxPayment, minPayment, duration, listAmount);

        uint256 send = lot / 4;
        uint256 left = lot - send;
        vm.prank(alice);
        graiToken.transfer(bob, send);

        (, uint256 remaining, uint256 initial, uint256 maxAfter, uint256 minAfter, uint256 startTime,) =
            graiToken.asks(alice);
        assertEq(remaining, left);
        assertEq(initial, left);
        assertEq(maxAfter, (maxPayment * left) / lot);
        assertEq(minAfter, (minPayment * left) / lot);
        assertGt(startTime, 0);

        vm.prank(alice);
        graiToken.transfer(bob, left);

        (,,,, , uint256 startAfter,) = graiToken.asks(alice);
        assertEq(startAfter, 0);
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
