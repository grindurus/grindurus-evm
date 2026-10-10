// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";

/// @dev Dump 5 on-chain Treasury card SVGs via `tokenURI` → `out/treasury-art-*.svg`.
contract DumpTreasuryArtTest is GRAIFixture {
    function test_DumpTreasuryArt() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));

        address[5] memory lockers = [
            makeAddr("locker0"),
            makeAddr("locker1"),
            makeAddr("locker2"),
            makeAddr("locker3"),
            makeAddr("locker4")
        ];
        // Varied books: root / L1 tree / transferred cashflow / larger books / mid values.
        // Mix of cents / K / M so compact `$N[.x]K|M` paths show up in dumps.
        uint256[5] memory amounts = [uint256(0.99e6), 100e6, 25e6, 2_000_000e6, 7.5e6];

        for (uint256 i; i < 5; ++i) {
            usdc.mint(lockers[i], amounts[i] + 1e6);
            vm.startPrank(lockers[i]);
            usdc.approve(address(grai), type(uint256).max);
            // 0: self-root; 1→0; 2→1; 3→0; 4→3 — builds L1/L2 on uplines.
            address ref = i == 0 ? address(0) : lockers[i == 2 ? 1 : (i == 4 ? 3 : 0)];
            grai.deposit(address(usdc), amounts[i], false, ref);
            vm.stopPrank();
        }

        // Transfer cashflow NFT of locker2 → locker4 so Owner ≠ Locker.
        vm.prank(lockers[2]);
        treasury.transferFrom(lockers[2], lockers[4], uint256(uint160(lockers[2])));

        for (uint256 i; i < 5; ++i) {
            uint256 tokenId = uint256(uint160(lockers[i]));
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.writeFile(
                string.concat("out/treasury-tokenuri-", vm.toString(i), ".txt"), treasury.tokenURI(tokenId)
            );
        }
    }
}
