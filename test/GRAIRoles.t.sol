// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
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

        (, uint32 id,) = grai.assets(asset);
        assertEq(grai.assetList(id), asset);
    }

    function test_OwnerCanSetAssetConfig() public {
        address asset = makeAddr("cfgAsset");
        _setFeedAsOwner(asset, new MockAggregator(8, 1e8));

        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(
                grai.setAssetConfig,
                (asset, IGRAI.AssetConfig({asset: asset, id: 0, paused: true}))
            )
        );

        (,, bool paused) = grai.assets(asset);
        assertTrue(paused);
    }

    function test_OwnerCanSetConfig() public {
        IGRAI.Config memory cfg = IGRAI.Config({
            buybackCutBps: 5_000,
            dividendCutBps: 3_000,
            treasuryCutBps: 2_000,
            claimTipBps: 100,
            bribePremiumBps: 300,
            quorumBps: 5_000,
            unlockFeeBps: 1_000,
            buybackPeriod: uint32(180 days),
            liquidationPeriod: uint32(12 hours),
            redeemPeriod: uint32(3 days),
            unlockPenaltyPeriod: uint32(24 hours)
        });
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.FULL, _packConfig(cfg)))
        );

        (
            uint16 buybackCutBps,
            uint16 dividendCutBps,
            uint16 treasuryCutBps,
            uint16 claimTipBps,
            uint16 bribePremiumBps,
            uint16 quorum,
            uint16 unlockFeeBps,
            uint32 buybackPeriod,
            uint32 liquidationPeriod,
            uint32 redeemPeriod,
            uint32 unlockPenaltyPeriod
        ) = grai.config();
        assertEq(buybackCutBps, 5_000);
        assertEq(dividendCutBps, 3_000);
        assertEq(treasuryCutBps, 2_000);
        assertEq(claimTipBps, 100);
        assertEq(bribePremiumBps, 300);
        assertEq(quorum, 5_000);
        assertEq(unlockFeeBps, 1_000);
        assertEq(buybackPeriod, 180 days);
        assertEq(liquidationPeriod, 12 hours);
        assertEq(redeemPeriod, 3 days);
        assertEq(unlockPenaltyPeriod, 24 hours);
    }

    function test_OwnerCanPatchClaimTipBps() public {
        _exec(
            ownerMultisig,
            ownerSigner,
            address(grai),
            abi.encodeCall(grai.setConfig, (IGRAI.ConfigId.CLAIM_TIP, uint256(50)))
        );
        (,,, uint16 claimTipBps,,,,,,,) = grai.config();
        assertEq(claimTipBps, 50);
    }

    function test_OwnerCanSetTreasuryAndVaults() public {
        address treasury = makeAddr("treasury");
        MockAggregator ethFeed = new MockAggregator(8, 1000e8);
        _setFeedAsOwner(address(0), ethFeed);

        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setTreasury, (treasury)));
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setGrinders, (address(grinders))));
        _exec(ownerMultisig, ownerSigner, address(grai), abi.encodeCall(grai.setBribeAsset, (address(0))));

        assertEq(grai.treasury(), treasury);
        assertEq(address(grai.grinders()), address(grinders));
        assertEq(grai.bribeAsset(), address(0));
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
            abi.encodeCall(
                grai.setAssetConfig,
                (address(0), IGRAI.AssetConfig({asset: address(0), id: 0, paused: true}))
            )
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
            feedType: 2,
            asset: asset,
            source: aggregator,
            data: bytes32(0),
            decimals: 0,
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

    function _packConfig(IGRAI.Config memory cfg) internal pure returns (uint256 data) {
        data = uint256(cfg.buybackCutBps) | (uint256(cfg.dividendCutBps) << 16) | (uint256(cfg.treasuryCutBps) << 32)
            | (uint256(cfg.claimTipBps) << 48) | (uint256(cfg.bribePremiumBps) << 64) | (uint256(cfg.quorumBps) << 80)
            | (uint256(cfg.unlockFeeBps) << 96) | (uint256(cfg.buybackPeriod) << 112)
            | (uint256(cfg.liquidationPeriod) << 144) | (uint256(cfg.redeemPeriod) << 176)
            | (uint256(cfg.unlockPenaltyPeriod) << 208);
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
