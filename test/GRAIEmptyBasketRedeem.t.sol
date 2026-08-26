// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";

/// @dev Mock Grinders that satisfies `grai()` / `alive() == false` for the open gate, but always
///      reverts on liquidate — GRAI must propagate that revert (no try/catch on open sweeps).
contract RevertingGrinders {
    address public grai;

    constructor(address grai_) {
        grai = grai_;
    }

    function alive() external pure returns (bool) {
        return false;
    }

    function liquidate(uint256, uint256) external pure {
        revert("sweep failed");
    }

    function revive() external {}
}

/// @dev Open is atomic with Grinders sweeps: a reverting `grinders.liquidate` aborts liquidation.
contract GRAIEmptyBasketRedeemTest is GRAIFixture {
    uint256 constant DEPOSIT = 1_000e6;

    /// @dev Counter to the old swallowed-sweep PoC: open must revert when Grinders sweep reverts.
    function test_LiquidateReverts_WhenGrindersLiquidateReverts() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        uint256 graiOut = _deposit(alice, usdc, DEPOSIT);
        assertEq(usdc.balanceOf(address(grinders)), DEPOSIT);

        vm.prank(alice);
        grai.vote(graiOut);
        assertTrue(grai.hasQuorum());

        vm.warp(block.timestamp + uint256(grinders.vetoPeriod()) + 1);
        RevertingGrinders bad = new RevertingGrinders(address(grai));
        vm.prank(admin);
        grai.setGrinders(address(bad));

        vm.prank(admin);
        vm.expectRevert(bytes("sweep failed"));
        grai.liquidate();
        assertFalse(grai.liquidation(), "open must not stick after sweep revert");
        assertEq(usdc.balanceOf(address(grinders)), DEPOSIT, "principal stays on old grinders");
    }

    /// @dev High-level call to an EOA is not a successful sweep — unset `grinders` (still admin)
    ///      aborts open. Also `alive()` on an EOA reverts before the body.
    function test_LiquidateReverts_WhenGrindersIsEOA() public {
        assertEq(address(grai.grinders()), admin);

        uint256 graiOut = _deposit(alice, usdc, DEPOSIT);
        assertEq(usdc.balanceOf(admin), DEPOSIT);

        vm.prank(alice);
        grai.vote(graiOut);

        // Skip alive gate via hard-cap path: quorum clock + max extension.
        IGRAI.Config memory cfg = _readConfig();
        vm.warp(block.timestamp + uint256(cfg.maxVetoExtension) + 1);

        vm.prank(admin);
        vm.expectRevert();
        grai.liquidate();
        assertFalse(grai.liquidation());
    }

    function test_LiquidateReverts_WhenGrindersStillAlive() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        uint256 graiOut = _deposit(alice, usdc, DEPOSIT);
        vm.prank(alice);
        grai.vote(graiOut);
        assertTrue(grai.hasQuorum());
        assertTrue(grinders.alive());

        vm.expectRevert(IGRAI.GrindersActive.selector);
        grai.liquidate();
        assertFalse(grai.liquidation());
    }
}
