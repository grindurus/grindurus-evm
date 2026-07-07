// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {PriceOracleRouter} from "../src/PriceOracleRouter.sol";

/// @dev Nick's deterministic deployment proxy - same address on most EVM chains.
library Create2Factory {
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error FactoryNotDeployed();
    error DeploymentFailed(address expected);

    function isAvailable() internal view returns (bool) {
        return DEPLOYER.code.length > 0;
    }

    function computeAddress(bytes32 salt, bytes memory creationBytecode) internal pure returns (address addr) {
        return computeAddress(salt, keccak256(creationBytecode));
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) internal pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, DEPLOYER)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            addr := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function deploy(bytes32 salt, bytes memory creationBytecode) internal returns (address addr) {
        if (!isAvailable()) revert FactoryNotDeployed();
        addr = computeAddress(salt, creationBytecode);
        if (addr.code.length > 0) {
            return addr;
        }
        (bool success,) = DEPLOYER.call(abi.encodePacked(salt, creationBytecode));
        require(success, "create2 call failed");
        if (addr.code.length == 0) revert DeploymentFailed(addr);
    }
}

library DeployPlanLib {
    struct Plan {
        address admin;
        address treasury;
        bytes32 saltOracleImpl;
        bytes32 saltOracleProxy;
        bytes32 saltGraiImpl;
        bytes32 saltGraiProxy;
        bytes oracleImplCode;
        bytes oracleProxyCode;
        bytes graiImplCode;
        bytes graiProxyCode;
        address oracleImpl;
        address oracleProxy;
        address graiImpl;
        address graiProxy;
        address seniorVault;
        address juniorVault;
    }

    function salt(string memory label, string memory tag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("grindurus/", tag, "/", label));
    }

    function build(address admin, address treasury, string memory saltTag) internal pure returns (Plan memory plan) {
        plan.admin = admin;
        plan.treasury = treasury;
        plan.saltOracleImpl = salt("PriceOracleRouter/impl", saltTag);
        plan.saltGraiImpl = salt("GRAI/impl", saltTag);
        plan.saltOracleProxy = salt("PriceOracleRouter/proxy", saltTag);
        plan.saltGraiProxy = salt("GRAI/proxy", saltTag);

        plan.oracleImplCode = type(PriceOracleRouter).creationCode;
        plan.oracleImpl = Create2Factory.computeAddress(plan.saltOracleImpl, plan.oracleImplCode);

        plan.oracleProxyCode = proxyCreationCode(
            plan.oracleImpl, abi.encodeCall(PriceOracleRouter.initialize, (admin))
        );
        plan.oracleProxy = Create2Factory.computeAddress(plan.saltOracleProxy, plan.oracleProxyCode);

        plan.graiImplCode = type(GRAI).creationCode;
        plan.graiImpl = Create2Factory.computeAddress(plan.saltGraiImpl, plan.graiImplCode);

        plan.graiProxyCode = proxyCreationCode(
            plan.graiImpl, abi.encodeCall(GRAI.initialize, (admin, plan.oracleProxy, treasury))
        );
        plan.graiProxy = Create2Factory.computeAddress(plan.saltGraiProxy, plan.graiProxyCode);
    }

    function withVaults(Plan memory plan, address seniorVault, address juniorVault) internal pure returns (Plan memory) {
        plan.seniorVault = seniorVault;
        plan.juniorVault = juniorVault;
        return plan;
    }

    function proxyCreationCode(address implementation, bytes memory initData) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));
    }
}

