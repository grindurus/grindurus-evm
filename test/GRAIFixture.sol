// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockTreasuryNFT} from "./mocks/MockTreasuryNFT.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custody = makeAddr("custody");

    GRAI grai;
    MockTreasuryNFT treasuryNft;
    address treasury;

    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;
    uint16 constant DEFAULT_MINT_SPLIT = 5_000;
    uint16 constant DEFAULT_YIELD_SPLIT = 8_000;
    uint256 constant DEFAULT_MAX_STALENESS = 1 hours;

    function setUp() public virtual {
        GRAI impl = new GRAI();
        bytes memory init = abi.encodeCall(GRAI.initialize, (admin));
        grai = GRAI(payable(address(new ERC1967Proxy(address(impl), init))));

        treasuryNft = new MockTreasuryNFT();
        treasury = address(treasuryNft);
        treasuryNft.setGrai(address(grai));
        treasuryNft.setCustodian(custody, 0);

        vm.prank(admin);
        grai.setTreasury(treasury);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        vm.startPrank(admin);
        _setChainlinkFeed(address(usdc), address(usdcFeed));
        _setChainlinkFeed(address(weth), address(wethFeed));
        grai.addAsset(address(usdc), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        grai.addAsset(address(weth), DEFAULT_MINT_SPLIT, DEFAULT_YIELD_SPLIT);
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        usdc.mint(custody, 1_000e6); // for distribute
        weth.mint(alice, 100e18);
    }

    function _setChainlinkFeed(address asset, address aggregator) internal {
        grai.setFeed(asset, _chainlinkFeed(asset, aggregator));
    }

    function _setPythFeed(address asset, address pyth, bytes32 priceId) internal {
        grai.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: 3,
                asset: asset,
                source: pyth,
                data: priceId,
                decimals: 0,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );
    }

    function _chainlinkFeed(address asset, address aggregator) internal pure returns (IPriceOracleRouter.Feed memory) {
        return IPriceOracleRouter.Feed({
            feedType: 2,
            asset: asset,
            source: aggregator,
            data: bytes32(0),
            decimals: 0,
            storedPrice: 0,
            storedUpdatedAt: 0,
            maxStaleness: DEFAULT_MAX_STALENESS
        });
    }

    function _mint(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(grai), amount);
        graiOut = grai.mint(address(token), amount);
        vm.stopPrank();
    }

    function _getVaultSnapshots() internal view returns (IGRAI.VaultSnapshot[] memory) {
        return grai.getVaultsData();
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        IGRAI.VaultSnapshot[] memory snap = _getVaultSnapshots();
        assertEq(snap.length, 2);
        assertEq(snap[0].asset, expectedAsset);
        assertEq(snap[0].seniorBalance, expectedSenior);
        assertEq(snap[0].juniorBalance, expectedJunior);
    }
}
