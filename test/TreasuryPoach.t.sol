// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

/// @dev Poach + Treasury tree accounting.
///
/// Canonical tree used across scenarios (unless noted):
///   Alice deposits 100, ref=0     → referrer=Alice, NFT∈Alice
///   Bob   deposits  40, ref=Alice → referrer=Alice, NFT∈Bob
///   Carol deposits  25, ref=Bob   → referrer=Bob,   NFT∈Carol
///
/// referralBooks after setup:
///   Alice: value=100, l1=40, l2=25
///   Bob:   value=40,  l1=25, l2=0
///   Carol: value=25,  l1=0,  l2=0
///
/// poach ask = value + l1Value (not l2Value):
///   Alice=140, Bob=65, Carol=25
/// Poach rewrites sticky referrer only; cashflow NFT ownership is unchanged.
contract TreasuryPoachTest is GRAIFixture {
    address carol = makeAddr("carol");
    address dias = makeAddr("dias");
    address eve = makeAddr("eve");
    address paul = makeAddr("paul");
    address beneficiar = makeAddr("beneficiar");

    uint16 constant REVENUE_SHARE_BPS = 1_000;
    uint256 constant YIELD = 100e6;
    uint256 constant DIVIDEND = 30e6;
    uint256 constant GROSS_PROFIT_SHARE = 20e6;
    uint256 constant REVENUE = 10e6;
    uint256 constant L1_FULL = 8e6;
    uint256 constant L2_FULL = 2e6;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        _setYieldSplitFiftyThirtyTwenty();
        grai.setConfig(IGRAI.ConfigId.REVENUE_SHARE, REVENUE_SHARE_BPS);
        treasury.setBeneficiar(beneficiar);
        vm.stopPrank();

        usdc.mint(carol, 1_000e6);
        usdc.mint(dias, 1_000e6);
        usdc.mint(eve, 1_000e6);
        usdc.mint(paul, 1_000e6);
    }

    /// 1. Bob 100 → Alice (Alice becomes stub)
    /// 2. Bob 200 → sticky ignored
    /// 3. Carol 300 → Bob
    /// 4. Carol2 301 → Bob
    /// 5. Dias poaches Bob (seller = Alice stub identity; Alice herself stays unbound)
    function test_BobUnderAlice_TwoCarols_DiasPoachBob() public {
        address carol2 = makeAddr("carol2");
        usdc.mint(carol2, 1_000e6);

        // 1. Bob deposits 100, ref=Alice → Alice stub, Bob.l1 walk into Alice
        _deposit(bob, 100e6, alice);
        assertEq(treasury.referrerOf(bob), alice);
        assertEq(treasury.referrerOf(alice), address(0));
        _assertNode(bob, 100e6, 0, 0);
        _assertNode(alice, 0, 100e6, 0);

        // 2. Bob deposits 200, no ref → sticky kept; Alice.l1 += 200
        _deposit(bob, 200e6, address(0));
        assertEq(treasury.referrerOf(bob), alice);
        _assertNode(bob, 300e6, 0, 0);
        _assertNode(alice, 0, 300e6, 0);

        // 3. Carol deposits 300, ref=Bob → Bob.l1 += 300, Alice.l2 += 300
        _deposit(carol, 300e6, bob);
        assertEq(treasury.referrerOf(carol), bob);
        _assertNode(carol, 300e6, 0, 0);
        _assertNode(bob, 300e6, 300e6, 0);
        _assertNode(alice, 0, 300e6, 300e6);

        // 4. Carol2 deposits 301, ref=Bob → Bob.l1 += 301, Alice.l2 += 301
        _deposit(carol2, 301e6, bob);
        assertEq(treasury.referrerOf(carol2), bob);
        _assertNode(carol2, 301e6, 0, 0);
        _assertNode(bob, 300e6, 601e6, 0);
        _assertNode(alice, 0, 300e6, 601e6);

        // 5. Dias poaches Bob: ask = value+l1 = 300+601 = 901; seller = Alice
        _deposit(dias, 1_000e6, address(0));
        uint256 aliceGraiBefore = grai.balanceOf(alice);
        (uint256 ask, address seller) = treasury.poachOf(bob, dias);
        assertEq(seller, alice);
        assertEq(ask, 901e6);

        vm.prank(dias);
        grai.poach(bob);

        assertEq(treasury.referrerOf(bob), dias);
        assertEq(treasury.referrerOf(alice), address(0), "Alice remains unbound stub");
        assertEq(treasury.ownerOf(uint256(uint160(bob))), bob, "cashflow NFT stays with Bob");
        assertEq(grai.balanceOf(alice), aliceGraiBefore + 901e6);

        // Alice sold Bob seat: l1/l2 debited
        _assertNode(alice, 0, 0, 0);
        // Dias bought Bob: l1+=Bob.value, l2+=Bob.l1
        _assertNode(dias, 1_000e6, 300e6, 601e6);
        // Bob / downline node books unchanged
        _assertNode(bob, 300e6, 601e6, 0);
        _assertNode(carol, 300e6, 0, 0);
        _assertNode(carol2, 301e6, 0, 0);
    }

    ////////////////////////////// mint / referralBooks //////////////////////////////

    /// 1. Alice deposits with no referrer (self-slot).
    /// 2. Dias poach ask = Alice.value + Alice.l1Value = deposit book (no downline yet).
    function test_Poach_AliceSelfDeposit_DiasAskEqualsOwnValue() public {
        _deposit(alice, 100e6, address(0));

        assertEq(treasury.referrerOf(alice), alice);
        _assertNode(alice, 100e6, 0, 0);

        (uint256 price, address seller) = treasury.poachOf(alice, dias);
        assertEq(seller, alice);
        assertEq(price, 100e6); // value + l1Value = 100 + 0

        _deposit(dias, 100e6, address(0));
        uint256 aliceGraiBefore = grai.balanceOf(alice);
        vm.prank(dias);
        grai.poach(alice);

        assertEq(treasury.referrerOf(alice), dias);
        assertEq(grai.balanceOf(alice), aliceGraiBefore + 100e6);
        _assertNode(dias, 100e6, 100e6, 0); // l1 += alice.value on self-poach
    }

    function test_Tree_AfterDeposits_L1L2AndPoachAsks() public {
        _seedTree();

        _assertNode(alice, 100e6, 40e6, 25e6);
        _assertNode(bob, 40e6, 25e6, 0);
        _assertNode(carol, 25e6, 0, 0);

        assertEq(treasury.referrerOf(alice), alice);
        assertEq(treasury.referrerOf(bob), alice);
        assertEq(treasury.referrerOf(carol), bob);

        (uint256 pAlice,) = treasury.poachOf(alice, dias);
        (uint256 pBob,) = treasury.poachOf(bob, dias);
        (uint256 pCarol,) = treasury.poachOf(carol, dias);
        assertEq(pAlice, 140e6);
        assertEq(pBob, 65e6);
        assertEq(pCarol, 25e6);
    }

    function test_Tree_SecondDeposit_AccruesOwnValueOnly() public {
        _deposit(alice, 100e6, address(0));
        _deposit(alice, 50e6, bob); // sticky self; referrer ignored

        assertEq(treasury.referrerOf(alice), alice);
        _assertNode(alice, 150e6, 0, 0);
        (uint256 price,) = treasury.poachOf(alice, bob);
        assertEq(price, 150e6);
    }

    function test_Tree_DepositAfterPoach_CreditsNewOwner() public {
        _seedTree();
        _fundAndPoach(dias, 140e6, alice);

        // New bob deposit while dias is sticky referrer of alice: dias is L2 on bob
        _deposit(bob, 10e6, alice); // sticky bob→alice
        // Bob already bound to alice; deposit accrues bob.value and alice.l1 / dias.l2
        _assertNode(bob, 50e6, 25e6, 0);
        _assertNode(alice, 100e6, 50e6, 25e6); // l1 += 10
        _assertNode(dias, 140e6, 100e6, 50e6); // l2 was 40, +=10 from bob deposit walk
    }

    ////////////////////////////// poach self-slot //////////////////////////////

    function test_Poach_Self_PaysLocker_AndCreditsBuyerBook() public {
        _seedTree();
        uint256 aliceId = uint256(uint160(alice));

        _deposit(dias, 140e6, address(0));
        (uint256 price, address seller) = treasury.poachOf(alice, dias);
        assertEq(price, 140e6);
        assertEq(seller, alice);

        uint256 aliceGraiBefore = grai.balanceOf(alice);
        uint256 diasGraiBefore = grai.balanceOf(dias);
        vm.prank(dias);
        grai.poach(alice);

        assertEq(treasury.referrerOf(alice), dias);
        assertEq(treasury.ownerOf(aliceId), alice, "poach does not move cashflow NFT");
        assertEq(grai.balanceOf(alice), aliceGraiBefore + price);
        assertEq(grai.balanceOf(dias), diasGraiBefore - price);

        // Alice keeps downline book (still referrer of bob); dias gains alice.value/l1 as l1/l2
        _assertNode(alice, 100e6, 40e6, 25e6);
        _assertNode(dias, 140e6, 100e6, 40e6);
        // Downline cashflow NFTs untouched; sticky refs untouched except alice
        assertEq(treasury.ownerOf(uint256(uint160(bob))), bob);
        assertEq(treasury.ownerOf(uint256(uint160(carol))), carol);
        assertEq(treasury.referrerOf(bob), alice);
        assertEq(treasury.referrerOf(carol), bob);
    }

    ////////////////////////////// poach non-self //////////////////////////////

    function test_Poach_NonSelf_PaysSeller_MovesL1L2Book() public {
        _seedTree();

        _deposit(paul, 65e6, address(0));
        (uint256 price, address seller) = treasury.poachOf(bob, paul);
        assertEq(price, 65e6);
        assertEq(seller, alice);

        uint256 aliceGraiBefore = grai.balanceOf(alice);
        vm.prank(paul);
        grai.poach(bob);

        assertEq(treasury.referrerOf(bob), paul);
        assertEq(grai.balanceOf(alice), aliceGraiBefore + price);
        assertEq(treasury.ownerOf(uint256(uint160(bob))), bob, "poach does not move cashflow NFT");
        assertEq(treasury.ownerOf(uint256(uint160(carol))), carol);

        _assertNode(alice, 100e6, 0, 0); // lost bob volume
        _assertNode(paul, 65e6, 40e6, 25e6); // gained bob.value / bob.l1
        (uint256 priceAlice,) = treasury.poachOf(alice, paul);
        assertEq(priceAlice, 100e6);
    }

    function test_Poach_NonSelf_WithUpline_CreditsNewL2() public {
        _seedTree();
        // Eve self-root, then Paul deposits under Eve, then Paul poaches Bob from Alice
        _deposit(eve, 1e6, address(0));
        _deposit(paul, 65e6, eve); // referrerOf(paul)=eve

        vm.prank(paul);
        grai.poach(bob);

        // Eve is new L2 on bob claims → +bob.value on eve.l2
        (,, uint256 eveL2,) = treasury.referralBooks(eve);
        assertEq(eveL2, 40e6);
        _assertNode(paul, 65e6, 40e6, 25e6);
        _assertNode(alice, 100e6, 0, 0);
    }

    ////////////////////////////// multi-step resale //////////////////////////////

    function test_Poach_DiasThenEveTakesBob_AskAndBooks() public {
        _seedTree();

        _fundAndPoach(dias, 140e6, alice);
        _assertNode(dias, 140e6, 100e6, 40e6);
        _assertNode(alice, 100e6, 40e6, 25e6);
        (uint256 priceAlice,) = treasury.poachOf(alice, eve);
        assertEq(priceAlice, 140e6);

        _fundAndPoach(eve, 65e6, bob);

        // Alice lost bob book; dias lost L2 on bob; eve holds bob book
        _assertNode(alice, 100e6, 0, 0);
        _assertNode(dias, 140e6, 100e6, 0);
        _assertNode(eve, 65e6, 40e6, 25e6);

        (priceAlice,) = treasury.poachOf(alice, eve);
        assertEq(priceAlice, 100e6);

        // Resale alice from dias → eve
        uint256 diasGraiBefore = grai.balanceOf(dias);
        // eve needs 100 more GRAI (already spent 65 on bob; has 0 left) — fund again
        _deposit(eve, 100e6, address(0));
        vm.prank(eve);
        grai.poach(alice);

        assertEq(treasury.referrerOf(alice), eve);
        assertEq(grai.balanceOf(dias), diasGraiBefore + 100e6);
        // eve gains alice.value as l1; dias loses that l1 credit (dias was non-self seller)
        _assertNode(dias, 140e6, 0, 0);
        (, uint256 eveL1,,) = treasury.referralBooks(eve);
        // eve already had 40 from bob + 100 from alice
        // prior eve.l1=40, eve.l2=25 → after: l1=140, l2=25
        assertEq(eveL1, 140e6);
    }

    function test_Poach_LeafCarol_PriceIsOwnValueOnly() public {
        _seedTree();
        _deposit(paul, 25e6, address(0));

        (uint256 price, address seller) = treasury.poachOf(carol, paul);
        assertEq(price, 25e6);
        assertEq(seller, bob);

        uint256 bobGraiBefore = grai.balanceOf(bob);
        vm.prank(paul);
        grai.poach(carol);

        assertEq(treasury.referrerOf(carol), paul);
        assertEq(grai.balanceOf(bob), bobGraiBefore + 25e6);
        // bob loses carol as l1; alice loses carol as l2
        _assertNode(bob, 40e6, 0, 0);
        _assertNode(alice, 100e6, 40e6, 0);
        _assertNode(paul, 25e6, 25e6, 0);
    }

    ////////////////////////////// revenueShare after poach //////////////////////////////

    function test_Info_AfterPoachAlice_DiasIsL1() public {
        _seedTree();
        _fundAndPoach(dias, 140e6, alice);

        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 1);
        assertEq(refs[0], dias);
        assertEq(shares[0], 8_000);

        // Bob: L1=alice (still sticky referrer of bob), L2=dias — payees are cashflow owners
        (refs, shares) = treasury.revenueShareInfo(bob, 10_000);
        assertEq(refs.length, 2);
        assertEq(refs[0], alice);
        assertEq(refs[1], dias);
        assertEq(shares[0], 8_000);
        assertEq(shares[1], 2_000);

        // Carol: L1=bob, L2=alice — dias not in top-2
        (refs, shares) = treasury.revenueShareInfo(carol, 10_000);
        assertEq(refs.length, 2);
        assertEq(refs[0], bob);
        assertEq(refs[1], alice);
    }

    function test_Claim_AfterPoachAlice_PaysDiasAsL1() public {
        _seedTree();
        _fundAndPoach(dias, 140e6, alice);

        _lock(alice, grai.balanceOf(alice));
        _yield(YIELD);

        uint256 diasBefore = usdc.balanceOf(dias);
        uint256 aliceBefore = usdc.balanceOf(alice);
        _claimMax(alice);

        // Alice was self → after poach L1=dias gets L1_FULL of affiliate; no L2
        // Affiliate pool REVENUE=10e6, L1=8e6 to dias; beneficiar gets rest of gross
        assertEq(usdc.balanceOf(dias) - diasBefore, L1_FULL);
        // locker tip stays with alice when self-claim; dividend path unchanged beyond affiliate
        assertGt(usdc.balanceOf(alice), aliceBefore);
    }

    function test_Claim_AfterPoachBob_PaulL1_AliceGoneFromBobUpline() public {
        _seedTree();
        _fundAndPoach(paul, 65e6, bob);

        _lock(bob, grai.balanceOf(bob));
        _yield(YIELD);

        uint256 paulBefore = usdc.balanceOf(paul);
        uint256 aliceBefore = usdc.balanceOf(alice);
        _claimMax(bob);

        // Bob upline: L1=paul only (paul self → no L2)
        assertEq(usdc.balanceOf(paul) - paulBefore, L1_FULL);
        assertEq(usdc.balanceOf(alice), aliceBefore);
    }

    ////////////////////////////// reverts //////////////////////////////

    function test_Poach_Reverts_Unbound() public {
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        grai.previewPoach(alice, bob);
    }

    function test_Poach_Reverts_InsufficientBalance() public {
        _seedTree();
        vm.expectRevert(IGRAI.InvalidAmount.selector);
        grai.previewPoach(alice, dias); // dias has 0 GRAI, ask = 140
    }

    function test_Poach_Reverts_AlreadyOwner() public {
        _deposit(alice, 100e6, address(0));
        vm.expectRevert(ITreasury.AlreadyBound.selector);
        vm.prank(alice);
        grai.poach(alice);
    }

    function test_Poach_Reverts_DownlineCreatesReferralLoop() public {
        _seedTree();
        // Bob under Alice; becoming Alice's referrer would cycle Alice ↔ Bob.
        _deposit(dias, 300e6, address(0));
        vm.prank(dias);
        assertTrue(grai.transfer(bob, 300e6));
        vm.expectRevert(ITreasury.ReferralLoop.selector);
        vm.prank(bob);
        grai.poach(alice);
    }

    function test_Poach_Reverts_DeeperDownlineCreatesReferralLoop() public {
        _seedTree();
        // Carol → Bob → Alice; poach(Alice) by Carol → cycle
        _deposit(dias, 300e6, address(0));
        vm.prank(dias);
        assertTrue(grai.transfer(carol, 300e6));
        vm.expectRevert(ITreasury.ReferralLoop.selector);
        vm.prank(carol);
        grai.poach(alice);
    }

    /// Deep acyclic upline (≥33 hops) must not false-positive as ReferralLoop (old 32-cap).
    function test_Poach_AllowsDeepAcyclicUpline() public {
        uint256 depth = 40;
        address[] memory chain = new address[](depth);
        for (uint256 i; i < depth; ++i) {
            chain[i] = makeAddr(string.concat("deep", vm.toString(i)));
            usdc.mint(chain[i], 200e6);
        }

        _deposit(chain[0], 1e6, address(0));
        for (uint256 i = 1; i < depth; ++i) {
            _deposit(chain[i], 1e6, chain[i - 1]);
        }

        _deposit(eve, 10e6, address(0));
        // Leaf already bound; top up GRAI to cover eve's poach ask (10).
        _deposit(chain[depth - 1], 20e6, address(0));

        vm.prank(chain[depth - 1]);
        grai.poach(eve);

        assertEq(treasury.referrerOf(eve), chain[depth - 1]);
    }

    function test_PoachOf_MatchesPreviewPoach() public {
        _seedTree();
        _deposit(paul, 65e6, address(0));
        (uint256 p1, address r1) = grai.previewPoach(bob, paul);
        (uint256 p2, address r2) = treasury.poachOf(bob, paul);
        assertEq(p1, p2);
        assertEq(r1, r2);
        assertEq(p1, 65e6);
        assertEq(r1, alice);
    }

    function test_GetReferralBooks_PaginatesEnumerableOrder() public {
        _seedTree();
        assertEq(treasury.totalSupply(), 3);

        ITreasury.LockerReferral[] memory all_ = treasury.getReferralBooks(0, 100);
        assertEq(all_.length, 3);

        bool sawAlice;
        bool sawBob;
        bool sawCarol;
        for (uint256 i; i < all_.length; ++i) {
            ITreasury.LockerReferral memory row = all_[i];
            if (row.locker == alice) {
                sawAlice = true;
                assertEq(row.referrer, alice);
                assertEq(row.book.value, 100e6);
                assertEq(row.book.l1Value, 40e6);
                assertEq(row.book.l2Value, 25e6);
            } else if (row.locker == bob) {
                sawBob = true;
                assertEq(row.referrer, alice);
                assertEq(row.book.value, 40e6);
                assertEq(row.book.l1Value, 25e6);
                assertEq(row.book.l2Value, 0);
            } else if (row.locker == carol) {
                sawCarol = true;
                assertEq(row.referrer, bob);
                assertEq(row.book.value, 25e6);
                assertEq(row.book.l1Value, 0);
                assertEq(row.book.l2Value, 0);
            } else {
                fail("unexpected locker");
            }
        }
        assertTrue(sawAlice && sawBob && sawCarol);

        assertEq(treasury.getReferralBooks(0, 2).length, 2);
        assertEq(treasury.getReferralBooks(2, 99).length, 1);
        assertEq(treasury.getReferralBooks(3, 5).length, 0);

        vm.expectRevert(abi.encodeWithSelector(ITreasury.InvalidRange.selector, 1, 1));
        treasury.getReferralBooks(1, 1);
    }

    function test_Poach_Reverts_DuringLiquidation() public {
        _deposit(alice, 100e6, address(0));
        uint256 aliceGrai = grai.balanceOf(alice);
        vm.prank(alice);
        grai.lock(aliceGrai);
        vm.prank(alice);
        grai.vote(aliceGrai);
        assertTrue(grai.hasQuorum());

        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation());

        // Liquidation gate runs before balance/ask checks.
        vm.prank(dias);
        vm.expectRevert(IGRAI.LiquidationOpen.selector);
        grai.poach(alice);
    }

    /// Redeem reverses deposit volume on locker + L1/L2 upline (treasury.burn).
    function test_Redeem_BurnsReferralBooks() public {
        _deposit(alice, 100e6, address(0));
        _deposit(bob, 40e6, alice);
        _deposit(carol, 25e6, bob);
        _assertNode(alice, 100e6, 40e6, 25e6);
        _assertNode(bob, 40e6, 25e6, 0);
        _assertNode(carol, 25e6, 0, 0);

        uint256 bobGrai = grai.balanceOf(bob);
        vm.prank(bob);
        grai.lock(bobGrai);
        vm.prank(bob);
        grai.vote(bobGrai);
        // Need quorum: also vote alice
        uint256 aliceGrai = grai.balanceOf(alice);
        vm.prank(alice);
        grai.lock(aliceGrai);
        vm.prank(alice);
        grai.vote(aliceGrai);
        assertTrue(grai.hasQuorum());

        vm.prank(admin);
        grai.liquidate();
        IGRAI.Config memory cfg = _readConfig();
        vm.warp(block.timestamp + uint256(cfg.liquidationPeriod));

        uint256 carolGrai = grai.balanceOf(carol);
        vm.prank(carol);
        grai.redeem(carolGrai);

        _assertNode(carol, 0, 0, 0);
        _assertNode(bob, 40e6, 0, 0); // l1 lost carol's 25
        _assertNode(alice, 100e6, 40e6, 0); // l2 lost carol's 25
    }

    ////////////////////////////// helpers //////////////////////////////

    function _seedTree() internal {
        _deposit(alice, 100e6, address(0));
        _deposit(bob, 40e6, alice);
        _deposit(carol, 25e6, bob);
    }

    function _fundAndPoach(address poacher, uint256 fund, address locker) internal {
        _deposit(poacher, fund, address(0));
        vm.prank(poacher);
        grai.poach(locker);
    }

    function _deposit(address user, uint256 amount, address referrer) internal {
        vm.startPrank(user);
        usdc.approve(address(grai), amount);
        grai.deposit(address(usdc), amount, false, referrer);
        vm.stopPrank();
    }

    function _lock(address user, uint256 amount) internal {
        vm.prank(user);
        grai.lock(amount);
    }

    function _yield(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(grai), amount);
        grai.distribute(address(usdc), amount);
    }

    function _claimMax(address locker) internal {
        vm.prank(locker);
        grai.claim(locker, address(usdc), type(uint256).max);
    }

    function _assertNode(address who, uint256 value, uint256 l1, uint256 l2) internal view {
        (uint256 v, uint256 a, uint256 b,) = treasury.referralBooks(who);
        assertEq(v, value, "value");
        assertEq(a, l1, "l1Value");
        assertEq(b, l2, "l2Value");
    }
}
