// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Create2Factory, DeployPlanLib} from "../script/Deploy.s.sol";

contract DeployCreate2Test is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant TREASURY = address(0xBEEF);

    function test_PlanIsStableAcrossRuns() public {
        DeployPlanLib.Plan memory first = DeployPlanLib.build(ADMIN, TREASURY, "v1");
        DeployPlanLib.Plan memory second = DeployPlanLib.build(ADMIN, TREASURY, "v1");

        assertEq(first.oracleImpl, second.oracleImpl);
        assertEq(first.oracleProxy, second.oracleProxy);
        assertEq(first.graiImpl, second.graiImpl);
        assertEq(first.graiProxy, second.graiProxy);
    }

    function test_SaltTagChangesAddresses() public {
        DeployPlanLib.Plan memory v1 = DeployPlanLib.build(ADMIN, TREASURY, "v1");
        DeployPlanLib.Plan memory v2 = DeployPlanLib.build(ADMIN, TREASURY, "v2");

        assertTrue(v1.graiProxy != v2.graiProxy);
    }

    function test_Create2FactoryMatchesOpenZeppelin() public pure {
        bytes32 salt = keccak256("example");
        bytes32 hash = keccak256("example-bytecode");

        assertEq(
            Create2Factory.computeAddress(salt, hash),
            Create2.computeAddress(salt, hash, 0x4e59b44847b379578588920cA78FbF26c0B4956C)
        );
    }

    function test_VaultAddressesFollowGraiProxyNonce() public {
        DeployPlanLib.Plan memory plan = DeployPlanLib.build(ADMIN, TREASURY, "v1");

        assertEq(vm.computeCreateAddress(plan.graiProxy, 0), vm.computeCreateAddress(plan.graiProxy, 0));
        assertTrue(vm.computeCreateAddress(plan.graiProxy, 0) != vm.computeCreateAddress(plan.graiProxy, 1));
    }
}
