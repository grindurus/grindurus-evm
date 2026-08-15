// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {GRS} from "../src/GRS.sol";
import {IGRS} from "../src/interfaces/IGRS.sol";

contract MockLzEndpoint {
    mapping(address => address) public delegates;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }
}

contract GRSAllocTest is Test {
    MockLzEndpoint internal endpoint;
    address internal admin = address(0xA11CE);
    GRS internal grs;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        grs = new GRS(address(endpoint), admin, true);
    }

    function test_AllocationsSumToCap() public view {
        IGRS.Allocation[] memory rows = grs.getAllocations();
        assertEq(rows.length, 13);
        uint256 cap;
        uint256 left;
        for (uint256 i; i < rows.length; ++i) {
            cap += rows[i].cap;
            left += rows[i].remaining;
            assertEq(rows[i].spent, 0);
            assertEq(rows[i].remaining, rows[i].cap);
        }
        assertEq(cap, 1_000_000_000e18);
        assertEq(left, 1_000_000_000e18);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18);
    }

    function test_GrantInstantDebitsBucket() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 50_000_000e18, 0, 0, 0);

        assertEq(grs.spent(IGRS.Bucket.TokenSales), 50_000_000e18);
        assertEq(grs.remaining(IGRS.Bucket.TokenSales), 0);
        assertEq(grs.balanceOf(admin), 50_000_000e18);
        assertEq(grs.balanceOf(address(grs)), 950_000_000e18);

        vm.prank(admin);
        vm.expectRevert(IGRS.BucketExceeded.selector);
        grs.grant(IGRS.Bucket.TokenSales, admin, 1, 0, 0, 0);
    }

    function test_GrantVestingCliffThenLinear() public {
        address alice = address(0xB0B);
        uint64 month = 30 days;
        uint64 start = uint64(block.timestamp);
        vm.prank(admin);
        uint256 id = grs.grant(IGRS.Bucket.CoreTeam, alice, 12e18, start, 12 * month, 60 * month);

        assertEq(id, 1);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18);
        assertEq(grs.releasable(id), 0);

        vm.warp(start + 12 * month);
        assertEq(grs.releasable(id), 0);

        vm.warp(start + 12 * month + 1);
        assertGt(grs.releasable(id), 0);

        vm.warp(start + 72 * month);
        assertEq(grs.releasable(id), 12e18);
        grs.release(id);
        assertEq(grs.balanceOf(alice), 12e18);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18 - 12e18);

        IGRS.VestingRec[] memory recs = grs.getVestings();
        assertEq(recs.length, 1);
        assertEq(recs[0].id, id);
        assertEq(recs[0].beneficiary, alice);
        assertEq(recs[0].funder, address(grs));
        assertEq(recs[0].released, 12e18);
        assertEq(uint8(recs[0].bucket), uint8(IGRS.Bucket.CoreTeam));
    }

    function test_VoteGatedNeedsProprietorOnceSet() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.GrowthFund, admin, 1e18, 0, 0, 0);

        address prop = address(0x60);
        vm.prank(admin);
        grs.setProprietor(prop);

        vm.prank(admin);
        vm.expectRevert(IGRS.VoteGated.selector);
        grs.grant(IGRS.Bucket.GrowthFund, admin, 1e18, 0, 0, 0);

        vm.prank(prop);
        grs.grant(IGRS.Bucket.Audits, admin, 2e18, 0, 0, 0);
        assertEq(grs.spent(IGRS.Bucket.Audits), 2e18);
    }

    function test_SpokeCannotGrant() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        vm.prank(admin);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.grant(IGRS.Bucket.TokenSales, admin, 1e18, 0, 0, 0);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.getAllocations();
    }

    function test_HolderCanVestOwnTokens() public {
        address bob = address(0xB0B);
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, bob, 10e18, 0, 0, 0);

        uint64 start = uint64(block.timestamp);
        vm.prank(bob);
        uint256 id = grs.vest(bob, 10e18, start, 0, 30 days);

        assertEq(grs.balanceOf(bob), 0);
        assertEq(uint8(grs.getVestings()[0].bucket), uint8(IGRS.Bucket.Holder));
        assertEq(grs.getVestings()[0].funder, bob);
        assertEq(grs.spent(IGRS.Bucket.TokenSales), 10e18);

        vm.warp(start + 30 days);
        grs.release(id);
        assertEq(grs.balanceOf(bob), 10e18);
    }

    function test_VestRejectsInstant() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 1e18, 0, 0, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InstantNotVest.selector);
        grs.vest(admin, 1e18, 0, 0, 0);
    }

    function test_VestRejectsTooLongCliffOrUnlock() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 2e18, 0, 0, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidSchedule.selector);
        grs.vest(admin, 1e18, 0, 365 days + 1, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidSchedule.selector);
        grs.vest(admin, 1e18, 0, 0, 4 * 365 days + 1);
        vm.prank(admin);
        grs.vest(admin, 1e18, 0, 365 days, 4 * 365 days);
    }

    function test_SpokeHolderCanVest() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        deal(address(spoke), admin, 5e18);
        vm.prank(admin);
        uint256 id = spoke.vest(admin, 5e18, uint64(block.timestamp), 0, 7 days);
        assertEq(id, 1);
        assertEq(spoke.balanceOf(admin), 0);
        assertEq(spoke.balanceOf(address(spoke)), 5e18);
        assertEq(spoke.getVestings()[0].funder, admin);
    }

    function test_GrantCannotUseHolderBucket() public {
        vm.prank(admin);
        vm.expectRevert(IGRS.BucketExceeded.selector);
        grs.grant(IGRS.Bucket.Holder, admin, 1e18, 0, 0, 0);
    }

    function test_SetVeGRS() public {
        address vault = address(0x7E);
        vm.prank(admin);
        grs.setVeGRS(vault);
        assertEq(grs.veGRS(), vault);

        GRS spoke = new GRS(address(endpoint), admin, false);
        vm.prank(admin);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.setVeGRS(vault);
    }

    function test_SchedulesMatchSvg() public view {
        (uint32 c, uint32 d) = grs.scheduleOf(IGRS.Bucket.Seed);
        assertEq(c, 3);
        assertEq(d, 24);
        (c, d) = grs.scheduleOf(IGRS.Bucket.Advisors);
        assertEq(c, 6);
        assertEq(d, 66);
        assertEq(uint8(grs.gateOf(IGRS.Bucket.LpMm)), uint8(IGRS.Gate.Proprietary));
        assertEq(uint8(grs.gateOf(IGRS.Bucket.Legal)), uint8(IGRS.Gate.VoteGated));
    }
}
