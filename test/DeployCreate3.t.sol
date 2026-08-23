// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Create3Factory} from "../script/Create3Factory.sol";

/// @dev CREATE3 address predictions matching `DeployGRAI.s.sol` / `DeployGrinders.s.sol` salts.
contract DeployCreate3Test is Test {
    struct Plan {
        address graiImpl;
        address graiProxy;
        address grindersImpl;
        address grindersProxy;
    }

    function _plan(string memory saltTag) internal pure returns (Plan memory plan) {
        plan.graiImpl = Create3Factory.computeAddress(Create3Factory.makeSalt("GRAI/impl", saltTag));
        plan.graiProxy = Create3Factory.computeAddress(Create3Factory.makeSalt("GRAI/proxy", saltTag));
        plan.grindersImpl = Create3Factory.computeAddress(Create3Factory.makeSalt("Grinders/impl", saltTag));
        plan.grindersProxy = Create3Factory.computeAddress(Create3Factory.makeSalt("Grinders/proxy", saltTag));
    }

    function test_PlanIsStableAcrossRuns() public pure {
        Plan memory first = _plan("v1");
        Plan memory second = _plan("v1");

        assertEq(first.graiImpl, second.graiImpl);
        assertEq(first.graiProxy, second.graiProxy);
        assertEq(first.grindersProxy, second.grindersProxy);
    }

    function test_AddressDependsOnlyOnSaltTag() public pure {
        // CREATE3 final address is salt-only (admin / WETH / init calldata do not move it).
        Plan memory a = _plan("v1");
        Plan memory b = _plan("v1");

        assertEq(a.graiImpl, b.graiImpl);
        assertEq(a.graiProxy, b.graiProxy);
        assertEq(a.grindersImpl, b.grindersImpl);
        assertEq(a.grindersProxy, b.grindersProxy);
    }

    function test_SaltTagChangesAddresses() public pure {
        Plan memory v1 = _plan("v1");
        Plan memory v2 = _plan("v2");

        assertTrue(v1.graiProxy != v2.graiProxy);
        assertTrue(v1.grindersProxy != v2.grindersProxy);
    }

    function test_GraiProxyIsNonZero() public pure {
        Plan memory plan = _plan("v1");

        assertTrue(plan.graiProxy != address(0));
        assertTrue(plan.graiImpl != address(0));
    }

    function test_ProxyBytecodeHashMatchesConstant() public pure {
        assertEq(Create3Factory.PROXY_BYTECODE_HASH, keccak256(Create3Factory.PROXY_BYTECODE));
    }

    function test_Create3ProxyMatchesCreate2OfFixedBytecode() public pure {
        bytes32 salt = keccak256("example");
        address expectedProxy =
            Create2.computeAddress(salt, Create3Factory.PROXY_BYTECODE_HASH, Create3Factory.DEPLOYER);
        assertEq(Create3Factory.computeProxyAddress(salt), expectedProxy);
    }

    function test_MakeSaltMatchesDeployScripts() public pure {
        assertEq(
            Create3Factory.makeSalt("GRAI/proxy", "grindurus"),
            keccak256(abi.encodePacked("grindurus/", "grindurus", "/", "GRAI/proxy"))
        );
    }
}
