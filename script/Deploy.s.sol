// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";

/// @dev Nick's deterministic deployment proxy - same address on most EVM chains.
library Create2Factory {
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error FactoryNotDeployed();
    error DeploymentFailed(address expected);
    error AdminKeyRequired();

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
        bool deployTreasury;
        bytes32 saltGraiImpl;
        bytes32 saltGraiProxy;
        bytes32 saltTreasuryImpl;
        bytes32 saltTreasuryProxy;
        bytes graiImplCode;
        bytes graiProxyCode;
        bytes treasuryImplCode;
        bytes treasuryProxyCode;
        address graiImpl;
        address graiProxy;
        address treasuryImpl;
        address treasuryProxy;
        address seniorVault;
        address juniorVault;
    }

    function salt(string memory label, string memory tag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("grindurus/", tag, "/", label));
    }

    function build(address admin, address treasuryOverride, string memory saltTag) internal pure returns (Plan memory plan) {
        plan.admin = admin;
        plan.saltGraiImpl = salt("GRAI/impl", saltTag);
        plan.saltGraiProxy = salt("GRAI/proxy", saltTag);
        plan.saltTreasuryImpl = salt("Treasury/impl", saltTag);
        plan.saltTreasuryProxy = salt("Treasury/proxy", saltTag);

        plan.graiImplCode = type(GRAI).creationCode;
        plan.graiImpl = Create2Factory.computeAddress(plan.saltGraiImpl, plan.graiImplCode);

        // GRAI first: address does not depend on Treasury.
        plan.graiProxyCode = proxyCreationCode(plan.graiImpl, abi.encodeCall(GRAI.initialize, (admin)));
        plan.graiProxy = Create2Factory.computeAddress(plan.saltGraiProxy, plan.graiProxyCode);

        if (treasuryOverride == address(0)) {
            plan.deployTreasury = true;
            plan.treasuryImplCode = type(Treasury).creationCode;
            plan.treasuryImpl = Create2Factory.computeAddress(plan.saltTreasuryImpl, plan.treasuryImplCode);

            plan.treasuryProxyCode = proxyCreationCode(
                plan.treasuryImpl, abi.encodeCall(Treasury.initialize, (admin, plan.graiProxy))
            );
            plan.treasuryProxy = Create2Factory.computeAddress(plan.saltTreasuryProxy, plan.treasuryProxyCode);
            plan.treasury = plan.treasuryProxy;
            return plan;
        }

        plan.deployTreasury = false;
        plan.treasury = treasuryOverride;
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
/// @notice Deploys GRAI then Treasury at deterministic addresses on every chain that hosts
///         Nick's CREATE2 factory (`0x4e59...4956C`) with identical bytecode and init params.
///
/// Default order:
///   1. GRAI proxy — `initialize(admin)` (treasury unset)
///   2. Treasury proxy — `initialize(admin, grai)`
///   3. `grai.setTreasury(treasury)` — requires ADMIN key
///
/// Set `TREASURY=0x...` to skip Treasury CREATE2 and only wire GRAI via `setTreasury`.
///
/// Requirements for cross-chain address parity:
///   - Same `ADMIN` on every chain (CREATE2 Safe or fixed EOA).
///   - Same `CREATE2_SALT_TAG` (default `v1`) and unchanged contract bytecode.
///   - Deploy in one run per chain; do not change optimizer settings between chains.
///
/// Usage - predict addresses (no broadcast):
///   ADMIN=0x... forge script script/Deploy.s.sol:Deploy --sig "predict()"
///
/// Usage - deploy GRAI + Treasury:
///   ADMIN=0x... forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
///
/// Usage - deploy GRAI only (external treasury):
///   ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    using DeployPlanLib for DeployPlanLib.Plan;

    function predict() external view {
        DeployPlanLib.Plan memory plan = _plan();
        plan = plan.withVaults(
            vm.computeCreateAddress(plan.graiProxy, 0), vm.computeCreateAddress(plan.graiProxy, 1)
        );
        _logPlan(plan, Create2Factory.isAvailable());
    }

    function run() external returns (GRAI grai, Treasury treasury) {
        DeployPlanLib.Plan memory plan = _plan();
        plan = plan.withVaults(
            vm.computeCreateAddress(plan.graiProxy, 0), vm.computeCreateAddress(plan.graiProxy, 1)
        );
        _logPlan(plan, Create2Factory.isAvailable());

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return (GRAI(payable(plan.graiProxy)), Treasury(payable(plan.treasuryProxy)));
        }

        require(Create2Factory.isAvailable(), "CREATE2 factory missing on this chain");

        vm.startBroadcast();

        address graiImpl = Create2Factory.deploy(plan.saltGraiImpl, plan.graiImplCode);
        require(graiImpl == plan.graiImpl, "grai impl address mismatch");

        address graiProxy = Create2Factory.deploy(plan.saltGraiProxy, plan.graiProxyCode);
        require(graiProxy == plan.graiProxy, "grai proxy address mismatch");
        grai = GRAI(payable(graiProxy));

        if (plan.deployTreasury) {
            address treasuryImpl = Create2Factory.deploy(plan.saltTreasuryImpl, plan.treasuryImplCode);
            require(treasuryImpl == plan.treasuryImpl, "treasury impl address mismatch");

            address treasuryProxy = Create2Factory.deploy(plan.saltTreasuryProxy, plan.treasuryProxyCode);
            require(treasuryProxy == plan.treasuryProxy, "treasury proxy address mismatch");

            treasury = Treasury(payable(treasuryProxy));
        } else {
            treasury = Treasury(payable(address(0)));
        }

        vm.stopBroadcast();

        require(address(grai.seniorVault()) == plan.seniorVault, "senior vault address mismatch");
        require(address(grai.juniorVault()) == plan.juniorVault, "junior vault address mismatch");

        if (plan.deployTreasury) {
            require(treasury.grai() == address(grai), "treasury grai mismatch");
        }

        _wireTreasury(grai, plan.treasury);
        require(grai.treasury() == plan.treasury, "treasury address mismatch");

        console2.log("Deploy complete.");
    }

    function _wireTreasury(GRAI grai, address treasuryProxy) internal {
        uint256 adminKey = _adminPrivateKey();
        vm.startBroadcast(adminKey);
        grai.setTreasury(treasuryProxy);
        vm.stopBroadcast();
    }

    function _adminPrivateKey() internal view returns (uint256 key) {
        address admin = vm.envAddress("ADMIN");
        try vm.envUint("ADMIN_PRIVATE_KEY") returns (uint256 adminKey) {
            require(vm.addr(adminKey) == admin, "ADMIN_PRIVATE_KEY mismatch");
            return adminKey;
        } catch {
            try vm.envUint("PRIVATE_KEY") returns (uint256 deployerKey) {
                require(vm.addr(deployerKey) == admin, "PRIVATE_KEY must match ADMIN to wire treasury");
                return deployerKey;
            } catch {
                revert Create2Factory.AdminKeyRequired();
            }
        }
    }

    function _plan() internal view returns (DeployPlanLib.Plan memory plan) {
        address admin = vm.envAddress("ADMIN");
        address treasuryOverride = vm.envOr("TREASURY", address(0));
        string memory saltTag = vm.envOr("CREATE2_SALT_TAG", string("v1"));
        plan = DeployPlanLib.build(admin, treasuryOverride, saltTag);
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
        console2.log("Deploy Treasury:", plan.deployTreasury);
        console2.log("TREASURY:", plan.treasury);
        console2.log("GRAI impl:", plan.graiImpl);
        console2.log("GRAI proxy:", plan.graiProxy);
        if (plan.deployTreasury) {
            console2.log("Treasury impl:", plan.treasuryImpl);
            console2.log("Treasury proxy:", plan.treasuryProxy);
        }
        console2.log("SeniorVault:", plan.seniorVault);
        console2.log("JuniorVault:", plan.juniorVault);
    }
}

// After deploy, register each asset feed on GRAI, then add it to the asset registry:
//   Chainlink (mainnet):
//     grai.setFeed(USDC, chainlinkFeed(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6));
//     grai.addAsset(USDC, mintSplit, yieldSplit);
//   Pyth:
//     grai.setFeed(WETH, pythFeed(PYTH, WETH_USD_ID));
//     grai.addAsset(WETH, mintSplit, yieldSplit);
//   Custom:
//     grai.setFeed(TOKEN, customFeed(8, oracleSigner));
//     grai.addAsset(TOKEN, mintSplit, yieldSplit);
