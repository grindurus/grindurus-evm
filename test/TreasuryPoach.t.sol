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
/// lockerBooks after setup:
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
    uint256 constant DIVIDEND = 50e6;
    uint256 constant GROSS_PROFIT_SHARE = 50e6;
    uint256 constant REVENUE = 10e6;
    uint256 constant L1_FULL = 8e6;
    uint256 constant L2_FULL = 2e6;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        _setYieldSplitFiftyFifty();
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

    ////////////////////////////// mint / lockerBooks //////////////////////////////

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

    /// Audit: reclaiming self-root must not `l1Value += own` on the locker (ask would become 2× value).
    function test_Poach_SelfRootReclaim_DoesNotDoubleCountOwnValue() public {
        _seedTree();
        // Alice: value=100, l1=40 → ask 140. Dias buys the seat.
        _fundAndPoach(dias, 140e6, alice);
        assertEq(treasury.referrerOf(alice), dias);
        _assertNode(alice, 100e6, 40e6, 25e6);
        _assertNode(dias, 140e6, 100e6, 40e6);

        (uint256 reclaimAsk, address seller) = treasury.poachOf(alice, alice);
        assertEq(seller, dias);
        assertEq(reclaimAsk, 140e6, "ask still value+l1, not yet doubled");

        // Alice already holds GRAI from her deposit + dias's poach payment.
        uint256 diasGraiBefore = grai.balanceOf(dias);
        vm.prank(alice);
        grai.poach(alice);

        assertEq(treasury.referrerOf(alice), alice);
        // Own deposits stay in `value`; downline books unchanged — not copied into `l1Value`.
        _assertNode(alice, 100e6, 40e6, 25e6);
        _assertNode(dias, 140e6, 0, 0); // lost alice seat; no bogus L2 re-credit

        (uint256 nextAsk,) = treasury.poachOf(alice, dias);
        assertEq(nextAsk, 140e6, "must not be 2 * value + l1 (240)");
        assertEq(grai.balanceOf(dias), diasGraiBefore + reclaimAsk);
    }

    /// Audit: claim while unbound grows `locker.value` with no upline L1; first bind must backfill
    /// so later `poach`/`rebind` does not underflow or eat sibling L1.
    function test_ClaimBeforeBind_BackfillsL1_PoachSucceeds() public {
        _deposit(alice, 100e6, address(0)); // Alice self-root
        uint256 g = grai.balanceOf(alice);
        vm.prank(alice);
        assertTrue(grai.transfer(eve, g));

        _lock(eve, g);
        assertEq(treasury.referrerOf(eve), address(0));

        _yield(YIELD);
        _claimMax(eve);

        (uint256 claimBook,,,) = treasury.lockerBooks(eve);
        assertGt(claimBook, 0, "unbound claim credited value");
        assertEq(treasury.referrerOf(eve), address(0));

        _deposit(eve, 1e6, alice); // first bind under Alice
        assertEq(treasury.referrerOf(eve), alice);

        (uint256 eveValue,,,) = treasury.lockerBooks(eve);
        (, uint256 aliceL1,,) = treasury.lockerBooks(alice);
        assertEq(eveValue, claimBook + 1e6);
        // Backfill claimBook + deposit 1e6 onto Alice L1 (not deposit alone).
        assertEq(aliceL1, claimBook + 1e6, "bind must mirror pre-claim value into referrer.l1");

        uint256 price = eveValue; // poachOf = value + l1 (eve has no downline)
        uint256 aliceGraiBefore = grai.balanceOf(alice);
        deal(address(grai), bob, price);
        vm.prank(bob);
        grai.poach(eve);

        assertEq(treasury.referrerOf(eve), bob);
        _assertNode(alice, 100e6, 0, 0); // lost Eve seat; L1 cleared for that own book
        _assertNode(bob, 0, eveValue, 0); // deal-funded poacher: no own deposits, gains Eve L1
        assertEq(grai.balanceOf(alice), aliceGraiBefore + price);
    }

    function test_ClaimBeforeBind_PoachDoesNotCannibalizeSiblingL1() public {
        _deposit(alice, 100e6, address(0));
        _deposit(bob, 80e6, alice);

        uint256 g = grai.balanceOf(alice);
        vm.prank(alice);
        assertTrue(grai.transfer(eve, g));

        _lock(eve, g);
        _yield(YIELD);
        _claimMax(eve);
        (uint256 claimBook,,,) = treasury.lockerBooks(eve);

        _deposit(eve, 1e6, alice);

        (, uint256 aliceL1Before,,) = treasury.lockerBooks(alice);
        (uint256 eveValue,,,) = treasury.lockerBooks(eve);
        // Bob 80 + Eve backfill(claimBook) + Eve deposit 1
        assertEq(aliceL1Before, 80e6 + claimBook + 1e6);
        assertEq(eveValue, claimBook + 1e6);

        uint256 price = eveValue;
        deal(address(grai), paul, price);
        vm.prank(paul);
        grai.poach(eve);

        (, uint256 aliceL1After,,) = treasury.lockerBooks(alice);
        assertEq(aliceL1After, 80e6, "Bob's L1 credit must survive Eve poach");
        assertEq(treasury.referrerOf(eve), paul);
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
        (,, uint256 eveL2,) = treasury.lockerBooks(eve);
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
        (, uint256 eveL1,,) = treasury.lockerBooks(eve);
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
        assertApproxEqAbs(usdc.balanceOf(dias) - diasBefore, L1_FULL, 1);
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
        assertApproxEqAbs(usdc.balanceOf(paul) - paulBefore, L1_FULL, 1);
        assertEq(usdc.balanceOf(alice), aliceBefore);
    }

    /// Claim credits `usdValue(claimed)` into referral books → poach ask rises.
    function test_Claim_IncreasesPoachAskByClaimedUsd() public {
        _seedTree();
        (uint256 askBefore,) = treasury.poachOf(bob, dias);
        assertEq(askBefore, 65e6); // value 40 + l1 25

        _lock(bob, grai.balanceOf(bob));
        _yield(YIELD);
        uint256 claimed = grai.previewClaim(bob, address(usdc), type(uint256).max);
        assertEq(claimed, DIVIDEND); // sole unvoted locker after alice unlocked? alice not locked
        // alice still has unlocked GRAI; only bob locked → bob gets full dividend slice
        uint256 book = grai.usdValue(address(usdc), claimed);

        _claimMax(bob);

        (uint256 askAfter,) = treasury.poachOf(bob, dias);
        assertEq(askAfter, askBefore + book);
        _assertNode(bob, 40e6 + book, 25e6, 0);
        _assertNode(alice, 100e6, 40e6 + book, 25e6); // L1 += bob's claim book
        _assertNode(carol, 25e6, 0, 0);
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

    function test_GetLockerBooks_PaginatesEnumerableOrder() public {
        _seedTree();
        assertEq(treasury.totalSupply(), 3);

        ITreasury.LockerData[] memory all_ = treasury.getLockersData(0, 100);
        assertEq(all_.length, 3);

        bool sawAlice;
        bool sawBob;
        bool sawCarol;
        for (uint256 i; i < all_.length; ++i) {
            ITreasury.LockerData memory row = all_[i];
            if (row.locker == alice) {
                sawAlice = true;
                assertEq(row.book.referrer, alice);
                assertEq(row.ownerOf, alice);
                assertEq(row.book.value, 100e6);
                assertEq(row.book.l1Value, 40e6);
                assertEq(row.book.l2Value, 25e6);
            } else if (row.locker == bob) {
                sawBob = true;
                assertEq(row.book.referrer, alice);
                assertEq(row.ownerOf, bob);
                assertEq(row.book.value, 40e6);
                assertEq(row.book.l1Value, 25e6);
                assertEq(row.book.l2Value, 0);
            } else if (row.locker == carol) {
                sawCarol = true;
                assertEq(row.book.referrer, bob);
                assertEq(row.ownerOf, carol);
                assertEq(row.book.value, 25e6);
                assertEq(row.book.l1Value, 0);
                assertEq(row.book.l2Value, 0);
            } else {
                fail("unexpected locker");
            }
        }
        assertTrue(sawAlice && sawBob && sawCarol);

        assertEq(treasury.getLockersData(0, 2).length, 2);
        assertEq(treasury.getLockersData(2, 99).length, 1);
        assertEq(treasury.getLockersData(3, 5).length, 0);

        vm.expectRevert(abi.encodeWithSelector(ITreasury.InvalidRange.selector, 1, 1));
        treasury.getLockersData(1, 1);
    }

    function test_GetReferral_TreeBookOwnerAndClaimable() public {
        _seedTree();

        IGRAI.LockerData[] memory page = grai.getLockersData(0, 100);
        assertEq(page.length, 3);

        IGRAI.LockerData memory aliceRow = _referralOf(page, alice);
        assertEq(aliceRow.locker, alice);
        assertEq(aliceRow.referrer, alice);
        assertEq(aliceRow.ownerOf, alice);
        assertEq(aliceRow.book.value, 100e6);
        assertEq(aliceRow.book.l1Value, 40e6);
        assertEq(aliceRow.book.l2Value, 25e6);
        assertEq(aliceRow.book.referrer, alice);

        IGRAI.LockerData memory bobRow = _referralOf(page, bob);
        assertEq(bobRow.locker, bob);
        assertEq(bobRow.referrer, alice);
        assertEq(bobRow.ownerOf, bob);
        assertEq(bobRow.book.value, 40e6);
        assertEq(bobRow.book.l1Value, 25e6);

        IGRAI.LockerData memory carolRow = _referralOf(page, carol);
        assertEq(carolRow.referrer, bob);
        assertEq(carolRow.ownerOf, carol);

        _lock(alice, grai.balanceOf(alice));
        _yield(20e6);
        uint256 pending = grai.previewClaim(alice, address(usdc), type(uint256).max);
        assertGt(pending, 0);
        aliceRow = _referralOf(grai.getLockersData(0, 100), alice);
        bool sawUsdc;
        for (uint256 i; i < aliceRow.assets.length; ++i) {
            if (aliceRow.assets[i] == address(usdc)) {
                assertEq(aliceRow.claimable[i], pending);
                sawUsdc = true;
            }
        }
        assertTrue(sawUsdc);

        vm.expectRevert(abi.encodeWithSelector(ITreasury.InvalidRange.selector, 1, 1));
        grai.getLockersData(1, 1);
    }

    function test_Poach_Reverts_DuringLiquidation() public {
        _deposit(alice, 100e6, address(0));
        uint256 aliceGrai = grai.balanceOf(alice);
        vm.prank(alice);
        grai.lock(aliceGrai);
        vm.prank(alice);
        grai.vote(aliceGrai);
        assertTrue(grai.hasQuorum());

        vm.warp(block.timestamp + uint256(grinders.vetoPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation());

        // Liquidation gate runs before balance/ask checks.
        vm.prank(dias);
        vm.expectRevert(IGRAI.LiquidationOpen.selector);
        grai.poach(alice);
    }

    /// Admin may retarget payout knobs during liquidation (on-admin trust).
    function test_TreasurySetters_Allowed_DuringLiquidation() public {
        _deposit(alice, 100e6, address(0));
        uint256 aliceGrai = grai.balanceOf(alice);
        vm.prank(alice);
        grai.lock(aliceGrai);
        vm.prank(alice);
        grai.vote(aliceGrai);

        vm.warp(block.timestamp + uint256(grinders.vetoPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation());

        address other = makeAddr("other");
        vm.startPrank(admin);
        treasury.setBeneficiar(other);
        assertEq(treasury.beneficiar(), other);

        treasury.setRoyaltyBps(100);
        assertEq(treasury.royaltyBps(), 100);

        uint16[] memory shares = new uint16[](2);
        shares[0] = 7_000;
        shares[1] = 3_000;
        treasury.setRevenueShareBps(shares);
        assertEq(treasury.revenueShareBps(0), 7_000);
        assertEq(treasury.revenueShareBps(1), 3_000);
        vm.stopPrank();
    }

    /// Redeem does not reverse deposit volume — referral books stay sticky after mint.
    function test_Redeem_KeepsLockerBooks() public {
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

        vm.warp(block.timestamp + uint256(grinders.vetoPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();
        IGRAI.Config memory cfg = _readConfig();
        vm.warp(block.timestamp + uint256(cfg.liquidationPeriod));

        uint256 carolGrai = grai.balanceOf(carol);
        vm.prank(carol);
        grai.redeem(carolGrai);

        _assertNode(carol, 25e6, 0, 0);
        _assertNode(bob, 40e6, 25e6, 0);
        _assertNode(alice, 100e6, 40e6, 25e6);
    }

    ////////////////////////////// helpers //////////////////////////////

    function _referralOf(IGRAI.LockerData[] memory page, address locker)
        internal
        pure
        returns (IGRAI.LockerData memory row)
    {
        for (uint256 i; i < page.length; ++i) {
            if (page[i].locker == locker) return page[i];
        }
        revert("missing locker");
    }

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
        (uint256 v, uint256 a, uint256 b,) = treasury.lockerBooks(who);
        assertEq(v, value, "value");
        assertEq(a, l1, "l1Value");
        assertEq(b, l2, "l2Value");
    }
}
