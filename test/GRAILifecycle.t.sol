// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

/// @dev End-to-end happy path: gradual deposits → yield → claims → liquidate → redeem → resettle.
contract GRAILifecycleTest is GRAIFixture {
    address carol = makeAddr("carol");

    uint256 constant USDC_TOTAL = 1_000e6;
    uint256 constant ETH_TOTAL = 3 ether;
    uint256 constant YIELD_USDC = 90e6;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        // Native ETH deposits / redeem basket (same ETH/USD feed as WETH).
        _setChainlinkFeed(address(0), address(wethFeed));
        _setAssetConfig(address(0), false);
        vm.stopPrank();

        // Extra USDC beyond the fixture's 1_000e6 Alice/Bob mints (Carol + yield payer).
        usdc.mint(alice, 500e6);
        usdc.mint(bob, 500e6);
        usdc.mint(carol, 1_000e6);
        vm.deal(alice, 2 ether);
        vm.deal(bob, 2 ether);
        vm.deal(carol, 2 ether);
    }

    function test_DepositYieldClaimLiquidateRedeemResettle() public {
        // ── 1. Gradual deposits: 1000 USDC + 3 ETH across Alice / Bob / Carol ──
        _depositUsdc(alice, 200e6);
        _depositUsdc(bob, 150e6);
        _depositUsdc(carol, 150e6);
        _depositUsdc(alice, 200e6);
        _depositUsdc(bob, 150e6);
        _depositUsdc(carol, 150e6);

        _depositEth(alice, 1 ether);
        _depositEth(bob, 1 ether);
        _depositEth(carol, 1 ether);

        assertEq(usdc.balanceOf(address(grinders)), USDC_TOTAL, "usdc on grinders");
        assertEq(address(grinders).balance, ETH_TOTAL, "eth on grinders");

        uint256 aliceGrai = grai.balanceOf(alice);
        uint256 bobGrai = grai.balanceOf(bob);
        uint256 carolGrai = grai.balanceOf(carol);
        uint256 supply = grai.totalSupply();
        assertEq(aliceGrai + bobGrai + carolGrai, supply, "all minted GRAI held by depositors");
        assertGt(supply, 0);

        // Book: $1000 USDC + 3 ETH * $2000 = $7000 → 7000e6 GRAI at bootstrap parity.
        assertEq(supply, 7_000e6, "book mint at $1/GRAI");
        assertEq(aliceGrai, 2_400e6); // 400 USDC + 1 ETH
        assertEq(bobGrai, 2_300e6); // 300 USDC + 1 ETH
        assertEq(carolGrai, 2_300e6);

        // ── 2. Lock (unvoted) so everyone is dividend-eligible ──
        _lock(alice, aliceGrai);
        _lock(bob, bobGrai);
        _lock(carol, carolGrai);
        assertEq(grai.totalLocked(), supply);

        // ── 3. Protocol income → auction / dividend / treasury cuts ──
        uint256 treasuryBefore = usdc.balanceOf(admin);
        usdc.mint(address(this), YIELD_USDC);
        usdc.approve(address(grai), YIELD_USDC);
        grai.distribute(address(usdc), YIELD_USDC);

        IGRAI.Config memory cfg = _readConfig();
        uint256 dividendCut = (YIELD_USDC * cfg.dividendCutBps) / BPS;
        uint256 treasuryCut = (YIELD_USDC * cfg.treasuryCutBps) / BPS;
        assertEq(usdc.balanceOf(admin) - treasuryBefore, treasuryCut, "treasury cut");
        assertGt(dividendCut, 0, "dividend cut");

        // ── 4. Everyone claims USDC dividends ──
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);

        uint256 aliceClaim = grai.previewClaim(alice, address(usdc), type(uint256).max);
        uint256 bobClaim = grai.previewClaim(bob, address(usdc), type(uint256).max);
        uint256 carolClaim = grai.previewClaim(carol, address(usdc), type(uint256).max);
        assertGt(aliceClaim, 0);
        assertGt(bobClaim, 0);
        assertGt(carolClaim, 0);
        // Per-locker floor can leave 1 wei unreserved vs full dividendCut.
        assertApproxEqAbs(aliceClaim + bobClaim + carolClaim, dividendCut, 1, "dividend to lockers");

        vm.prank(alice);
        grai.claimAll(alice);
        vm.prank(bob);
        grai.claimAll(bob);
        vm.prank(carol);
        grai.claimAll(carol);

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, aliceClaim);
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, bobClaim);
        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, carolClaim);
        assertEq(grai.previewClaim(alice, address(usdc), type(uint256).max), 0);
        assertEq(grai.previewClaim(bob, address(usdc), type(uint256).max), 0);
        assertEq(grai.previewClaim(carol, address(usdc), type(uint256).max), 0);

        // ── 5. Vote to quorum → owner opens liquidation ──
        _vote(alice, aliceGrai);
        _vote(bob, bobGrai);
        _vote(carol, carolGrai);
        assertTrue(grai.hasQuorum());

        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation());
        assertEq(uint256(grai.liquidationAt()), block.timestamp);

        // ── 6. Consolidation: sweep Grinders idle → GRAI, then redeem window ──
        vm.warp(block.timestamp + uint256(cfg.liquidationPeriod));

        vm.prank(bob);
        grinders.liquidate();
        assertEq(usdc.balanceOf(address(grinders)), 0, "idle usdc swept");
        assertEq(address(grinders).balance, 0, "idle eth swept");
        assertEq(address(grai).balance, ETH_TOTAL, "eth basket on grai");
        (,,, uint256 auctionRemaining,,,) = grai.auctions(address(usdc));
        assertEq(auctionRemaining, 0, "auctions cleared at liquidate");
        // Deposits + Dutch buyback cut; ±1 wei sticky dividend reserve dust.
        uint256 buybackCut = YIELD_USDC - treasuryCut - dividendCut;
        assertApproxEqAbs(usdc.balanceOf(address(grai)), USDC_TOTAL + buybackCut, 1, "usdc basket");

        // ── 7. Everyone redeems full escrow ──
        uint256 aliceUsdcRedeemBefore = usdc.balanceOf(alice);
        uint256 bobUsdcRedeemBefore = usdc.balanceOf(bob);
        uint256 carolUsdcRedeemBefore = usdc.balanceOf(carol);
        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore = bob.balance;
        uint256 carolEthBefore = carol.balance;

        _redeemAll(alice);
        _redeemAll(bob);
        _redeemAll(carol);

        assertEq(grai.totalSupply(), 0, "all shares burned");
        assertEq(grai.totalLocked(), 0);
        assertEq(grai.totalVoted(), 0);

        // Pro-rata of $2400 / $2300 / $2300 against $7000 book → USDC+ETH basket.
        assertGt(usdc.balanceOf(alice) - aliceUsdcRedeemBefore, 0);
        assertGt(usdc.balanceOf(bob) - bobUsdcRedeemBefore, 0);
        assertGt(usdc.balanceOf(carol) - carolUsdcRedeemBefore, 0);
        assertGt(alice.balance - aliceEthBefore, 0);
        assertGt(bob.balance - bobEthBefore, 0);
        assertGt(carol.balance - carolEthBefore, 0);

        // Dust may remain from integer division across three redeemers.
        assertLe(usdc.balanceOf(address(grai)), 2);
        assertLe(address(grai).balance, 2);

        // ── 8. Resettle after redeemPeriod ──
        vm.warp(block.timestamp + uint256(cfg.redeemPeriod));
        vm.prank(carol);
        grai.resettle();

        assertFalse(grai.liquidation());
        assertEq(uint256(grai.liquidationAt()), 0);
        assertEq(grai.totalValue(), 0);
        assertFalse(grai.confirmed());
    }

    ////////////////////////////// HELPERS //////////////////////////////

    function _depositUsdc(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(grai), amount);
        grai.deposit(address(usdc), amount, false);
        vm.stopPrank();
    }

    function _depositEth(address user, uint256 amount) internal {
        vm.prank(user);
        grai.deposit{value: amount}(address(0), amount, false);
    }

    function _lock(address user, uint256 amount) internal {
        vm.prank(user);
        grai.lock(amount);
    }

    function _vote(address user, uint256 amount) internal {
        vm.prank(user);
        grai.vote(amount);
    }

    function _redeemAll(address user) internal {
        (,, uint256 amount,,,,) = grai.escrows(user);
        vm.prank(user);
        grai.redeem(amount);
    }
}
