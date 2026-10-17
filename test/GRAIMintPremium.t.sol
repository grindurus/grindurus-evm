// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {GRAIFixture} from "./GRAIFixture.sol";

contract GRAIMintPremiumTest is GRAIFixture {
    function test_previewDeposit_parInYearZero() public view {
        (, , , , , , , , , , uint16 mintPremium) = grai.config();
        assertEq(mintPremium, 5_00);
        (, uint256 graiOut) = grai.previewDeposit(address(usdc), 100e6);
        assertEq(graiOut, 100e6);
    }

    function test_previewDeposit_compoundsFivePercentPerYear() public {
        uint48 start = grai.mintPremiumAt();
        // Seed book so preview uses supply/value path after first deposit isn't needed —
        // empty book: book == value, ask still applies.
        vm.warp(uint256(start) + 365 days);
        usdcFeed.setAnswer(1e8);
        (, uint256 graiOut1) = grai.previewDeposit(address(usdc), 105e6);
        // $105 book at 1.05 ask → 100 GRAI
        assertEq(graiOut1, (105e6 * uint256(BPS)) / 10_500);

        vm.warp(uint256(start) + 2 * 365 days);
        usdcFeed.setAnswer(1e8);
        (, uint256 graiOut2) = grai.previewDeposit(address(usdc), 110_25e2 * 100); // $110.25
        // priceBps = 11025; graiOut = value * 10000 / 11025
        assertEq(graiOut2, (110_25e4 * uint256(BPS)) / 11_025);
    }

    function test_deposit_yearOneMintsFewerShares_creditsFullValue() public {
        uint256 amount = 100e6; // $100 USDC
        vm.prank(alice);
        usdc.approve(address(grai), amount);
        vm.prank(alice);
        (uint256 graiOut0, uint256 value0) = grai.deposit(address(usdc), amount, false, address(0));
        assertEq(value0, 100e6);
        assertEq(graiOut0, 100e6); // year 0 par
        assertEq(grai.totalValue(), 100e6);
        assertEq(grai.totalSupply(), 100e6);

        uint48 start = grai.mintPremiumAt();
        vm.warp(uint256(start) + 365 days);
        usdcFeed.setAnswer(1e8); // refresh oracle timestamp after warp

        usdc.mint(bob, amount);
        vm.prank(bob);
        usdc.approve(address(grai), amount);
        vm.prank(bob);
        (uint256 graiOut1, uint256 value1) = grai.deposit(address(usdc), amount, false, address(0));
        assertEq(value1, 100e6);
        // book = 100e6; ask 1.05 → 100e6 * 10000 / 10500
        assertEq(graiOut1, (100e6 * uint256(BPS)) / 10_500);
        assertEq(grai.totalValue(), 200e6);
        assertEq(grai.totalSupply(), graiOut0 + graiOut1);
        // Book NAV/share > $1 for existing holders
        assertGt((grai.totalValue() * 1e6) / grai.totalSupply(), 1e6);
    }

    function test_setConfig_mintPremiumZeroRestoresBookMint() public {
        uint48 start = grai.mintPremiumAt();
        vm.warp(uint256(start) + 365 days);
        usdcFeed.setAnswer(1e8);
        (, uint256 graiOutPremium) = grai.previewDeposit(address(usdc), 100e6);
        assertEq(graiOutPremium, (100e6 * uint256(BPS)) / 10_500);

        vm.prank(admin);
        grai.setConfig(IGRAI.ConfigId.MINT_PREMIUM, 0);
        (, uint256 graiOutPar) = grai.previewDeposit(address(usdc), 100e6);
        assertEq(graiOutPar, 100e6);
    }
}
