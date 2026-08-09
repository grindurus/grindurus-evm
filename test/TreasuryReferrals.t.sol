// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

/// @dev Referrer L1/L2 split: `revenueShareInfo` + claim-time `Treasury.distribute`.
///
/// Economics used in e2e (set in setUp): buyback/dividend/treasury = 50/30/20,
/// GRAI `revenueShareBps` = 1000 (10% of yield → affiliates), Treasury L1/L2 = 80/20.
/// Tip = 1% of claimed (default); when locker claims for self, tip stays with locker.
contract TreasuryReferralsTest is GRAIFixture {
    address carol = makeAddr("carol");
    address beneficiar = makeAddr("beneficiar");

    uint16 constant REVENUE_SHARE_BPS = 1_000; // 10% of yield → affiliate pool on claim
    uint256 constant YIELD = 100e6;
    uint256 constant DIVIDEND = 30e6; // 30% of YIELD
    uint256 constant GROSS_PROFIT_SHARE = 20e6; // 20% of YIELD (full claim)
    uint256 constant REVENUE = 10e6; // claimed * 1000 / 3000 on full DIVIDEND claim
    uint256 constant L1_FULL = 8e6; // 80% of REVENUE
    uint256 constant L2_FULL = 2e6; // 20% of REVENUE

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        grai.setGrinders(address(grinders));
        _setYieldSplitFiftyThirtyTwenty();
        grai.setConfig(IGRAI.ConfigId.REVENUE_SHARE, REVENUE_SHARE_BPS);
        treasury.setBeneficiar(beneficiar);
        grai.setDepositor(carol, true);
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

    function test_Info_CycleBackToLocker_StopsAtL1() public {
        // alice → bob → alice (cycle)
        _mintAff(alice, bob);
        _mintAff(bob, alice);
        (address[] memory refs, uint256[] memory shares) = treasury.revenueShareInfo(alice, 10_000);
        assertEq(refs.length, 1);
        assertEq(refs[0], bob);
        assertEq(shares[0], 8_000);
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
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE);

        assertEq(usdc.balanceOf(beneficiar), GROSS_PROFIT_SHARE);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_Distribute_L1Only_UnpaidL2ToBeneficiar() public {
        _mintAff(alice, bob);
        usdc.mint(address(treasury), GROSS_PROFIT_SHARE);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE);

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
        treasury.distribute(address(0), alice, GROSS_PROFIT_SHARE, REVENUE);

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
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE);

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
        treasury.distribute(address(usdc), alice, GROSS_PROFIT_SHARE, REVENUE);

        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(usdc.balanceOf(beneficiar), 0);
        assertEq(usdc.balanceOf(address(treasury)), GROSS_PROFIT_SHARE - 1);
    }

    function test_Distribute_HalfAmounts() public {
        _mintAff(alice, bob);
        _mintAff(bob, carol);
        uint256 net = GROSS_PROFIT_SHARE / 2; // 10e6
        uint256 rev = REVENUE / 2; // 5e6
        usdc.mint(address(treasury), net);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(address(grai));
        treasury.distribute(address(usdc), alice, net, rev);

        assertEq(usdc.balanceOf(bob) - bobBefore, 4e6); // 80% of 5e6
        assertEq(usdc.balanceOf(carol) - carolBefore, 1e6); // 20% of 5e6
        assertEq(usdc.balanceOf(beneficiar), 5e6); // net - paid
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

        uint256 half = DIVIDEND / 2; // 15e6
        vm.prank(alice);
        grai.claim(alice, address(usdc), half);

        assertEq(usdc.balanceOf(bob) - bobBefore, 4e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 1e6);
        assertEq(usdc.balanceOf(beneficiar), 5e6);
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

    ////////////////////////////// helpers //////////////////////////////

    function _mintAff(address locker, address referrer) internal {
        vm.prank(address(grai));
        treasury.mint(locker, referrer);
    }

    function _depositWithRef(address user, uint256 amount, address referrer) internal {
        vm.prank(admin);
        grai.setDepositor(user, true);
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
