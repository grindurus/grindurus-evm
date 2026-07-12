// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {GRAI} from "../src/GRAI.sol";
import {SeniorToken} from "../src/SeniorToken.sol";
import {JuniorToken} from "../src/JuniorToken.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";

/// @dev ADMIN via grant/revoke; DEFAULT_ADMIN via two-step `transferOwnership`.
contract GRAIRolesTest is Test {
    address internal constant DEPLOYER = address(0xA11CE);
    address internal opsOwner = makeAddr("opsOwner");
    address internal upgradeOwner = makeAddr("upgradeOwner");

    MockMultisig internal opsMultisig;
    MockMultisig internal upgradeMultisig;
    GRAI internal grai;

    function setUp() public {
        address[] memory opsOwners = new address[](1);
        opsOwners[0] = opsOwner;
        opsMultisig = new MockMultisig(opsOwners, 1);

        address[] memory upgradeOwners = new address[](1);
        upgradeOwners[0] = upgradeOwner;
        upgradeMultisig = new MockMultisig(upgradeOwners, 1);

        GRAI impl = new GRAI();
        grai = GRAI(
            payable(
                address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (DEPLOYER)))
                )
            )
        );

        bytes32 adminRole = grai.ADMIN_ROLE();

        vm.startPrank(DEPLOYER);
        grai.grantRole(adminRole, address(opsMultisig));
        grai.revokeRole(adminRole, DEPLOYER);
        grai.transferOwnership(address(upgradeMultisig));
        vm.stopPrank();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(grai),
            abi.encodeCall(grai.transferOwnership, (address(upgradeMultisig)))
        );
    }

    function test_OwnershipRequiresAccept() public {
        GRAI fresh = _deployFreshGrai();

        vm.prank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));

        assertFalse(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));
        assertEq(fresh.pendingOwner(), address(upgradeMultisig));

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(fresh),
            abi.encodeCall(fresh.transferOwnership, (address(upgradeMultisig)))
        );

        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));
        assertEq(fresh.pendingOwner(), address(0));
    }

    function test_OwnershipTransferIsExclusiveOnAccept() public {
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();
        GRAI fresh = _deployFreshGrai();

        assertTrue(fresh.hasRole(defaultAdminRole, DEPLOYER));

        vm.prank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(fresh),
            abi.encodeCall(fresh.transferOwnership, (address(upgradeMultisig)))
        );

        assertTrue(fresh.hasRole(defaultAdminRole, address(upgradeMultisig)));
        assertFalse(fresh.hasRole(defaultAdminRole, DEPLOYER));
    }

    function test_RoleSplitMatchesReadme() public view {
        assertFalse(grai.hasRole(grai.ADMIN_ROLE(), DEPLOYER));
        assertTrue(grai.hasRole(grai.ADMIN_ROLE(), address(opsMultisig)));
        assertFalse(grai.hasRole(grai.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertTrue(grai.hasRole(grai.DEFAULT_ADMIN_ROLE(), address(upgradeMultisig)));
        assertTrue(grai.hasRole(grai.ORACLE_ROLE(), DEPLOYER));
    }

    function test_DeployerCannotCallAdminFunctions() public {
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdminRole)
        );
        vm.prank(DEPLOYER);
        grai.setJuniorToken(makeAddr("juniorToken"));
    }

    function test_OpsMultisigCanCallAdminFunctions() public {
        address newJuniorToken = address(
            new ERC1967Proxy(
                address(new JuniorToken()),
                abi.encodeCall(JuniorToken.initialize, (address(grai)))
            )
        );
        SeniorToken tokenImpl = new SeniorToken();
        SeniorToken newSeniorToken = SeniorToken(
            payable(
                address(
                    new ERC1967Proxy(address(tokenImpl), abi.encodeCall(SeniorToken.initialize, (address(grai))))
                )
            )
        );

        _exec(address(upgradeMultisig), upgradeOwner, address(grai), abi.encodeCall(grai.setJuniorToken, (newJuniorToken)));
        _exec(address(upgradeMultisig), upgradeOwner, address(grai), abi.encodeCall(grai.setSeniorToken, (address(newSeniorToken))));

        assertEq(address(grai.juniorToken()), newJuniorToken);
        assertEq(address(grai.seniorToken()), address(newSeniorToken));
    }

    function test_DeployerCannotUpgrade() public {
        GRAI newImpl = new GRAI();
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdminRole
            )
        );
        vm.prank(DEPLOYER);
        grai.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeMultisigCanUpgrade() public {
        GRAI newImpl = new GRAI();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(grai),
            abi.encodeCall(grai.upgradeToAndCall, (address(newImpl), ""))
        );

        assertEq(_implementation(address(grai)), address(newImpl));
    }

    function test_UpgradeMultisigControlsAdminRole() public {
        address newOps = makeAddr("newOps");
        bytes32 adminRole = grai.ADMIN_ROLE();

        _exec(
            address(upgradeMultisig),
            upgradeOwner,
            address(grai),
            abi.encodeCall(grai.grantRole, (adminRole, newOps))
        );

        assertTrue(grai.hasRole(adminRole, newOps));
    }

    function test_DeployerCannotGrantRoles() public {
        bytes32 adminRole = grai.ADMIN_ROLE();
        bytes32 defaultAdminRole = grai.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, defaultAdminRole
            )
        );
        vm.prank(DEPLOYER);
        grai.grantRole(adminRole, makeAddr("intruder"));
    }

    function test_StrangerCannotAcceptOwnership() public {
        GRAI fresh = _deployFreshGrai();

        vm.prank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));

        vm.expectRevert(IGRAI.NotCurrentOwner.selector);
        vm.prank(makeAddr("stranger"));
        fresh.transferOwnership(address(upgradeMultisig));
    }

    function test_PendingOwnershipBlocksSecondOffer() public {
        GRAI fresh = _deployFreshGrai();

        vm.startPrank(DEPLOYER);
        fresh.transferOwnership(address(upgradeMultisig));
        vm.expectRevert(IGRAI.OwnershipOfferPending.selector);
        fresh.transferOwnership(makeAddr("other"));
        vm.stopPrank();
    }

    function test_NonOwnerCannotDriveOpsMultisig() public {
        vm.expectRevert("not owner");
        _exec(address(opsMultisig), makeAddr("stranger"), address(grai), abi.encodeCall(grai.setJuniorToken, (makeAddr("jv"))));
    }

    function _deployFreshGrai() internal returns (GRAI fresh) {
        GRAI impl = new GRAI();
        fresh = GRAI(
            payable(
                address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (DEPLOYER)))
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
