// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

/// @dev Referrer L1/L2 split: `revenueShareInfo` + claim-time `Treasury.distribute`.
///
/// Economics used in e2e (set in setUp): dividend/treasury = 50/50,
/// GRAI `revenueShareBps` = 1000 (10% of yield → affiliates), Treasury L1/L2 = 80/20.
/// Tip = 1% of claimed (default); when locker claims for self, tip stays with locker.
contract TreasuryReferralsTest is GRAIFixture {
    address carol = makeAddr("carol");
    address beneficiar = makeAddr("beneficiar");

    uint16 constant REVENUE_SHARE_BPS = 1_000; // 10% of yield → affiliate pool on claim
    uint256 constant YIELD = 100e6;
    uint256 constant DIVIDEND = 50e6; // 50% of YIELD
    uint256 constant GROSS_PROFIT_SHARE = 50e6; // treasuryCut/dividendCut of full claim
    uint256 constant REVENUE = 10e6; // claimed * 1000 / 5000 on full DIVIDEND claim
    uint256 constant L1_FULL = 8e6; // 80% of REVENUE
    uint256 constant L2_FULL = 2e6; // 20% of REVENUE

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        _setYieldSplitFiftyFifty();
        grai.setConfig(IGRAI.ConfigId.REVENUE_SHARE, REVENUE_SHARE_BPS);
        treasury.setBeneficiar(beneficiar);
        vm.stopPrank();

        usdc.mint(carol, 1_000e6);
    }

    ////////////////////////////// revenueShareInfo //////////////////////////////

    function test_Info_NoBind_Empty() public view {
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 0);
        assertEq(shares.length, 0);
    }

    function test_Info_SelfReferrer_Empty() public {
        _mintAff(alice, alice);
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 0);
        assertEq(shares.length, 0);
    }

    function test_Info_L1Only() public {
        _mintAff(alice, bob);
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 1);
        assertEq(refs[0], bob);
        assertEq(shares[0], 8_000);
    }

    function test_Info_L1AndL2() public {
        _mintAff(alice, bob);
        _mintAff(bob, carol);
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 2);
        assertEq(refs[0], bob);
        assertEq(refs[1], carol);
        assertEq(shares[0], 8_000);
        assertEq(shares[1], 2_000);
    }

    function test_Mint_LoopingReferrer_FallsBackToSelfRoot() public {
        _mintAff(alice, bob);
        // bob → alice would cycle; mint binds bob to self instead of reverting
        _mintAff(bob, alice);
        assertEq(treasury.referrerOf(bob), bob);
        (address[] memory refs,) = treasury.revenueShareInfo(bob, 10_000);
        assertEq(refs.length, 0);
    }

    function test_Mint_Reverts_ProtocolSinkReferrer() public {
        vm.startPrank(alice);
        usdc.approve(address(grai), 3e6);
        vm.expectRevert(ITreasury.InvalidReferrer.selector);
        grai.deposit(address(usdc), 1e6, false, address(grai));
        vm.expectRevert(ITreasury.InvalidReferrer.selector);
        grai.deposit(address(usdc), 1e6, false, address(treasury));
        vm.expectRevert(ITreasury.InvalidReferrer.selector);
        grai.deposit(address(usdc), 1e6, false, address(weth));
        vm.stopPrank();
    }

    function test_Info_SelfLoopOnL1_StopsAtL1() public {
        _mintAff(alice, bob);
        _mintAff(bob, bob); // referrerOf(bob) == bob
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 1);
        assertEq(refs[0], bob);
        assertEq(shares[0], 8_000);
    }

    function test_Info_ZeroRevenue_Empty() public {
        _mintAff(alice, bob);
        (address[] memory refs,) = treasury.revenueShareInfo(alice, 0);
        assertEq(refs.length, 0);
    }

    ////////////////////////////// distribute (unit) //////////////////////////////

    function test_Distribute_NoReferrer_AllToBeneficiar() public {
        usdc.mint(address(treasury), GROSS_PROFIT_SHARE);
        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE, 0);

        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Distribute_L1Only_UnpaidL2ToBeneficiar() public {
        _mintAff(alice, bob);
        usdc.mint(address(treasury), GROSS_PROFIT_SHARE);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE, 0);

        assertEq(usdc.balanceOf(bob) - bobBefore, L1_FULL);
        assertEq(usdc.balanceOf(carol) - carolBefore, 0);
        // unpaid L2 (2e6) + protocol slice (10e6) = 12e6
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE - L1_FULL);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Distribute_RejectingReferrer_GetsWeth() public {
        RejectEth rejector = new RejectEth();
        _mintAff(alice, address(rejector));
        vm.deal(address(treasury), GROSS_PROFIT_SHARE);

        vm.prank(address(grai));
        treasury.distribute(address(0), alice, GROSS_PROFIT_SHARE, REVENUE, 0);

        // L1 ETH push rejected → WETH wrap; unpaid protocol slice → beneficiar
        assertEq(address(rejector).balance, 0);
        assertEq(weth.balanceOf(address(rejector)), L1_FULL);
        assertEq(beneficiar.balance, GROSS_PROFIT_SHARE - L1_FULL);
        assertEq(address(treasury).balance, 0);
    }

    function test_Distribute_L1AndL2() public {
        _mintAff(alice, bob);
        _mintAff(bob, carol);
        usdc.mint(address(treasury), GROSS_PROFIT_SHARE);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE, 0);

        assertEq(usdc.balanceOf(bob) - bobBefore, L1_FULL);
        assertEq(usdc.balanceOf(carol) - carolBefore, L2_FULL);
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE - L1_FULL - L2_FULL);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Distribute_InsufficientBalance_NoOp() public {
        _mintAff(alice, bob);
        usdc.mint(address(treasury), GROSS_PROFIT_SHARE - 1);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE, 0);

        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(usdc.balanceOf(beneficiar), 0);
        assertEq(usdc.balanceOf(address(treasury)), GROSS_PROFIT_SHARE - 1);
    }

    function test_Distribute_HalfAmounts() public {
        _mintAff(alice, bob);
        _mintAff(bob, carol);
        uint256 net = GROSS_PROFIT_SHARE / 2; // 25e6
        uint256 rev = REVENUE / 2; // 5e6
        usdc.mint(address(treasury), net);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, net, rev, 0);

        assertEq(usdc.balanceOf(bob) - bobBefore, 4e6); // 80% of 5e6
        assertEq(usdc.balanceOf(carol) - carolBefore, 1e6); // 20% of 5e6
        assertEq(usdc.balanceOf(beneficiar), 20e6); // net - paid
    }

    ////////////////////////////// claim e2e //////////////////////////////

    function test_Claim_NoReferrer_AllNetProfitToBeneficiar() public {
        _depositWithRef(alice, 100e6, address(0));
        _lock(alice, grai.balanceOf(alice));
        _yield(YIELD);
        uint256 bobBefore = usdc.balanceOf(bob);

        uint256 claimed = _claimMax(alice);
        assertEq(claimed, DIVIDEND);

        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Claim_L1Only() public {
        _depositWithRef(alice, 100e6, bob);
        _lock(alice, grai.balanceOf(alice));
        _yield(YIELD);
        uint256 bobBefore = usdc.balanceOf(bob);

        _claimMax(alice);

        assertEq(usdc.balanceOf(bob) - bobBefore, L1_FULL);
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE - L1_FULL);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Claim_L1AndL2() public {
        // alice ← bob ← carol
        _depositWithRef(bob, 1e6, carol); // bind bob → carol (L2 for alice)
        _depositWithRef(alice, 100e6, bob);
        _lock(alice, grai.balanceOf(alice));
        // bob's tiny lock would dilute dividends — unlock bob's GRAI by not locking bob
        _yield(YIELD);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        _claimMax(alice);

        assertEq(usdc.balanceOf(bob) - bobBefore, L1_FULL);
        assertEq(usdc.balanceOf(carol) - carolBefore, L2_FULL);
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE - L1_FULL - L2_FULL);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Claim_Half_ThenRest() public {
        _depositWithRef(bob, 1e6, carol);
        _depositWithRef(alice, 100e6, bob);
        _lock(alice, grai.balanceOf(alice));
        _yield(YIELD);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        uint256 half = DIVIDEND / 2; // 25e6
        vm.prank(alice);
        grai.claim(alice, address(usdc), half);

        assertEq(usdc.balanceOf(bob) - bobBefore, 4e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 1e6);
        assertEq(usdc.balanceOf(beneficiar), 20e6);
        assertEq(usdc.balanceOf(address(treasury)), GROSS_PROFIT_SHARE / 2);

        _claimMax(alice);

        assertEq(usdc.balanceOf(bob) - bobBefore, L1_FULL);
        assertEq(usdc.balanceOf(carol) - carolBefore, L2_FULL);
        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE - L1_FULL - L2_FULL);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Claim_SelfReferrer_TreatedAsNoAffiliate() public {
        _depositWithRef(alice, 100e6, alice);
        _lock(alice, grai.balanceOf(alice));
        _yield(YIELD);

        _claimMax(alice);

        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    ////////////////////////////// poach //////////////////////////////

    function test_Poach_SelfReferrer_RewritesStickyReferrer() public {
        _depositWithRef(alice, 100e6, address(0)); // self-mint NFT + tree value
        uint256 tokenId = uint256(uint160(alice));
        assertEq(treasury.ownerOf(tokenId), alice);
        (uint256 own, uint256 l1, uint256 l2,) = treasury.referralBooks(alice);
        assertEq(own, 100e6);
        assertEq(l1, 0);
        assertEq(l2, 0);

        (uint256 price,) = treasury.poachOf(alice, bob);
        assertEq(price, 100e6);

        // Fund bob with GRAI via deposit
        _depositWithRef(bob, 100e6, carol);
        uint256 aliceGraiBefore = grai.balanceOf(alice);
        vm.prank(bob);
        grai.poach(alice);

        assertEq(treasury.ownerOf(tokenId), alice, "poach does not move cashflow NFT");
        assertEq(treasury.referrerOf(alice), bob);
        assertEq(grai.balanceOf(alice), aliceGraiBefore + price);
        assertEq(grai.balanceOf(bob), 0);
        // Self-poach: alice keeps her node; bob gains alice.value as l1
        (uint256 aliceOwn, uint256 aliceL1, uint256 aliceL2,) = treasury.referralBooks(alice);
        assertEq(aliceOwn, 100e6);
        assertEq(aliceL1, 0);
        assertEq(aliceL2, 0);
        (, uint256 bobL1, uint256 bobL2,) = treasury.referralBooks(bob);
        assertEq(bobL1, 100e6);
        assertEq(bobL2, 0);
    }

    function test_Poach_NonSelf_PaysCurrentReferrer() public {
        address paul = makeAddr("paul");
        usdc.mint(paul, 1_000e6);

        _depositWithRef(alice, 100e6, address(0));
        _depositWithRef(bob, 40e6, alice);
        _depositWithRef(carol, 25e6, bob);

        uint256 bobId = uint256(uint160(bob));
        assertEq(treasury.ownerOf(bobId), bob);
        assertEq(treasury.referrerOf(bob), alice);

        // Paul funds GRAI to cover bob value+l1Value = 40+25
        _depositWithRef(paul, 65e6, address(0));
        (uint256 price, address seller) = treasury.poachOf(bob, paul);
        assertEq(price, 65e6);
        assertEq(seller, alice);

        uint256 aliceGraiBefore = grai.balanceOf(alice);
        vm.prank(paul);
        grai.poach(bob);

        assertEq(treasury.ownerOf(bobId), bob, "poach does not move cashflow NFT");
        assertEq(treasury.referrerOf(bob), paul);
        assertEq(grai.balanceOf(alice), aliceGraiBefore + price);
        assertEq(grai.balanceOf(paul), 0);
        assertEq(treasury.ownerOf(uint256(uint160(carol))), carol);
        assertEq(treasury.ownerOf(uint256(uint160(alice))), alice);

        // L1/L2 book moves alice → paul for bob's subtree
        (, uint256 aliceL1, uint256 aliceL2,) = treasury.referralBooks(alice);
        (, uint256 paulL1, uint256 paulL2,) = treasury.referralBooks(paul);
        assertEq(aliceL1, 0);
        assertEq(aliceL2, 0);
        assertEq(paulL1, 40e6);
        assertEq(paulL2, 25e6);
        // Subsequent poach(alice) no longer prices bob's volume
        (uint256 priceAlice,) = treasury.poachOf(alice, paul);
        assertEq(priceAlice, 100e6);
    }

    function test_Poach_SelfThenDownline_BookStaysConsistent() public {
        address dias = makeAddr("dias");
        address eve = makeAddr("eve");
        usdc.mint(dias, 1_000e6);
        usdc.mint(eve, 1_000e6);

        _depositWithRef(alice, 100e6, address(0));
        _depositWithRef(bob, 40e6, alice);
        _depositWithRef(carol, 25e6, bob);

        _depositWithRef(dias, 140e6, address(0));
        vm.prank(dias);
        grai.poach(alice);

        // Dias credited alice.value / alice.l1 as l1/l2; alice keeps downline L1 on bob
        (, uint256 diasL1, uint256 diasL2,) = treasury.referralBooks(dias);
        (, uint256 aliceL1, uint256 aliceL2,) = treasury.referralBooks(alice);
        assertEq(diasL1, 100e6);
        assertEq(diasL2, 40e6);
        assertEq(aliceL1, 40e6);
        assertEq(aliceL2, 25e6);
        (uint256 priceAlice,) = treasury.poachOf(alice, eve);
        assertEq(priceAlice, 140e6); // still value+l1 on alice node

        // Eve takes bob from alice → alice loses bob book; dias still holds alice
        _depositWithRef(eve, 65e6, address(0));
        vm.prank(eve);
        grai.poach(bob);

        (, aliceL1, aliceL2,) = treasury.referralBooks(alice);
        (, uint256 eveL1, uint256 eveL2,) = treasury.referralBooks(eve);
        assertEq(aliceL1, 0);
        assertEq(aliceL2, 0);
        assertEq(eveL1, 40e6);
        assertEq(eveL2, 25e6);

        // Resale of alice from dias: only alice.own left in ask
        (priceAlice,) = treasury.poachOf(alice, eve);
        assertEq(priceAlice, 100e6);
        // Dias keeps L1 book on alice; loses L2 book on bob after eve took bob
        (, diasL1, diasL2,) = treasury.referralBooks(dias);
        assertEq(diasL1, 100e6);
        assertEq(diasL2, 0);
    }

    function test_Mint_CreditsL1L2ValuesUpUpline() public {
        _depositWithRef(alice, 100e6, address(0)); // self
        _depositWithRef(bob, 40e6, alice); // alice is L1 of bob
        _depositWithRef(carol, 25e6, bob); // bob L1, alice L2 of carol

        (uint256 aliceOwn, uint256 aliceL1, uint256 aliceL2,) = treasury.referralBooks(alice);
        (uint256 bobOwn, uint256 bobL1, uint256 bobL2,) = treasury.referralBooks(bob);
        (uint256 carolOwn, uint256 carolL1, uint256 carolL2,) = treasury.referralBooks(carol);
        assertEq(aliceOwn, 100e6);
        assertEq(aliceL1, 40e6);
        assertEq(aliceL2, 25e6);
        assertEq(bobOwn, 40e6);
        assertEq(bobL1, 25e6);
        assertEq(bobL2, 0);
        assertEq(carolOwn, 25e6);
        assertEq(carolL1, 0);
        assertEq(carolL2, 0);

        // poach ask = value + l1Value (excludes l2Value / deeper tree)
        (uint256 priceAlice,) = treasury.poachOf(alice, bob);
        assertEq(priceAlice, 140e6);
        (uint256 priceBob,) = treasury.poachOf(bob, carol);
        assertEq(priceBob, 65e6);
    }

    function test_Mint_SecondDeposit_AccruesValue() public {
        _depositWithRef(alice, 100e6, address(0));
        _depositWithRef(alice, 50e6, bob); // referrer ignored; sticky self + accrue

        assertEq(treasury.referrerOf(alice), alice);
        (uint256 own, uint256 l1, uint256 l2,) = treasury.referralBooks(alice);
        assertEq(own, 150e6);
        assertEq(l1, 0);
        assertEq(l2, 0);
        (uint256 price,) = treasury.poachOf(alice, bob);
        assertEq(price, 150e6);
    }

    function test_Poach_Reverts_WhenAlreadyOwner() public {
        _mintAff(alice, bob);
        vm.expectRevert(ITreasury.AlreadyBound.selector);
        vm.prank(bob);
        grai.poach(alice);
    }

    ////////////////////////////// helpers //////////////////////////////

    function _mintAff(address locker, address referrer) internal {
        vm.prank(address(grai));
        treasury.mint(locker, referrer, 0);
    }

    function _depositWithRef(address user, uint256 amount, address referrer) internal {
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

    function _claimMax(address locker) internal returns (uint256 claimed) {
        claimed = grai.previewClaim(locker, address(usdc), type(uint256).max);
        vm.prank(locker);
        grai.claim(locker, address(usdc), type(uint256).max);
    }
}

contract RejectEth {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("no eth");
    }
}
