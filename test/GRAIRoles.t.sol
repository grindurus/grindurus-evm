// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";

/// @dev GRAI: ADMIN/ORACLE/DEFAULT_ADMIN via AccessControl; Grinders: Ownable owner.
contract GRAIRolesTest is Test {
    address internal constant DEPLOYER = address(0xA11CE);
    address internal opsOwner = makeAddr("opsOwner");
    address internal upgradeOwner = makeAddr("upgradeOwner");

    MockMultisig internal opsMultisig;
    MockMultisig internal upgradeMultisig;
    Grinders internal grai;
    GRAI internal graiToken;

    function setUp() public {
        address[] memory opsOwners = new address[](1);
        opsOwners[0] = opsOwner;
        opsMultisig = new MockMultisig(opsOwners, 1);

        address[] memory upgradeOwners = new address[](1);
        upgradeOwners[0] = upgradeOwner;
        upgradeMultisig = new MockMultisig(upgradeOwners, 1);

        GRAI tokenImpl = new GRAI();
        graiToken = GRAI(
            payable(
                address(
                    new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER)))
                )
            )
        );

        Grinders impl = new Grinders();
        grai = Grinders(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Grinders.initialize, (DEPLOYER, address(graiToken)))
                    )
                )
            )
        );

        bytes32 adminRole = graiToken.ADMIN_ROLE();
        bytes32 defaultAdminRole = graiToken.DEFAULT_ADMIN_ROLE();

        vm.startPrank(DEPLOYER);
        graiToken.toggleGrinders(address(grai));
        graiToken.grantRole(adminRole, address(opsMultisig));
        graiToken.revokeRole(adminRole, DEPLOYER);
        graiToken.grantRole(defaultAdminRole, address(upgradeMultisig));
        graiToken.revokeRole(defaultAdminRole, DEPLOYER);
        grai.transferOwnership(address(upgradeMultisig));
        vm.stopPrank();
    }

    function test_OwnershipTransferIsImmediate() public {
        Grinders fresh = _deployFreshGrinders();

        assertEq(fresh.owner(), DEPLOYER);

        vm.prank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));

        assertEq(fresh.owner(), address(upgradeMultisig));
    }

    function test_RoleSplitMatchesReadme() public view {
        assertFalse(graiToken.hasRole(graiToken.ADMIN_ROLE(), DEPLOYER));
        assertTrue(graiToken.hasRole(graiToken.ADMIN_ROLE(), address(opsMultisig)));
        assertFalse(graiToken.hasRole(graiToken.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertTrue(graiToken.hasRole(graiToken.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));
        assertTrue(graiToken.hasRole(graiToken.ORACLE_ROLE(), DEPLOYER));
        assertEq(grai.owner(), address(upgradeMultisig));
    }

    function test_DeployerCannotCallAdminFunctions() public {
        bytes32 adminRole = graiToken.ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, adminRole)
        );
        vm.prank(DEPLOYER);
        graiToken.setPaused(address(0), true);
    }

    function test_OpsMultisigCanCallAdminFunctions() public {
        address asset = makeAddr("opsAsset");
        MockAggregator feed = new MockAggregator(8, 1e8);
        vm.prank(DEPLOYER);
        graiToken.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: 2,
                asset: asset,
                source: address(feed),
                data: bytes32(0),
                decimals: 0,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: 1 hours
            })
        );
        _exec(
            address(opsMultisig),
            opsOwner,
            address(graiToken),
            abi.encodeCall(graiToken.addAsset, (asset, 8_000))
        );
        (uint16 split,,) = graiToken.assets(asset);
        assertEq(split, 8_000);
    }

    function test_DeployerCannotUpgradeGrinders() public {
        Grinders newImpl = new Grinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        vm.prank(DEPLOYER);
        grai.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeMultisigCanUpgradeGrinders() public {
        Grinders newImpl = new Grinders();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(grai),
            abi.encodeCall(grai.upgradeToAndCall, (address(newImpl), ""))
        );

        assertEq(_implementation(address(grai)), address(newImpl));
    }

    function test_UpgradeMultisigCanUpgradeGraiToken() public {
        GRAI newImpl = new GRAI();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.upgradeToAndCall, (address(newImpl), ""))
        );

        assertEq(_implementation(address(graiToken)), address(newImpl));
    }

    function test_UpgradeMultisigControlsAdminRole() public {
        address newOps = makeAddr("newOps");
        bytes32 adminRole = graiToken.ADMIN_ROLE();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(graiToken),
            abi.encodeCall(graiToken.grantRole, (adminRole, newOps))
        );

        assertTrue(graiToken.hasRole(adminRole, newOps));
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

    function test_StrangerCannotTransferOwnership() public {
        Grinders fresh = _deployFreshGrinders();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        vm.prank(makeAddr("stranger"));
        fresh.transferOwnership(makeAddr("other"));
    }

    function test_NonOwnerCannotDriveOpsMultisig() public {
        vm.expectRevert("not owner");
        _exec(address(opsMultisig), makeAddr("stranger"), address(graiToken), abi.encodeCall(graiToken.setPaused, (address(0), true)));
    }

    function _deployFreshGrinders() internal returns (Grinders fresh) {
        GRAI tokenImpl = new GRAI();
        address graiTokenAddr = address(
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (DEPLOYER)))
        );
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

    function _exec(address multisig, address signer, address target, bytes memory data) internal {
        vm.prank(signer);
        MockMultisig(multisig).exec(target, data);
    }

    function _implementation(address proxy) private view returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        impl = address(uint160(uint256(vm.load(proxy, slot))));
    }
}
