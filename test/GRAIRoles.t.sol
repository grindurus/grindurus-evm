// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @dev Ownable2Step handoff: deployer → ownerMultisig (GRAI + Grinders ownership).
contract GRAIRolesTest is Test {
    address internal constant DEPLOYER = address(0xA11CE);

    address internal ownerSigner = makeAddr("ownerSigner");

    MockMultisig internal ownerMultisig;

    Grinders internal grinders;
    GRAI internal grai;
    MockWETH internal weth;

    function setUp() public {
        ownerMultisig = _newMultisig(ownerSigner);
        weth = new MockWETH();

        GRAI tokenImpl = new GRAI();
        grai = GRAI(
            payable(
                address(
                    new ERC1967Proxy(
                        address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER, address(weth)))
                    )
                )
            )
        );

        Grinders impl = new Grinders();
        grinders = Grinders(
            payable(address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, address(grai))))
                ))
        );

        vm.startPrank(DEPLOYER);
        grai.setGrinders(address(grinders));
        grai.transferOwnership(address(ownerMultisig));
        grinders.transferOwnership(address(ownerMultisig));
        vm.stopPrank();

        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.acceptOwnership, ()));
        _exec(ownerMultisig, ownerSigner, address(grinders), abi.encodeCall(grinders.acceptOwnership, ()));
        assertEq(grinders.owner(), address(ownerMultisig));
    }

    //////////////////// OWNERSHIP ////////////////////

    function test_OwnerAfterHandoff() public view {
        assertEq(grai.owner(), address(ownerMultisig));
        assertEq(grai.pendingOwner(), address(0));
        assertEq(grinders.owner(), address(ownerMultisig));
    }

    function test_TwoStepTransferRequiresAccept() public {
        address next = makeAddr("nextOwner");
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.transferOwnership, (next)));
        assertEq(grai.owner(), address(ownerMultisig));
        assertEq(grai.pendingOwner(), next);

        vm.prank(next);
        grai.acceptOwnership();
        assertEq(grai.owner(), next);
        assertEq(grai.pendingOwner(), address(0));
    }

    function test_AcceptOwnershipDoesNotResetHeartbeat() public {
        assertTrue(grinders.alive());
        uint48 before = grinders.lastActiveAt();

        address next = makeAddr("nextOwner");
        _exec(ownerMultisig, ownerSigner, address(grinders), abi.encodeCall(grinders.transferOwnership, (next)));
        vm.prank(next);
        grinders.acceptOwnership();

        assertEq(grinders.owner(), next);
        assertEq(grinders.lastActiveAt(), before, "ownership handoff must not bump or clear heartbeat");
        assertTrue(grinders.alive());
    }

    function test_OwnerCannotRenounceOwnership() public {
        vm.expectRevert(IGRAI.OwnershipRenounceDisabled.selector);
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.renounceOwnership, ()));
    }

    function test_DeployerCannotCallOwnerFunctions() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grai.setTreasury(makeAddr("x"));
    }

    function test_StrangerCannotAcceptOwnership() public {
        address next = makeAddr("nextOwner");
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.transferOwnership, (next)));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        vm.prank(makeAddr("stranger"));
        grai.acceptOwnership();
    }

    //////////////////// OWNER OPS ////////////////////

    function test_OwnerSetFeedListsAsset() public {
        address asset = makeAddr("opsAsset");
        _setFeedAsOwner(asset, new MockAggregator(8, 1e8));

        (, uint32 id,,) = grai.assets(asset);
        assertEq(grai.assetList(id), asset);
    }

    function test_OwnerCanPauseViaSetFeed() public {
        address asset = makeAddr("cfgAsset");
        MockAggregator agg = new MockAggregator(8, 1e8);
        _setFeedAsOwner(asset, agg);

        IPriceOracleRouter.Feed memory feed = _chainlinkFeed(asset, address(agg));
        feed.paused = true;
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setFeed, (asset, feed)));

        (,,,,, bool paused,,,) = grai.feeds(asset);
        assertTrue(paused);
    }

    function test_OwnerCanSetConfig() public {
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.CLAIM_TIP, uint256(100)))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.REVENUE_SHARE, uint256(500)))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.BRIBE_PREMIUM, uint256(300)))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.QUORUM, uint256(5_000)))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.UNLOCK_PENALTY, uint256(1_000)))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.LIQUIDATION_PERIOD, uint256(uint32(12 hours))))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.REDEEM_PERIOD, uint256(uint32(3 days))))
        );
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.MAX_VETO_EXTENSION, uint256(uint32(14 days))))
        );

        (
            uint16 dividendCutBps,
            uint16 treasuryCutBps,
            uint16 revenueShareBps,
            uint16 claimTipBps,
            uint16 bribePremiumBps,
            uint16 quorum,
            uint16 unlockPenaltyBps,
            uint32 liquidationPeriod,
            uint32 redeemPeriod,
            uint32 maxVetoExtension
        ) = grai.config();
        // Yield cuts stay at initialize defaults (immutable via setConfig).
        assertEq(dividendCutBps, 5_000);
        assertEq(treasuryCutBps, 5_000);
        assertEq(revenueShareBps, 500);
        assertEq(claimTipBps, 100);
        assertEq(bribePremiumBps, 300);
        assertEq(quorum, 5_000);
        assertEq(unlockPenaltyBps, 1_000);
        assertEq(liquidationPeriod, 12 hours);
        assertEq(redeemPeriod, 3 days);
        assertEq(maxVetoExtension, 14 days);
    }

    function test_OwnerCanPatchClaimTipBps() public {
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.CLAIM_TIP, uint256(50)))
        );
        (,,, uint16 claimTipBps,,,,,,) = grai.config();
        assertEq(claimTipBps, 50);
    }

    function test_OwnerCanSetTreasuryAndVaults() public {
        Treasury nextImpl = new Treasury();
        address nextTreasury = address(
            new ERC1967Proxy(address(nextImpl), abi.encodeCall(Treasury.initialize, (address(grai))))
        );
        MockAggregator ethFeed = new MockAggregator(8, 1000e8);
        _setFeedAsOwner(address(0), ethFeed);

        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setTreasury, (nextTreasury)));
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setGrinders, (address(grinders))));
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setSettlementAsset, (address(0))));

        assertEq(address(grai.treasury()), nextTreasury);
        assertEq(address(grai.grinders()), address(grinders));
        assertEq(grai.settlementAsset(), address(0));
    }

    function test_NonOwnerCannotSetFeed() public {
        address asset = makeAddr("noAdmin");
        MockAggregator feed = new MockAggregator(8, 1e8);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grai.setFeed(asset, _chainlinkFeed(asset, address(feed)));
    }

    //////////////////// UPGRADES ////////////////////

    function test_OwnerCanUpgradeGraiToken() public {
        GRAI newImpl = new GRAI();
        _exec(
            ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.upgradeToAndCall, (address(newImpl), ""))
        );
        assertEq(_implementation(address(grai)), address(newImpl));
    }

    function test_OwnerCanUpgradeGrinders() public {
        Grinders newImpl = new Grinders();
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grinders),
            abi.encodeCall(grinders.upgradeToAndCall, (address(newImpl), ""))
        );
        assertEq(_implementation(address(grinders)), address(newImpl));
    }

    function test_DeployerCannotUpgradeGraiToken() public {
        GRAI newImpl = new GRAI();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grai.upgradeToAndCall(address(newImpl), "");
    }

    function test_DeployerCannotUpgradeGrinders() public {
        Grinders newImpl = new Grinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grinders.upgradeToAndCall(address(newImpl), "");
    }

    //////////////////// GRINDERS OWNABLE ////////////////////

    function test_OwnerCanAllocateGate_RevertsUnknownCustodian() public {
        vm.expectRevert();
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grinders),
            abi.encodeCall(grinders.allocate, (makeAddr("unknown"), address(0), 1))
        );
    }

    function test_StrangerCannotTransferOwnership() public {
        Grinders fresh = _deployFreshGrinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        vm.prank(makeAddr("stranger"));
        fresh.transferOwnership(makeAddr("other"));
    }

    function test_NonOwnerCannotDriveOwnerMultisig() public {
        vm.expectRevert("not owner");
        _exec(
            ownerMultisig,
            makeAddr("stranger"),
            address(grai),
            abi.encodeCall(grai.setFeed, (address(0), _chainlinkFeed(address(0), address(0))))
        );
    }

    //////////////////// HELPERS ////////////////////

    function _newMultisig(address owner_) internal returns (MockMultisig m) {
        address[] memory owners_ = new address[](1);
        owners_[0] = owner_;
        m = new MockMultisig(owners_, 1);
    }

    function _setFeedAsOwner(address asset, MockAggregator feed) internal {
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setFeed, (asset, _chainlinkFeed(asset, address(feed))))
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
            maxStaleness: 1 hours
        });
    }

    function _deployFreshGrinders() internal returns (Grinders fresh) {
        GRAI tokenImpl = new GRAI();
        address graiAddr = address(
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER, address(weth))))
        );
        Grinders impl = new Grinders();
        fresh = Grinders(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, graiAddr)))))
        );
    }

    function _exec(MockMultisig multisig, address signer, address target, bytes memory data) internal {
        vm.prank(signer);
        multisig.exec(target, data);
    }

    function _implementation(address proxy) private view returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        impl = address(uint160(uint256(vm.load(proxy, slot))));
    }
}