/// @title Grindurus CREATE2 deploy
/// @notice Deploys GRAI + PriceOracleRouter at the same addresses on every chain that hosts
///         Nick's CREATE2 factory (`0x4e59...4956C`) with identical bytecode and init params.
///
/// Requirements for cross-chain address parity:
///   - Same `ADMIN` and `TREASURY` addresses on every chain (use a CREATE2 Safe or fixed EOA).
///     Omit `TREASURY` or set `TREASURY=0x000...000` to reuse `ADMIN`.
///   - Same `CREATE2_SALT_TAG` (default `v1`) and unchanged contract bytecode.
///   - Deploy in one run per chain; do not change optimizer settings between chains.
///
/// Usage - predict addresses (no broadcast, no key required):
///   ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol:Deploy --sig "predict()"
///
/// Usage - deploy:
///   ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $RPC_URL --broadcast
///
/// After deploy, register feeds and assets (see comments at the bottom of this file).
contract Deploy is Script {
    using DeployPlanLib for DeployPlanLib.Plan;

    function predict() external {
        DeployPlanLib.Plan memory plan = _plan();
        plan = plan.withVaults(
            vm.computeCreateAddress(plan.graiProxy, 0), vm.computeCreateAddress(plan.graiProxy, 1)
        );
        _logPlan(plan, Create2Factory.isAvailable());
    }

    function run() external returns (GRAI grai, PriceOracleRouter oracle) {
        DeployPlanLib.Plan memory plan = _plan();
        plan = plan.withVaults(
            vm.computeCreateAddress(plan.graiProxy, 0), vm.computeCreateAddress(plan.graiProxy, 1)
        );
        _logPlan(plan, Create2Factory.isAvailable());

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return (GRAI(payable(plan.graiProxy)), PriceOracleRouter(plan.oracleProxy));
        }

        require(Create2Factory.isAvailable(), "CREATE2 factory missing on this chain");

        vm.startBroadcast();

        address oracleImpl = Create2Factory.deploy(plan.saltOracleImpl, plan.oracleImplCode);
        require(oracleImpl == plan.oracleImpl, "oracle impl address mismatch");

        address oracleProxy = Create2Factory.deploy(plan.saltOracleProxy, plan.oracleProxyCode);
        require(oracleProxy == plan.oracleProxy, "oracle proxy address mismatch");

        address graiImpl = Create2Factory.deploy(plan.saltGraiImpl, plan.graiImplCode);
        require(graiImpl == plan.graiImpl, "grai impl address mismatch");

        address graiProxy = Create2Factory.deploy(plan.saltGraiProxy, plan.graiProxyCode);
        require(graiProxy == plan.graiProxy, "grai proxy address mismatch");

        vm.stopBroadcast();

        grai = GRAI(payable(graiProxy));
        oracle = PriceOracleRouter(oracleProxy);

        require(address(grai.seniorVault()) == plan.seniorVault, "senior vault address mismatch");
        require(address(grai.juniorVault()) == plan.juniorVault, "junior vault address mismatch");

        console2.log("Deploy complete.");
    }

    function _plan() internal returns (DeployPlanLib.Plan memory plan) {
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envOr("TREASURY", admin);
        if (treasury == address(0)) {
            treasury = admin;
        }
        string memory saltTag = vm.envOr("CREATE2_SALT_TAG", string("v1"));
        plan = DeployPlanLib.build(admin, treasury, saltTag);
    }

    function _dryRun() internal view returns (bool) {
        try vm.envBool("DRY_RUN") returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    function _logPlan(DeployPlanLib.Plan memory plan, bool factoryAvailable) internal pure {
        console2.log("CREATE2 factory available:", factoryAvailable);
        console2.log("ADMIN:", plan.admin);
        console2.log("TREASURY:", plan.treasury);
        console2.log("PriceOracleRouter impl:", plan.oracleImpl);
        console2.log("PriceOracleRouter proxy:", plan.oracleProxy);
        console2.log("GRAI impl:", plan.graiImpl);
        console2.log("GRAI proxy:", plan.graiProxy);
        console2.log("SeniorVault:", plan.seniorVault);
        console2.log("JuniorVault:", plan.juniorVault);
    }
}

// After deploy, register each asset feed on the oracle router, then add it to GRAI:
//   Chainlink (mainnet):
//     oracle.addChainlinkFeed(USDC, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
//     grai.addAsset(USDC, mintSplit, yieldSplit);
//   Pyth:
//     oracle.addPythFeed(WETH, PYTH, WETH_USD_ID);
//     grai.addAsset(WETH, mintSplit, yieldSplit);
//   Custom:
//     oracle.addCustomFeed(TOKEN, 8, oracleSigner);
//     grai.addAsset(TOKEN, mintSplit, yieldSplit);
