// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

/// @dev Voting keeps dividend eligibility on full `locked`; bribe shrinks future share.
contract GRAIVotedDividendsTest is GRAIFixture {
    address briber = makeAddr("briber");

    uint256 constant DEPOSIT = 100e6;
    uint256 constant YIELD = 20e6;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        grai.setGrinders(address(grinders));
        _setBribeable(address(usdc), true);

        usdc.mint(briber, 10_000e6);
    }

    /// Fully voted locker still earns after `distribute`.
    function test_Vote_KeepsDividends() public {
        _depositAndVoteAll(alice, DEPOSIT);

        uint256 dividendCut = _distributeUsdc(YIELD);
        uint256 pending = grai.previewClaim(alice, address(usdc), type(uint256).max);
        assertGt(pending, 0, "voted locker earns");
        assertApproxEqAbs(pending, dividendCut, 1, "sole locker gets full dividend cut");

        vm.prank(alice);
        grai.claim(alice, address(usdc), type(uint256).max);
        assertEq(grai.previewClaim(alice, address(usdc), type(uint256).max), 0);
    }

    /// Two equal locks; one fully votes — both earn pro-rata on `locked`.
    function test_VotedAndUnvoted_ShareProRata() public {
        _depositLock(alice, DEPOSIT);
        _depositLock(bob, DEPOSIT);

        (,, uint256 aliceLocked,,,) = grai.escrows(alice);
        vm.prank(alice);
        grai.vote(aliceLocked);

        uint256 dividendCut = _distributeUsdc(YIELD);
        uint256 alicePending = grai.previewClaim(alice, address(usdc), type(uint256).max);
        uint256 bobPending = grai.previewClaim(bob, address(usdc), type(uint256).max);

        assertGt(alicePending, 0, "voter earns");
        assertGt(bobPending, 0, "non-voter earns");
        assertApproxEqAbs(alicePending, bobPending, 1, "equal locks -> equal dividends");
        assertApproxEqAbs(alicePending + bobPending, dividendCut, 1, "full cut to lockers");
    }

    /// Accrue while voted, bribe part of vote → keep pre-bribe claimable; later yield uses reduced lock vs peer.
    function test_Bribe_ShrinksFutureDividendShare() public {
        _depositLock(alice, DEPOSIT);
        _depositLock(bob, DEPOSIT);
        (,, uint256 aliceLocked,,,) = grai.escrows(alice);
        vm.prank(alice);
        grai.vote(aliceLocked);

        uint256 firstCut = _distributeUsdc(YIELD);
        uint256 aliceAccrued = grai.previewClaim(alice, address(usdc), type(uint256).max);
        uint256 bobAccrued = grai.previewClaim(bob, address(usdc), type(uint256).max);
        assertApproxEqAbs(aliceAccrued, bobAccrued, 1, "equal locks before bribe");
        assertApproxEqAbs(aliceAccrued + bobAccrued, firstCut, 1);

        uint256 bribeGrai = aliceLocked / 2;
        (uint256 ask,,) = grai.previewBribe(address(usdc), alice, bribeGrai);
        vm.startPrank(briber);
        usdc.approve(address(grai), ask);
        grai.bribe(address(usdc), alice, bribeGrai);
        vm.stopPrank();

        (,, uint256 aliceLockedAfter, uint256 aliceVotedAfter,,) = grai.escrows(alice);
        assertEq(aliceLockedAfter, aliceLocked - bribeGrai);
        assertEq(aliceVotedAfter, aliceLocked - bribeGrai);
        // Bribe cutPool may add extra dividends; never wipe the pre-bribe accrual.
        assertGe(
            grai.previewClaim(alice, address(usdc), type(uint256).max),
            aliceAccrued,
            "pre-bribe claimable preserved"
        );

        vm.prank(alice);
        grai.claim(alice, address(usdc), type(uint256).max);
        vm.prank(bob);
        grai.claim(bob, address(usdc), type(uint256).max);

        // Second harvest: alice L/2, bob L → alice ~1/3, bob ~2/3 of the cut.
        uint256 secondCut = _distributeUsdc(YIELD);
        uint256 aliceSecond = grai.previewClaim(alice, address(usdc), type(uint256).max);
        uint256 bobSecond = grai.previewClaim(bob, address(usdc), type(uint256).max);
        assertApproxEqAbs(aliceSecond + bobSecond, secondCut, 1, "full second cut to lockers");
        assertApproxEqAbs(aliceSecond * 2, bobSecond, bobSecond / 50, "alice half of bob after bribe");
        assertLt(aliceSecond, bobSecond, "bribe shrank alice share vs bob");
    }

    ////////////////////////////// HELPERS //////////////////////////////

    function _depositLock(address user, uint256 usdcAmount) internal returns (uint256 minted) {
        vm.startPrank(user);
        usdc.approve(address(grai), usdcAmount);
        grai.deposit(address(usdc), usdcAmount, true, address(0));
        vm.stopPrank();
        (,, minted,,,) = grai.escrows(user);
        assertGt(minted, 0);
    }

    function _depositAndVoteAll(address user, uint256 usdcAmount) internal returns (uint256 locked) {
        locked = _depositLock(user, usdcAmount);
        vm.prank(user);
        grai.vote(locked);
        (,, uint256 l, uint256 v,,) = grai.escrows(user);
        assertEq(l, locked);
        assertEq(v, locked);
    }

    function _distributeUsdc(uint256 amount) internal returns (uint256 dividendCut) {
        IGRAI.Config memory cfg = _readConfig();
        dividendCut = (amount * cfg.dividendCutBps) / BPS;
        usdc.mint(address(this), amount);
        usdc.approve(address(grai), amount);
        grai.distribute(address(usdc), amount);
    }
}
