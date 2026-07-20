// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {console2} from "forge-std/console2.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBuybackRouter {
    function swap(IERC20 paymentToken, IERC20 grai, uint256 payment, uint256 graiOut, address receiver) external {
        require(paymentToken.transferFrom(msg.sender, address(this), payment));
        require(grai.transfer(receiver, graiOut));
    }
}

/// @dev Yield-asset Dutch auction scenarios: distribute → 1y auction → fill for settlementAsset.
contract GRAITest is GRAIFixture {
    address yielder = makeAddr("yielder");
    MockAggregator ethFeed;

    function _logState(string memory label) internal view {
        console2.log("====================", label);
        console2.log("totalSupply (GRAI 1e6):", grai.totalSupply());
        console2.log("totalValue ($ 1e6):  ", grai.totalValue());
        console2.log("settlementAsset:            ", grai.settlementAsset());
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
        _setAssetConfig(address(0), false);
        _setTreasuryShare(0);
        _setAssetConfig(address(usdc), false);
        grai.setSettlementAsset(address(usdc));
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
        grai.deposit{value: 1 ether}(address(0), 1 ether);
        vm.stopPrank();

        // Distribute 0.1 ETH @ $1000 → yieldShare 0.1 ETH, fair value $100 = 100e6 USDC.
        vm.deal(yielder, 0.1 ether);
        vm.prank(yielder);
        grai.distribute{value: 0.1 ether}(address(0), 0.1 ether);

        (address asset, uint256 remaining, uint256 initial, uint256 maxPayment, uint256 minPayment, uint256 startTime, uint32 duration)
            = grai.auctions(address(0));

        assertEq(asset, address(0));
        assertEq(remaining, 0.1 ether);
        assertEq(initial, 0.1 ether);
        assertEq(maxPayment, 100e6);
        assertEq(minPayment, 0);
        assertEq(startTime, block.timestamp);
        assertEq(duration, 365 days);
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
        _setAssetConfig(address(weth), false);
        _setTreasuryShare(0);
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        weth.mint(yielder, 2e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 2e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        (,,, uint256 max1,, uint256 start1,) = grai.auctions(address(weth));
        assertEq(max1, 2000e6); // 1 WETH @ $2000

        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();

        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();

        (, uint256 remaining, uint256 initial, uint256 max2,, uint256 start2,) = grai.auctions(address(weth));
        assertEq(remaining, 2e18);
        assertEq(initial, 2e18);
        assertEq(max2, 4000e6);
        assertGt(start2, start1);
        assertEq(start2, block.timestamp);
    }

    function test_DistributeSettlementAssetSkipsAuction() public {
        vm.startPrank(admin);
        grai.setSettlementAsset(address(usdc));
        _setAssetConfig(address(usdc), false);
        _setTreasuryShare(2_000);
        vm.stopPrank();

        usdc.mint(yielder, 100e6);
        vm.startPrank(yielder);
        usdc.approve(address(grai), 100e6);
        grai.distribute(address(usdc), 100e6);
        vm.stopPrank();

        // 80% yield stays as settlementAsset; 20% to treasury (admin)
        assertEq(usdc.balanceOf(address(grai)), 80e6);
        assertEq(usdc.balanceOf(admin), 20e6);
        assertEq(grai.getAuctions().length, 0);
    }

    function test_PartialFillAuction() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), false);
        _setTreasuryShare(0);
        grai.setSettlementAsset(address(usdc));
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

        (, uint256 remaining, uint256 initial, uint256 maxPayment,,,) = grai.auctions(address(weth));
        assertEq(remaining, 0.5e18);
        assertEq(initial, 1e18);
        assertEq(maxPayment, 2000e6);
        assertEq(grai.getAuctions().length, 1);
    }

    function test_DepositIsOneToOneUsd() public {
        _deposit(alice, usdc, 1000e6);
        assertEq(grai.balanceOf(alice), 1000e6);
        assertEq(grai.totalValue(), 1000e6);

        _deposit(alice, weth, 1e18);
        assertEq(grai.balanceOf(alice), 1000e6 + 2000e6);
        assertEq(grai.totalValue(), 3000e6);
    }

    function test_SetSettlementAssetRequiresFeed() public {
        address unknown = makeAddr("unknown");
        vm.prank(admin);
        vm.expectRevert(IGRAI.AssetUnknown.selector);
        grai.setSettlementAsset(unknown);
    }

    function test_SetSettlementAssetAuctionsPreviousInventory() public {
        vm.startPrank(admin);
        grai.setSettlementAsset(address(usdc));
        _setAssetConfig(address(usdc), false);
        _setTreasuryShare(0);
        vm.stopPrank();

        // Accrue settlement inventory on GRAI (no auction while it is settlement).
        usdc.mint(yielder, 100e6);
        vm.startPrank(yielder);
        usdc.approve(address(grai), 100e6);
        grai.distribute(address(usdc), 100e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(grai)), 100e6);
        assertEq(grai.getAuctions().length, 0);

        // Switch settlement to WETH: prior USDC must be listed for sale in WETH.
        vm.prank(admin);
        grai.setSettlementAsset(address(weth));

        (address asset, uint256 remaining,,,,, uint32 duration) = grai.auctions(address(usdc));
        assertEq(asset, address(usdc));
        assertEq(remaining, 100e6);
        assertEq(duration, 365 days);
        assertEq(grai.getAuctions().length, 1);
        assertEq(grai.settlementAsset(), address(weth));
    }

    function test_SetSettlementAssetRevertsWhileVotesOpen() public {
        vm.prank(admin);
        grai.setSettlementAsset(address(usdc));

        _deposit(alice, usdc, 1000e6);
        vm.prank(alice);
        grai.vote(500e6);
        assertGt(grai.totalVoted(), 0);

        vm.prank(admin);
        vm.expectRevert(IGRAI.VotesOpen.selector);
        grai.setSettlementAsset(address(weth));
    }

    function test_FillRevertsWhenPaymentMaxTooLow() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), false);
        _setTreasuryShare(0);
        grai.setSettlementAsset(address(usdc));
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

    function test_BuybackSwapsSettlementAssetForGraiAndHoldsIt() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);
        MockBuybackRouter router = new MockBuybackRouter();
        vm.prank(bob);
        grai.transfer(address(router), 10e6);
        deal(address(usdc), address(grai), 10e6, true);

        bytes memory data =
            abi.encodeCall(router.swap, (IERC20(address(usdc)), IERC20(address(grai)), 10e6, 10e6, address(grai)));
        vm.prank(admin);
        (uint256 payment, uint256 graiOut) = grai.buyback(address(router), data, 10e6);

        assertEq(payment, 10e6);
        assertEq(graiOut, 10e6);
        assertEq(grai.totalValue(), 200e6);
        assertEq(grai.totalSupply(), 200e6);
        assertEq(usdc.balanceOf(address(grai)), 0);
        assertEq(grai.balanceOf(address(grai)), 10e6);

        uint256 deposited = _deposit(alice, usdc, 10e6);
        assertEq(deposited, 10e6);
        assertEq(grai.totalValue(), 210e6);
        assertEq(grai.totalSupply(), 210e6);
    }

    function test_BribeBuysOutVoteForSettlementPayment() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);

        vm.prank(alice);
        grai.vote(50e6);

        uint256 bribeAmount = grai.previewBribe(alice, 50e6);
        assertEq(bribeAmount, 51e6); // book value + 2%
        uint256 bookAmount = 50e6;
        uint256 premiumAmount = 1e6;
        uint256 treasuryCut = (premiumAmount * DEFAULT_TREASURY_SHARE) / BPS;
        uint256 buybackKeep = premiumAmount - treasuryCut;

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(admin);
        uint256 graiUsdcBefore = usdc.balanceOf(address(grai));
        vm.startPrank(bob);
        usdc.approve(address(grai), bribeAmount);
        grai.bribe(alice, 50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, bookAmount);
        assertEq(usdc.balanceOf(admin) - treasuryBefore, treasuryCut);
        assertEq(usdc.balanceOf(address(grai)) - graiUsdcBefore, buybackKeep);
        assertEq(grai.balanceOf(bob), 150e6); // 100 held + 50 bought-out vote
        assertEq(grai.totalVoted(), 0);
    }

    function test_NativeBribeRefundsExcessValue() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        ethFeed = new MockAggregator(8, 1000e8);
        _setChainlinkFeed(address(0), address(ethFeed));
        _setAssetConfig(address(0), false);
        _setTreasuryShare(DEFAULT_TREASURY_SHARE);
        grai.setSettlementAsset(address(0));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);
        vm.prank(alice);
        grai.vote(50e6);

        uint256 bribeAmount = grai.previewBribe(alice, 50e6);
        // ETH @$1000: book for $50 = 0.05 ETH; premium 2% → bribeAmount = 0.051 ETH
        uint256 bookAmount = bribeAmount * BPS / (BPS + 200);
        uint256 premiumAmount = bribeAmount - bookAmount;
        uint256 treasuryCut = (premiumAmount * DEFAULT_TREASURY_SHARE) / BPS;
        uint256 buybackKeep = premiumAmount - treasuryCut;
        uint256 excess = 1 ether;
        vm.deal(bob, bribeAmount + excess);
        uint256 aliceEthBefore = alice.balance;
        uint256 treasuryBefore = admin.balance;

        vm.prank(bob);
        grai.bribe{value: bribeAmount + excess}(alice, 50e6);

        assertEq(alice.balance - aliceEthBefore, bookAmount);
        assertEq(bob.balance, excess);
        assertEq(admin.balance - treasuryBefore, treasuryCut);
        assertEq(address(grai).balance, buybackKeep);
        assertEq(grai.balanceOf(bob), 150e6);
    }

    function test_BuybackRewardsArePaidBeforeVoterRemoval() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);

        MockBuybackRouter router = new MockBuybackRouter();
        vm.prank(bob);
        grai.transfer(address(router), 10e6);
        deal(address(usdc), address(grai), 10e6, true);
        bytes memory data =
            abi.encodeCall(router.swap, (IERC20(address(usdc)), IERC20(address(grai)), 10e6, 10e6, address(grai)));
        vm.prank(admin);
        grai.buyback(address(router), data, 10e6);

        uint256 bribeAmount = grai.previewBribe(alice, 100e6);
        uint256 aliceGraiBefore = grai.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(grai), bribeAmount);
        grai.bribe(alice, 100e6);
        vm.stopPrank();

        assertEq(grai.balanceOf(alice) - aliceGraiBefore, 10e6);
        (uint256 amount,,,,) = grai.votes(alice);
        assertEq(amount, 0);
    }

    function test_OneGraiBuybackRewardSplitsProRataBetweenAliceAndBob() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 200e6);
        usdc.mint(admin, 1e6);
        _deposit(admin, usdc, 1e6);

        vm.prank(alice);
        grai.vote(100e6);
        vm.prank(bob);
        grai.vote(200e6);

        MockBuybackRouter router = new MockBuybackRouter();
        vm.prank(admin);
        grai.transfer(address(router), 1e6);
        deal(address(usdc), address(grai), 1e6, true);
        bytes memory data =
            abi.encodeCall(router.swap, (IERC20(address(usdc)), IERC20(address(grai)), 1e6, 1e6, address(grai)));
        vm.prank(admin);
        grai.buyback(address(router), data, 1e6);

        assertEq(grai.rewardPerVote(), 3_333_333_333_333_333);
        assertEq(grai.pendingVoteRewards(), 1); // one 1e-6 GRAI unit remains from integer rounding

        uint256 aliceGraiBefore = grai.balanceOf(alice);
        uint256 bobGraiBefore = grai.balanceOf(bob);
        uint256 aliceBribe = grai.previewBribe(alice, 100e6);
        uint256 bobBribe = grai.previewBribe(bob, 200e6);
        usdc.mint(admin, aliceBribe + bobBribe);

        vm.startPrank(admin);
        usdc.approve(address(grai), aliceBribe + bobBribe);
        grai.bribe(alice, 100e6);
        grai.bribe(bob, 200e6);
        vm.stopPrank();

        assertEq(grai.balanceOf(alice) - aliceGraiBefore, 333_333);
        assertEq(grai.balanceOf(bob) - bobGraiBefore, 666_666);
        assertEq(grai.totalVoted(), 0);
    }

    function test_LiquidationCreditsVoteRewardToHolderBalance() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);

        MockBuybackRouter router = new MockBuybackRouter();
        vm.prank(bob);
        grai.transfer(address(router), 10e6);
        deal(address(usdc), address(grai), 10e6, true);
        bytes memory data =
            abi.encodeCall(router.swap, (IERC20(address(usdc)), IERC20(address(grai)), 10e6, 10e6, address(grai)));
        vm.prank(admin);
        grai.buyback(address(router), data, 10e6);

        vm.prank(bob);
        grai.vote(90e6);
        vm.prank(admin);
        grai.resolve();
        deal(address(usdc), address(grai), 200e6, true);

        (,,,, uint32 liquidationPeriod,) = grai.config();
        vm.warp(block.timestamp + liquidationPeriod);
        vm.prank(alice);
        grai.liquidate(100e6);

        assertEq(grai.balanceOf(alice), 10e6);
    }

    function test_VoterCanSelfBribePayingOnlyPremium() public {
        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        vm.prank(alice);
        grai.vote(50e6);

        vm.prank(alice);
        vm.expectRevert(IGRAI.AmountZero.selector);
        grai.vote(0);

        uint256 bribeAmount = grai.previewBribe(alice, 50e6);
        assertEq(bribeAmount, 51e6);
        uint256 premiumAmount = 1e6;
        uint256 treasuryCut = (premiumAmount * DEFAULT_TREASURY_SHARE) / BPS;
        uint256 buybackKeep = premiumAmount - treasuryCut;

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(admin);
        uint256 graiUsdcBefore = usdc.balanceOf(address(grai));
        vm.startPrank(alice);
        usdc.approve(address(grai), bribeAmount);
        grai.bribe(alice, 50e6);
        vm.stopPrank();

        assertEq(usdcBefore - usdc.balanceOf(alice), premiumAmount);
        assertEq(usdc.balanceOf(admin) - treasuryBefore, treasuryCut);
        assertEq(usdc.balanceOf(address(grai)) - graiUsdcBefore, buybackKeep);
        assertEq(grai.balanceOf(alice), 100e6);
        assertEq(grai.totalVoted(), 0);
    }

    function test_RedeemOnlyDuringLiquidationAndProRata() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);

        vm.prank(alice);
        vm.expectRevert(IGRAI.LiquidationClosed.selector);
        grai.liquidate(100e6);

        vm.prank(alice);
        grai.vote(100e6);
        vm.prank(bob);
        grai.vote(100e6);
        vm.prank(admin);
        grai.resolve();
        assertEq(grai.liquidationAt(), block.timestamp);

        // Simulate Grinders returning liquidated USDC directly to GRAI.
        deal(address(usdc), address(grai), 200e6, true);

        (,,,, uint32 liquidationPeriod, uint32 redeemPeriod) = grai.config();

        vm.prank(alice);
        vm.expectRevert(IGRAI.LiquidationDelay.selector);
        grai.liquidate(100e6);

        vm.warp(block.timestamp + liquidationPeriod);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        grai.liquidate(100e6);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);
        assertEq(grai.totalValue(), 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        grai.liquidate(100e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6);
        assertEq(grai.totalValue(), 0);
        assertEq(grai.totalSupply(), 0);

        deal(address(usdc), address(grai), 1e6, true);
        uint256 grindersBefore = usdc.balanceOf(address(grinders));

        vm.prank(admin);
        vm.expectRevert(IGRAI.RedeemPeriodActive.selector);
        grai.resolve();

        vm.warp(block.timestamp + redeemPeriod);
        vm.prank(admin);
        grai.resolve();
        assertFalse(grai.liquidation());
        assertEq(grai.liquidationAt(), 0);
        (,, bool paused) = grai.assets(address(usdc));
        assertFalse(paused);
        assertEq(usdc.balanceOf(address(grinders)) - grindersBefore, 1e6);
        assertEq(usdc.balanceOf(address(grai)), 0);
        assertEq(grai.totalValue(), 0);
    }

    function test_LiquidationClosePreservesUnredeemedBookValue() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        _deposit(alice, usdc, 100e6);
        _deposit(bob, usdc, 100e6);

        vm.prank(alice);
        grai.vote(100e6);
        vm.prank(bob);
        grai.vote(100e6);
        vm.prank(admin);
        grai.resolve();

        deal(address(usdc), address(grai), 200e6, true);

        (,,,, uint32 liquidationPeriod, uint32 redeemPeriod) = grai.config();
        vm.warp(block.timestamp + liquidationPeriod);
        vm.prank(alice);
        grai.liquidate(100e6);

        assertEq(grai.totalValue(), 100e6);
        assertEq(grai.totalSupply(), 100e6);

        uint256 grindersBefore = usdc.balanceOf(address(grinders));
        vm.warp(block.timestamp + redeemPeriod);
        vm.prank(admin);
        grai.resolve();

        assertEq(usdc.balanceOf(address(grinders)) - grindersBefore, 100e6);
        assertEq(grai.totalValue(), 100e6);
        assertEq(grai.totalSupply(), 100e6);
    }

    function test_LiquidationCancelsAuctionsIntoRedemptionBasket() public {
        vm.startPrank(admin);
        _setAssetConfig(address(weth), false);
        _setTreasuryShare(0);
        grai.setSettlementAsset(address(usdc));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);

        weth.mint(yielder, 1e18);
        vm.startPrank(yielder);
        weth.approve(address(grai), 1e18);
        grai.distribute(address(weth), 1e18);
        vm.stopPrank();
        assertEq(grai.getAuctions().length, 1);

        vm.prank(admin);
        grai.resolve();
        assertEq(grai.getAuctions().length, 0);
        (,,,, uint32 liquidationPeriod,) = grai.config();
        vm.warp(block.timestamp + liquidationPeriod);

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        grai.liquidate(100e6);
        assertEq(weth.balanceOf(alice) - wethBefore, 1e18);
    }
}
