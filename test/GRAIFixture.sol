// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {Custodian} from "../src/Custodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custodian;

    Grinders grinders;
    GRAI grai;
    Treasury treasury;

    MockERC20 usdc; // 6 decimals
    MockWETH weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;
    uint16 constant DIVIDEND_CUT_BPS = 5_000;
    uint16 constant TREASURY_CUT_BPS = 5_000;
    uint256 constant DEFAULT_MAX_STALENESS = 1 hours;

    function setUp() public virtual {
        weth = new MockWETH();

        vm.startPrank(admin);
        address tokenAddr = _deployGraiToken();
        grai = GRAI(payable(tokenAddr));

        Treasury treasuryImpl = new Treasury();
        treasury = Treasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(treasuryImpl), abi.encodeCall(Treasury.initialize, (tokenAddr))
                    )
                )
            )
        );
        grai.setTreasury(address(treasury));

        Grinders impl = new Grinders();
        bytes memory init = abi.encodeCall(Grinders.initialize, (admin, tokenAddr));
        grinders = Grinders(payable(address(new ERC1967Proxy(address(impl), init))));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        _setChainlinkFeed(address(usdc), address(usdcFeed));
        _setChainlinkFeed(address(weth), address(wethFeed));
        _setAssetPause(address(usdc), false);
        _setAssetPause(address(weth), false);
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
        return address(
            new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (tokenAdmin, address(weth))))
        );
    }

    function _registerTestCustodian() internal virtual {
        LiFiCustodian impl = new LiFiCustodian();
        custodian = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(Custodian.initialize, (address(grinders))))
        );
        grinders.register(custodian, admin);
        grinders.setAssets(custodian, address(usdc), address(weth));
    }

    function _allocate(address asset, address custodian_, uint256 amount) internal {
        vm.prank(admin);
        grinders.allocate(custodian_, asset, amount);
    }

    function _setChainlinkFeed(address asset, address aggregator) internal {
        grai.setFeed(asset, _chainlinkFeed(asset, aggregator));
    }

    function _setAssetPause(address asset, bool paused) internal {
        (
            IPriceOracleRouter.FeedType feedType,
            address feedAsset,
            address source,
            uint8 decimals,
            bytes32 data,
            ,
            int256 storedPrice,
            uint256 storedUpdatedAt,
            uint256 maxStaleness
        ) = grai.feeds(asset);
        grai.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: feedType,
                asset: feedAsset,
                source: source,
                decimals: decimals,
                data: data,
                paused: paused,
                storedPrice: storedPrice,
                storedUpdatedAt: storedUpdatedAt,
                maxStaleness: maxStaleness
            })
        );
    }

    /// @dev Clearing a feed (FeedType.NONE) delists the asset (paused, zero balance, zero totalClaimable).
    function _clearFeed(address asset) internal {
        grai.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: IPriceOracleRouter.FeedType.NONE,
                asset: asset,
                source: address(0),
                decimals: 0,
                data: bytes32(0),

            paused: false,
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
                feedType: IPriceOracleRouter.FeedType.PYTH,
                asset: asset,
                source: pyth,
                decimals: 0,
                data: priceId,

            paused: false,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );
    }

    function _chainlinkFeed(address asset, address aggregator) internal pure returns (IPriceOracleRouter.Feed memory) {
        return IPriceOracleRouter.Feed({
            feedType: IPriceOracleRouter.FeedType.CHAINLINK,
            asset: asset,
            source: aggregator,
            decimals: 0,
            data: bytes32(0),

            paused: false,
            storedPrice: 0,
            storedUpdatedAt: 0,
            maxStaleness: DEFAULT_MAX_STALENESS
        });
    }

    function _setSettlementAsset(address asset) internal {
        vm.prank(admin);
        grai.setSettlementAsset(asset);
    }

    function _readConfig() internal view returns (IGRAI.Config memory cfg) {
        (
            cfg.dividendCutBps,
            cfg.treasuryCutBps,
            cfg.revenueShareBps,
            cfg.claimTipBps,
            cfg.bribePremiumBps,
            cfg.quorumBps,
            cfg.unlockPenaltyBps,
            cfg.liquidationPeriod,
            cfg.redeemPeriod
        ) = grai.config();
    }

    /// @dev Test economics often assume 50/50; initialize defaults match.
    ///      Yield cuts are immutable via `setConfig` — poke the packed config word for tests only.
    function _setYieldSplitFiftyFifty() internal {
        IGRAI.Config memory cfg = _readConfig();
        cfg.dividendCutBps = DIVIDEND_CUT_BPS;
        cfg.treasuryCutBps = TREASURY_CUT_BPS;
        _writeConfig(cfg);
    }

    /// @dev Packed `config` is one storage word (current OZ layout). Update if inheritance changes.
    ///      `forge inspect GRAI storage-layout` → `config` slot.
    uint256 private constant _CONFIG_SLOT = 14;

    function _writeConfig(IGRAI.Config memory cfg) internal {
        vm.store(address(grai), bytes32(_CONFIG_SLOT), bytes32(_packConfig(cfg)));
    }

    function _packConfig(IGRAI.Config memory cfg) internal pure returns (uint256 data) {
        data = uint256(cfg.dividendCutBps) | (uint256(cfg.treasuryCutBps) << 16)
            | (uint256(cfg.revenueShareBps) << 32) | (uint256(cfg.claimTipBps) << 48)
            | (uint256(cfg.bribePremiumBps) << 64) | (uint256(cfg.quorumBps) << 80)
            | (uint256(cfg.unlockPenaltyBps) << 96) | (uint256(cfg.liquidationPeriod) << 112)
            | (uint256(cfg.redeemPeriod) << 144);
    }

    function _deposit(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(grai), amount);
        (graiOut,) = grai.deposit(address(token), amount, false, address(0));
        vm.stopPrank();
    }

    function _fundGrinders(MockERC20 token, uint256 amount) internal {
        token.mint(address(grinders), amount);
    }

    /// @dev Warp past Grinders `vetoPeriod` then open GRAI liquidation (requires quorum already).
    function _openLiquidation() internal {
        vm.startPrank(admin);
        if (address(grai.grinders()) != address(grinders)) {
            grai.setGrinders(address(grinders));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + uint256(grinders.vetoPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        assertEq(grai.assetList(0), expectedAsset);
        assertEq(IERC20(expectedAsset).balanceOf(address(grai)), expectedSenior);
        assertEq(grinders.balance(expectedAsset), expectedJunior);
    }
}
