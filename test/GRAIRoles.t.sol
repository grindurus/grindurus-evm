// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";

/// @dev Production-like role split against current GRAI / Grinders:
///      - opsMultisig:        ADMIN_ROLE (feeds/asset listing + config)
///      - upgradeMultisig:    DEFAULT_ADMIN_ROLE + Grinders Ownable
contract GRAIRolesTest is Test {
    address internal constant DEPLOYER = address(0xA11CE);

    address internal opsOwner = makeAddr("opsOwner");
    address internal oracleOwner = makeAddr("oracleOwner");
    address internal upgradeOwner = makeAddr("upgradeOwner");

    MockMultisig internal opsMultisig;
    MockMultisig internal oracleMultisig;
    MockMultisig internal upgradeMultisig;

    Grinders internal grinders;
    GRAI internal grai;

    function setUp() public {
        opsMultisig = _newMultisig(opsOwner);
        oracleMultisig = _newMultisig(oracleOwner);
        upgradeMultisig = _newMultisig(upgradeOwner);

        GRAI tokenImpl = new GRAI();
        grai = GRAI(payable(address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER))))));

        Grinders impl = new Grinders();
        grinders = Grinders(
            payable(address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, address(grai))))
                ))
        );

        bytes32 adminRole = grai.ADMIN_ROLE();
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();

        vm.startPrank(DEPLOYER);
        grai.setGrinders(address(grinders));
        grai.grantRole(adminRole, address(opsMultisig));
        grai.revokeRole(adminRole, DEPLOYER);
        grai.grantRole(defaultAdminRole, address(upgradeMultisig));
        grai.revokeRole(defaultAdminRole, DEPLOYER);
        grinders.transferOwnership(address(upgradeMultisig));
        vm.stopPrank();
    }

    //////////////////// ROLE SPLIT ////////////////////

    function test_RoleSplit_AfterHandoff() public view {
        assertFalse(grai.hasRole(grai.ADMIN_ROLE(), DEPLOYER));
        assertTrue(grai.hasRole(grai.ADMIN_ROLE(), address(opsMultisig)));

        assertFalse(grai.hasRole(grai.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertTrue(grai.hasRole(grai.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));
        assertTrue(grai.hasRole(grai.GRINDERS_ROLE(), address(grinders)));

        assertEq(grinders.owner(), address(upgradeMultisig));
    }

    function test_OwnershipTransferIsImmediate() public {
        Grinders fresh = _deployFreshGrinders();
        assertEq(fresh.owner(), DEPLOYER);

        vm.prank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));

        assertEq(fresh.owner(), address(upgradeMultisig));
    }

    //////////////////// ADMIN_ROLE ////////////////////

    function test_AdminSetFeedListsAsset() public {
        address asset = makeAddr("opsAsset");
        _setFeedAsAdmin(asset, new MockAggregator(8, 1e8));

        // setFeed auto-lists the asset with a default (zero) yield split.
        (, uint32 id,, uint16 split) = grai.assets(asset);
        assertEq(split, 0);
        assertEq(grai.assetList(id), asset);
    }

    function test_OpsCanSetAssetConfig() public {
        address asset = makeAddr("cfgAsset");
        _setFeedAsAdmin(asset, new MockAggregator(8, 1e8)); // setFeed lists the asset

        _exec(
            opsMultisig,
            opsOwner,
            address(grai),
            abi.encodeCall(
                grai.setAssetConfig,
                (asset, IGRAI.AssetConfig({asset: asset, id: 0, paused: true, treasuryShare: 5_000}))
            )
        );

        (,, bool paused, uint16 split) = grai.assets(asset);
        assertEq(split, 5_000);
        assertTrue(paused);
    }

    function test_DeployerCannotCallAdminFunctions() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, adminRole)
        );
        vm.prank(DEPLOYER);
        grai.setAssetConfig(address(0), IGRAI.AssetConfig({asset: address(0), id: 0, paused: true, treasuryShare: 0}));
    }

    function test_OracleCannotCallAdminFunctions() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(oracleMultisig), adminRole
            )
        );
        vm.prank(address(oracleMultisig));
        grai.setAssetConfig(address(0), IGRAI.AssetConfig({asset: address(0), id: 0, paused: true, treasuryShare: 0}));
    }

    function test_UpgradeCannotCallAdminFunctions() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(upgradeMultisig), adminRole
            )
        );
        vm.prank(address(upgradeMultisig));
        grai.setAssetConfig(address(0), IGRAI.AssetConfig({asset: address(0), id: 0, paused: true, treasuryShare: 0}));
    }

    //////////////////// SET FEED (ADMIN_ROLE) ////////////////////

    function test_AdminCanSetFeed() public {
        address asset = makeAddr("adminAsset");
        MockAggregator feed = new MockAggregator(8, 2e8);
        _setFeedAsAdmin(asset, feed);
        (,, address source,,,,,) = grai.feeds(asset);
        assertEq(source, address(feed));
    }

    function test_NonAdminCannotSetFeed() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        address asset = makeAddr("noAdmin");
        MockAggregator feed = new MockAggregator(8, 1e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(oracleMultisig), adminRole
            )
        );
        vm.prank(address(oracleMultisig));
        grai.setFeed(asset, _chainlinkFeed(asset, address(feed)));
    }

    function test_DeployerCannotSetFeed() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        address asset = makeAddr("noAdmin2");
        MockAggregator feed = new MockAggregator(8, 1e8);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, adminRole)
        );
        vm.prank(DEPLOYER);
        grai.setFeed(asset, _chainlinkFeed(asset, address(feed)));
    }

    //////////////////// DEFAULT_ADMIN_ROLE ////////////////////

    function test_UpgradeCanSetConfig() public {
        IGRAI.ProtocolConfig memory cfg = IGRAI.ProtocolConfig({
            bribePremiumBps: 300,
            liquidationQuorumBps: 5_000,
            auctionDuration: uint32(180 days),
            liquidationPeriod: uint32(12 hours),
            redeemPeriod: uint32(3 days)
        });
        _exec(upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.setProtocolConfig, (cfg)));

        (uint16 bribePremiumBps, uint16 quorum, uint32 auctionDuration, uint32 liquidationPeriod, uint32 redeemPeriod) =
            grai.config();
        assertEq(bribePremiumBps, 300);
        assertEq(quorum, 5_000);
        assertEq(auctionDuration, 180 days);
        assertEq(liquidationPeriod, 12 hours);
        assertEq(redeemPeriod, 3 days);
    }

    function test_UpgradeCanSetTreasuryAndVaults() public {
        address treasury = makeAddr("treasury");
        MockAggregator ethFeed = new MockAggregator(8, 1000e8);
        _setFeedAsAdmin(address(0), ethFeed);

        _exec(upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.setTreasury, (treasury)));
        _exec(upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.setGrinders, (address(grinders))));
        _exec(upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.setSettlementAsset, (address(0))));

        assertEq(grai.treasury(), treasury);
        assertEq(address(grai.grinders()), address(grinders));
        assertEq(grai.settlementAsset(), address(0));
    }

    function test_OpsCannotCallDefaultAdminFunctions() public {
        bytes32 defaultAdmin = grai.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), defaultAdmin
            )
        );
        vm.prank(address(opsMultisig));
        grai.setTreasury(makeAddr("x"));
    }

    function test_UpgradeMultisigControlsAdminRole() public {
        address newOps = makeAddr("newOps");
        bytes32 adminRole = grai.ADMIN_ROLE();

        _exec(upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.grantRole, (adminRole, newOps)));
        assertTrue(grai.hasRole(adminRole, newOps));
    }

    function test_DeployerCannotGrantRoles() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdminRole)
        );
        vm.prank(DEPLOYER);
        grai.grantRole(adminRole, makeAddr("intruder"));
    }

    //////////////////// UPGRADES ////////////////////

    function test_UpgradeMultisigCanUpgradeGraiToken() public {
        GRAI newImpl = new GRAI();
        _exec(
            upgradeMultisig, upgradeOwner, address(grai), abi.encodeCall(grai.upgradeToAndCall, (address(newImpl), ""))
        );
        assertEq(_implementation(address(grai)), address(newImpl));
    }

    function test_UpgradeMultisigCanUpgradeGrinders() public {
        Grinders newImpl = new Grinders();
        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(grinders),
            abi.encodeCall(grinders.upgradeToAndCall, (address(newImpl), ""))
        );
        assertEq(_implementation(address(grinders)), address(newImpl));
    }

    function test_DeployerCannotUpgradeGraiToken() public {
        bytes32 defaultAdmin = grai.DEFAULT_ADMIN_ROLE();
        GRAI newImpl = new GRAI();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdmin)
        );
        vm.prank(DEPLOYER);
        grai.upgradeToAndCall(address(newImpl), "");
    }

    function test_DeployerCannotUpgradeGrinders() public {
        Grinders newImpl = new Grinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grinders.upgradeToAndCall(address(newImpl), "");
    }

    function test_OpsCannotUpgradeGraiToken() public {
        bytes32 defaultAdmin = grai.DEFAULT_ADMIN_ROLE();
        GRAI newImpl = new GRAI();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), defaultAdmin
            )
        );
        vm.prank(address(opsMultisig));
        grai.upgradeToAndCall(address(newImpl), "");
    }

    //////////////////// GRINDERS OWNABLE ////////////////////

    function test_UpgradeOwnerCanAllocateGate_RevertsUnknownCustodian() public {
        // allocate is onlyOwner; unknown custodian fails after ownership check.
        vm.expectRevert();
        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(grinders),
            abi.encodeCall(grinders.allocate, (makeAddr("unknown"), address(0), 1))
        );
    }

    function test_OpsCannotAllocate() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(opsMultisig)));
        vm.prank(address(opsMultisig));
        grinders.allocate(makeAddr("c"), address(0), 1);
    }

    function test_StrangerCannotTransferOwnership() public {
        Grinders fresh = _deployFreshGrinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        vm.prank(makeAddr("stranger"));
        fresh.transferOwnership(makeAddr("other"));
    }

    function test_NonOwnerCannotDriveOpsMultisig() public {
        vm.expectRevert("not owner");
        _exec(
            opsMultisig,
            makeAddr("stranger"),
            address(grai),
            abi.encodeCall(
                grai.setAssetConfig,
                (address(0), IGRAI.AssetConfig({asset: address(0), id: 0, paused: true, treasuryShare: 0}))
            )
        );
    }

    //////////////////// HELPERS ////////////////////

    function _newMultisig(address owner_) internal returns (MockMultisig m) {
        address[] memory owners_ = new address[](1);
        owners_[0] = owner_;
        m = new MockMultisig(owners_, 1);
    }

    function _setFeedAsAdmin(address asset, MockAggregator feed) internal {
        _exec(
            opsMultisig,
            opsOwner,
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
        address graiAddr = address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER))));
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
