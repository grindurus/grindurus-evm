// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

/// @dev Mock Grinders that satisfies `grai()` for `setGrinders` but always reverts on liquidate.
contract RevertingGrinders {
    address public grai;

    constructor(address grai_) {
        grai = grai_;
    }

    function liquidate(uint256, uint256) external pure {
        revert("sweep failed");
    }
}

/// @dev PoC for audit #3: empty-basket redeem burns book when Grinders sweep is swallowed.
contract GRAIEmptyBasketRedeemTest is GRAIFixture {
    uint256 constant DEPOSIT = 1_000e6;

    /// @dev Confirms finding #3: `try/catch` swallows a reverting Grinders sweep, liquidation
    ///      still opens, and after the delay `redeem` burns book for an empty payout vector.
    function test_RedeemBurnsBook_WhenGrindersLiquidateReverts() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        uint256 graiOut = _deposit(alice, usdc, DEPOSIT);
        assertEq(usdc.balanceOf(address(grinders)), DEPOSIT);

        // Swap to a grinders that always reverts on liquidate (assets stay on the old Grinders).
        RevertingGrinders bad = new RevertingGrinders(address(grai));
        vm.prank(admin);
        grai.setGrinders(address(bad));

        vm.prank(alice);
        grai.vote(graiOut);
        assertTrue(grai.hasQuorum());

        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation(), "open succeeds despite sweep revert");
        assertEq(usdc.balanceOf(address(grai)), 0, "nothing landed on GRAI");
        assertEq(usdc.balanceOf(address(grinders)), DEPOSIT, "still on old grinders");

        IGRAI.Config memory cfg = _readConfig();
        vm.warp(block.timestamp + uint256(cfg.liquidationPeriod));

        (address[] memory assets, uint256[] memory amounts) = grai.previewRedeem(alice, graiOut);
        assertEq(assets.length, 0, "empty payout vector");
        assertEq(amounts.length, 0);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bookBefore = grai.totalValue();
        assertEq(bookBefore, DEPOSIT);

        vm.prank(alice);
        grai.redeem(graiOut);

        assertEq(grai.balanceOf(alice), 0, "shares burned");
        assertEq(grai.totalSupply(), 0, "supply burned");
        assertEq(grai.totalValue(), 0, "book cut to zero");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "received zero assets");
        assertEq(usdc.balanceOf(address(grinders)), DEPOSIT, "principal stranded on grinders");
    }

    /// @dev High-level call to an EOA is not swallowed by `try/catch` (extcodesize check) —
    ///      so unset `grinders` (still admin) aborts open rather than empty-basket redeem.
    function test_LiquidateReverts_WhenGrindersIsEOA() public {
        assertEq(address(grai.grinders()), admin);

        uint256 graiOut = _deposit(alice, usdc, DEPOSIT);
        assertEq(usdc.balanceOf(admin), DEPOSIT);

        vm.prank(alice);
        grai.vote(graiOut);

        vm.prank(admin);
        vm.expectRevert();
        grai.liquidate();
        assertFalse(grai.liquidation());
    }
}
