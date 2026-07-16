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
///      - opsMultisig:        ADMIN_ROLE
///      - oracleMultisig:     ORACLE_ROLE
///      - upgradeMultisig:    DEFAULT_ADMIN_ROLE + Grinders Ownable
///      - Grinders contract:  GRINDERS_ROLE (via toggleGrinders)
contract GRAIRolesTest is Test {
    address internal constant DEPLOYER = address(0xA11CE);

    address internal opsOwner = makeAddr("opsOwner");
    address internal oracleOwner = makeAddr("oracleOwner");
    address internal upgradeOwner = makeAddr("upgradeOwner");

    MockMultisig internal opsMultisig;
    MockMultisig internal oracleMultisig;
    MockMultisig internal upgradeMultisig;

    Grinders internal grinders;
    GRAI internal graiToken;

    function setUp() public {
        opsMultisig = _newMultisig(opsOwner);
        oracleMultisig = _newMultisig(oracleOwner);
        upgradeMultisig = _newMultisig(upgradeOwner);

        GRAI tokenImpl = new GRAI();
        graiToken = GRAI(
            payable(
                address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER))))
            )
        );

        Grinders impl = new Grinders();
        grinders = Grinders(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, address(graiToken)))
                    )
                )
            )
        );

        bytes32 adminRole = graiToken.ADMIN_ROLE();
        bytes32 oracleRole = graiToken.ORACLE_ROLE();
        bytes32 defaultAdminRole = graiToken.DEFAULT_ADMIN_ROLE();

        vm.startPrank(DEPLOYER);
        graiToken.toggleGrinders(address(grinders));
        graiToken.grantRole(adminRole, address(opsMultisig));
        graiToken.revokeRole(adminRole, DEPLOYER);
        graiToken.grantRole(oracleRole, address(oracleMultisig));
        graiToken.revokeRole(oracleRole, DEPLOYER);
        graiToken.grantRole(defaultAdminRole, address(upgradeMultisig));
        graiToken.revokeRole(defaultAdminRole, DEPLOYER);
        grinders.transferOwnership(address(upgradeMultisig));
        vm.stopPrank();
    }

    //////////////////// ROLE SPLIT ////////////////////

    function test_RoleSplit_AfterHandoff() public view {
        assertFalse(graiToken.hasRole(graiToken.ADMIN_ROLE(), DEPLOYER));
        assertTrue(graiToken.hasRole(graiToken.ADMIN_ROLE(), address(opsMultisig)));

        assertFalse(graiToken.hasRole(graiToken.ORACLE_ROLE(), DEPLOYER));
        assertTrue(graiToken.hasRole(graiToken.ORACLE_ROLE(), address(oracleMultisig)));

        assertFalse(graiToken.hasRole(graiToken.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertTrue(graiToken.hasRole(graiToken.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));

        assertTrue(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(grinders)));
        assertFalse(graiToken.hasRole(graiToken.GRINDERS_ROLE(), DEPLOYER));
        assertFalse(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(opsMultisig)));

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

    function test_OpsCanAddAsset_AfterOracleSetsFeed() public {
        address asset = makeAddr("opsAsset");
        _setFeedAsOracle(asset, new MockAggregator(8, 1e8));

        _exec(opsMultisig, opsOwner, address(graiToken), abi.encodeCall(graiToken.addAsset, (asset, 8_000)));

        (uint16 split,,) = graiToken.assets(asset);
        assertEq(split, 8_000);
    }

    function test_OpsCanSetAssetConfig() public {
        address asset = makeAddr("cfgAsset");
        _setFeedAsOracle(asset, new MockAggregator(8, 1e8));
        _exec(opsMultisig, opsOwner, address(graiToken), abi.encodeCall(graiToken.addAsset, (asset, 8_000)));

        _exec(
            opsMultisig,
            opsOwner,
            address(graiToken),
            abi.encodeCall(graiToken.setAssetConfig, (asset, uint16(5_000), true))
        );

        (uint16 split, bool paused,) = graiToken.assets(asset);
        assertEq(split, 5_000);
        assertTrue(paused);
    }

    function test_DeployerCannotCallAdminFunctions() public {
        bytes32 adminRole = graiToken.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, adminRole)
        );
        vm.prank(DEPLOYER);
        graiToken.setAssetConfig(address(0), 0, true);
    }

    function test_OracleCannotCallAdminFunctions() public {
        bytes32 adminRole = graiToken.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(oracleMultisig), adminRole
            )
        );
        vm.prank(address(oracleMultisig));
        graiToken.addAsset(address(0), 8_000);
    }

    function test_UpgradeCannotCallAdminFunctions() public {
        bytes32 adminRole = graiToken.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(upgradeMultisig), adminRole
            )
        );
        vm.prank(address(upgradeMultisig));
        graiToken.setAssetConfig(address(0), 0, true);
    }

    //////////////////// ORACLE_ROLE ////////////////////

    function test_OracleCanSetFeed() public {
        address asset = makeAddr("oracleAsset");
        MockAggregator feed = new MockAggregator(8, 2e8);
        _setFeedAsOracle(asset, feed);
        (,, address source,,,,,) = graiToken.feeds(asset);
        assertEq(source, address(feed));
    }

    function test_OpsCannotSetFeed() public {
        bytes32 oracleRole = graiToken.ORACLE_ROLE();
        address asset = makeAddr("noOracle");
        MockAggregator feed = new MockAggregator(8, 1e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), oracleRole
            )
        );
        vm.prank(address(opsMultisig));
        graiToken.setFeed(asset, _chainlinkFeed(asset, address(feed)));
    }

    function test_DeployerCannotSetFeed() public {
        bytes32 oracleRole = graiToken.ORACLE_ROLE();
        address asset = makeAddr("noOracle2");
        MockAggregator feed = new MockAggregator(8, 1e8);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, oracleRole)
        );
        vm.prank(DEPLOYER);
        graiToken.setFeed(asset, _chainlinkFeed(asset, address(feed)));
    }

    //////////////////// DEFAULT_ADMIN_ROLE ////////////////////

    function test_UpgradeCanSetConfig() public {
        IGRAI.ProtocolConfig memory cfg = IGRAI.ProtocolConfig({
            askAprBps: 200,
            bidAprBps: 200,
            unlockFeeBps: 300,
            unlockAprBps: 100,
            liquidationQuorumBps: 5_000
        });
        _exec(upgradeMultisig, upgradeOwner, address(graiToken), abi.encodeCall(graiToken.setConfig, (cfg)));

        (uint16 askAprBps, uint16 bidAprBps, uint16 unlockFeeBps, uint16 unlockAprBps, uint16 quorum) =
            graiToken.config();
        assertEq(askAprBps, 200);
        assertEq(bidAprBps, 200);
        assertEq(unlockFeeBps, 300);
        assertEq(unlockAprBps, 100);
        assertEq(quorum, 5_000);
    }

    function test_UpgradeCanSetTreasuryAndVaults() public {
        address treasury = makeAddr("treasury");
        address junior = makeAddr("junior");
        address senior = makeAddr("senior");

        _exec(upgradeMultisig, upgradeOwner, address(graiToken), abi.encodeCall(graiToken.setTreasury, (treasury)));
        _exec(upgradeMultisig, upgradeOwner, address(graiToken), abi.encodeCall(graiToken.setJuniorVault, (junior)));
        _exec(upgradeMultisig, upgradeOwner, address(graiToken), abi.encodeCall(graiToken.setSeniorVault, (senior)));

        assertEq(graiToken.treasury(), treasury);
        assertEq(graiToken.juniorVault(), junior);
        assertEq(graiToken.seniorVault(), senior);
    }

    function test_UpgradeCanToggleGrinders() public {
        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.toggleGrinders, (address(grinders)))
        );
        assertFalse(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(grinders)));

        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.toggleGrinders, (address(grinders)))
        );
        assertTrue(graiToken.hasRole(graiToken.GRINDERS_ROLE(), address(grinders)));
    }

    function test_OpsCannotCallDefaultAdminFunctions() public {
        bytes32 defaultAdmin = graiToken.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), defaultAdmin
            )
        );
        vm.prank(address(opsMultisig));
        graiToken.setTreasury(makeAddr("x"));
    }

    function test_UpgradeMultisigControlsAdminRole() public {
        address newOps = makeAddr("newOps");
        bytes32 adminRole = graiToken.ADMIN_ROLE();

        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.grantRole, (adminRole, newOps))
        );
        assertTrue(graiToken.hasRole(adminRole, newOps));
    }

    function test_UpgradeMultisigControlsOracleRole() public {
        address newOracle = makeAddr("newOracle");
        bytes32 oracleRole = graiToken.ORACLE_ROLE();

        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.grantRole, (oracleRole, newOracle))
        );
        assertTrue(graiToken.hasRole(oracleRole, newOracle));
    }

    function test_DeployerCannotGrantRoles() public {
        bytes32 adminRole = graiToken.ADMIN_ROLE();
        bytes32 defaultAdminRole = graiToken.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdminRole
            )
        );
        vm.prank(DEPLOYER);
        graiToken.grantRole(adminRole, makeAddr("intruder"));
    }

    //////////////////// UPGRADES ////////////////////

    function test_UpgradeMultisigCanUpgradeGraiToken() public {
        GRAI newImpl = new GRAI();
        _exec(
            upgradeMultisig,
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.upgradeToAndCall, (address(newImpl), ""))
        );
        assertEq(_implementation(address(graiToken)), address(newImpl));
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
        bytes32 defaultAdmin = graiToken.DEFAULT_ADMIN_ROLE();
        GRAI newImpl = new GRAI();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdmin)
        );
        vm.prank(DEPLOYER);
        graiToken.upgradeToAndCall(address(newImpl), "");
    }

    function test_DeployerCannotUpgradeGrinders() public {
        Grinders newImpl = new Grinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grinders.upgradeToAndCall(address(newImpl), "");
    }

    function test_OpsCannotUpgradeGraiToken() public {
        bytes32 defaultAdmin = graiToken.DEFAULT_ADMIN_ROLE();
        GRAI newImpl = new GRAI();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), defaultAdmin
            )
        );
        vm.prank(address(opsMultisig));
        graiToken.upgradeToAndCall(address(newImpl), "");
    }

    //////////////////// GRINDERS_ROLE ////////////////////

    function test_GrindersCanPut() public {
        _setFeedAsOracle(address(0), new MockAggregator(8, 1000e8));
        _exec(opsMultisig, opsOwner, address(graiToken), abi.encodeCall(graiToken.addAsset, (address(0), 8_000)));

        vm.deal(address(grinders), 1 ether);
        vm.prank(address(grinders));
        graiToken.put{value: 0.1 ether}(address(0), 0.1 ether);

        assertEq(graiToken.balance(address(0)), 0.1 ether);
    }

    function test_OpsCannotPut() public {
        bytes32 grindersRole = graiToken.GRINDERS_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(opsMultisig), grindersRole
            )
        );
        vm.prank(address(opsMultisig));
        graiToken.put{value: 0}(address(0), 1);
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
            address(graiToken),
            abi.encodeCall(graiToken.setAssetConfig, (address(0), uint16(0), true))
        );
    }

    //////////////////// HELPERS ////////////////////

    function _newMultisig(address owner_) internal returns (MockMultisig m) {
        address[] memory owners_ = new address[](1);
        owners_[0] = owner_;
        m = new MockMultisig(owners_, 1);
    }

    function _setFeedAsOracle(address asset, MockAggregator feed) internal {
        _exec(
            oracleMultisig,
            oracleOwner,
            address(graiToken),
            abi.encodeCall(graiToken.setFeed, (asset, _chainlinkFeed(asset, address(feed))))
        );
    }

    function _chainlinkFeed(address asset, address aggregator)
        internal
        pure
        returns (IPriceOracleRouter.Feed memory)
    {
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
        address graiTokenAddr =
            address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER))));
        Grinders impl = new Grinders();
        fresh = Grinders(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, graiTokenAddr))
                    )
                )
            )
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
