// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {Custodian} from "../src/Custodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custodian;

    Grinders grinders;
    GRAI grai;

    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;
    uint16 constant DEFAULT_TREASURY_SHARE = 2_000;
    uint256 constant DEFAULT_MAX_STALENESS = 1 hours;

    function setUp() public virtual {
        vm.startPrank(admin);
        address tokenAddr = _deployGraiToken();
        grai = GRAI(payable(tokenAddr));

        Grinders impl = new Grinders();
        bytes memory init = abi.encodeCall(Grinders.initialize, (admin, tokenAddr));
        grinders = Grinders(payable(address(new ERC1967Proxy(address(impl), init))));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        // setFeed lists the asset (yield split defaults to 0); set the split explicitly.
        _setChainlinkFeed(address(usdc), address(usdcFeed));
        _setChainlinkFeed(address(weth), address(wethFeed));
        _setAssetConfig(address(usdc), false);
        _setAssetConfig(address(weth), false);
        _registerTestCustodian();
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        if (custodian != address(0)) usdc.mint(custodian, 1_000e6); // for distribute
        weth.mint(alice, 100e18);
    }

    function _deployGraiToken() internal returns (address) {
        return _deployGraiToken(admin);
    }

    function _deployGraiToken(address tokenAdmin) internal returns (address) {
        GRAI impl = new GRAI();
        return address(new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (tokenAdmin))));
    }

    function _registerTestCustodian() internal virtual {
        LiFiCustodian impl = new LiFiCustodian();
        custodian = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(Custodian.initialize, (address(grinders), address(usdc), address(weth)))
            )
        );
        grinders.register(custodian, admin);
    }

    function _allocate(address asset, address custodian_, uint256 amount) internal {
        vm.prank(admin);
        grinders.allocate(custodian_, asset, amount);
    }

    function _setChainlinkFeed(address asset, address aggregator) internal {
        grai.setFeed(asset, _chainlinkFeed(asset, aggregator));
    }

    function _setAssetConfig(address asset, bool paused) internal {
        grai.setAssetConfig(asset, IGRAI.AssetConfig({asset: asset, id: 0, paused: paused}));
    }

    function _setTreasuryShare(uint16 treasuryShare) internal {
        (
            ,
            uint16 bribePremiumBps,
            uint16 liquidationQuorumBps,
            uint32 auctionDuration,
            uint32 liquidationPeriod,
            uint32 redeemPeriod
        ) = grai.config();
        grai.setProtocolConfig(
            IGRAI.ProtocolConfig({
                treasuryShare: treasuryShare,
                bribePremiumBps: bribePremiumBps,
                liquidationQuorumBps: liquidationQuorumBps,
                auctionDuration: auctionDuration,
                liquidationPeriod: liquidationPeriod,
                redeemPeriod: redeemPeriod
            })
        );
    }

    /// @dev Clearing a feed (FEED_NONE) delists the asset (must be paused with zero balance).
    function _clearFeed(address asset) internal {
        grai.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: 0,
                asset: asset,
                source: address(0),
                data: bytes32(0),
                decimals: 0,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: 0
            })
        );
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

    function _setSettlementAsset(address asset) internal {
        vm.prank(admin);
        grai.setSettlementAsset(asset);
    }

    /// @dev Fill the open yield auction for `asset` as `buyer`, paying with `settlementAsset`.
    function _fill(address buyer, address asset, uint256 amount, uint256 paymentMax) internal {
        address payAsset = grai.settlementAsset();
        vm.startPrank(buyer);
        if (payAsset != address(0)) {
            IERC20(payAsset).approve(address(grai), paymentMax);
            grai.fill(asset, amount, paymentMax);
        } else {
            grai.fill{value: paymentMax}(asset, amount, paymentMax);
        }
        vm.stopPrank();
    }

    function _deposit(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(grai), amount);
        (graiOut,) = grai.deposit(address(token), amount);
        vm.stopPrank();
    }

    function _fundGrinders(MockERC20 token, uint256 amount) internal {
        token.mint(address(grinders), amount);
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        assertEq(grai.assetList(0), expectedAsset);
        assertEq(grinders.grai().balance(expectedAsset), expectedSenior);
        assertEq(grinders.balance(expectedAsset), expectedJunior);
    }
}
