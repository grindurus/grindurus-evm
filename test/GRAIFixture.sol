// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {GRAIVault} from "../src/GRAIVault.sol";
import {PriceOracleRouter} from "../src/PriceOracleRouter.sol";
import {SeniorVault} from "../src/SeniorVault.sol";
import {JuniorVault} from "../src/JuniorVault.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custody = makeAddr("custody");

    GRAI grai;
    GRAIVault vault;
    PriceOracleRouter oracle;

    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;

    function setUp() public virtual {
        // --- token (UUPS proxy) ---
        GRAI tokenImpl = new GRAI();
        bytes memory tokenInit = abi.encodeCall(GRAI.initialize, (admin));
        grai = GRAI(address(new ERC1967Proxy(address(tokenImpl), tokenInit)));

        // --- oracle + tranche templates ---
        oracle = new PriceOracleRouter();
        address seniorImpl = address(new SeniorVault());
        address juniorImpl = address(new JuniorVault());

        // --- vault (UUPS proxy) ---
        GRAIVault vaultImpl = new GRAIVault();
        bytes memory vaultInit = abi.encodeCall(
            GRAIVault.initialize, (admin, address(grai), address(oracle), seniorImpl, juniorImpl, treasury)
        );
        vault = GRAIVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // --- wire minter role ---
        bytes32 minterRole = grai.MINTER_ROLE();
        vm.prank(admin);
        grai.grantRole(minterRole, address(vault));

        // --- assets + feeds ---
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        vm.startPrank(admin);
        vault.addAsset(address(usdc), address(usdcFeed));
        vault.addAsset(address(weth), address(wethFeed));
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        usdc.mint(custody, 1_000e6); // for distribute
        weth.mint(alice, 100e18);
    }

    function _mint(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(vault), amount);
        graiOut = vault.mint(address(token), amount);
        vm.stopPrank();
    }

    function _getVaultSnapshots() internal view returns (GRAIVault.VaultSnapshot[] memory) {
        return vault.getVaults();
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        GRAIVault.VaultSnapshot[] memory snap = _getVaultSnapshots();
        assertEq(snap.length, 2);
        assertEq(snap[0].asset, expectedAsset);
        assertEq(snap[0].seniorBalance, expectedSenior);
        assertEq(snap[0].juniorBalance, expectedJunior);
    }
}
