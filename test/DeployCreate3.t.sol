// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Create3Factory} from "../script/Create3Factory.sol";
import {DeployPlanLib} from "../script/Deploy.s.sol";

contract DeployCreate3Test is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function test_PlanIsStableAcrossRuns() public pure {
        DeployPlanLib.Plan memory first = DeployPlanLib.build(ADMIN, WETH, "v1");
        DeployPlanLib.Plan memory second = DeployPlanLib.build(ADMIN, WETH, "v1");

        assertEq(first.graiImpl, second.graiImpl);
        assertEq(first.graiProxy, second.graiProxy);
        assertEq(first.grindersProxy, second.grindersProxy);
    }

    function test_AddressIndependentOfAdminAndWeth() public pure {
        DeployPlanLib.Plan memory a = DeployPlanLib.build(ADMIN, WETH, "v1");
        DeployPlanLib.Plan memory b = DeployPlanLib.build(address(0xB0B), address(0xBEEF), "v1");

        assertEq(a.graiImpl, b.graiImpl);
        assertEq(a.graiProxy, b.graiProxy);
        assertEq(a.grindersImpl, b.grindersImpl);
        assertEq(a.grindersProxy, b.grindersProxy);
    }

    function test_SaltTagChangesAddresses() public pure {
        DeployPlanLib.Plan memory v1 = DeployPlanLib.build(ADMIN, WETH, "v1");
        DeployPlanLib.Plan memory v2 = DeployPlanLib.build(ADMIN, WETH, "v2");

        assertTrue(v1.graiProxy != v2.graiProxy);
        assertTrue(v1.grindersProxy != v2.grindersProxy);
    }

    function test_GraiProxyIsNonZero() public pure {
        DeployPlanLib.Plan memory plan = DeployPlanLib.build(ADMIN, WETH, "v1");

        assertTrue(plan.graiProxy != address(0));
        assertTrue(plan.graiImpl != address(0));
    }

    function test_ProxyBytecodeHashMatchesConstant() public pure {
        assertEq(Create3Factory.PROXY_BYTECODE_HASH, keccak256(Create3Factory.PROXY_BYTECODE));
    }

    function test_Create3ProxyMatchesCreate2OfFixedBytecode() public pure {
        bytes32 salt = keccak256("example");
        address expectedProxy = Create2.computeAddress(
            salt, Create3Factory.PROXY_BYTECODE_HASH, Create3Factory.DEPLOYER
        );
        assertEq(Create3Factory.computeProxyAddress(salt), expectedProxy);
    }
}
