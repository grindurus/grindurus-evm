// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {PriceOracleRouter} from "../src/PriceOracleRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custody = makeAddr("custody");

    GRAI grai;
    PriceOracleRouter oracle;

    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;
    uint16 constant DEFAULT_MINT_SPLIT = 5_000;
    uint16 constant DEFAULT_YIELD_SPLIT = 8_000;

    function setUp() public virtual {
        PriceOracleRouter oracleImpl = new PriceOracleRouter();
        oracle = PriceOracleRouter(
            address(
                new ERC1967Proxy(address(oracleImpl), abi.encodeCall(PriceOracleRouter.initialize, (admin)))
            )
        );

        GRAI impl = new GRAI();
        bytes memory init = abi.encodeCall(GRAI.initialize, (admin, address(oracle), treasury));
        grai = GRAI(payable(address(new ERC1967Proxy(address(impl), init))));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        vm.startPrank(admin);
        oracle.addChainlinkFeed(address(usdc), address(usdcFeed));
        oracle.addChainlinkFeed(address(weth), address(wethFeed));
        grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        grai.addAsset(address(weth), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        usdc.mint(custody, 1_000e6); // for distribute
        weth.mint(alice, 100e18);
    }

    function _mint(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(grai), amount);
        graiOut = grai.mint(address(token), amount);
        vm.stopPrank();
    }

    function _getVaultSnapshots() internal view returns (GRAI.VaultSnapshot[] memory) {
        return grai.getVaults();
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        GRAI.VaultSnapshot[] memory snap = _getVaultSnapshots();
        assertEq(snap.length, 2);
        assertEq(snap[0].asset, expectedAsset);
        assertEq(snap[0].seniorBalance, expectedSenior);
        assertEq(snap[0].juniorBalance, expectedJunior);
    }
}
