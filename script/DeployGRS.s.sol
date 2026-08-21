// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {GRS} from "../src/GRS.sol";

/// @title Deploy GRS (LayerZero OFT) on an EVM chain
/// @notice Non-upgradeable OFT. Pick network via `CHAIN` (default: sepolia) or `block.chainid`.
///
/// Env:
///   PRIVATE_KEY       — deployer / current GRS owner
///   CHAIN             — ethereum | arbitrum | base | sepolia | base-sepolia | arbitrum-sepolia
///                       (default: sepolia). Must match `--rpc-url` chain id.
///   DELEGATE          — OFT owner / endpoint delegate (default: deployer)
///   HOME              — default true on sepolia; default false elsewhere (override with HOME=)
///   OWNER_MULTISIG    — optional Ownable2Step handoff (`acceptOwnership` required)
///   LZ_ENDPOINT       — optional Endpoint V2 override
///   DRY_RUN=1         — log only
///
/// Wire Solana peer (`setSolanaPeer`):
///   GRS               — deployed GRS address
///   SOLANA_PEER       — Solana OFT store as `bytes32` hex (32-byte pubkey)
///   SOLANA_EID        — optional (default: Solana Devnet 40168 on testnets, Solana 30168 on mainnets)
///
/// Deploy (Sepolia home):
///   PRIVATE_KEY=0x... 
///     forge script script/DeployGRS.s.sol:DeployGRS --rpc-url sepolia --broadcast --verify
///
/// Deploy (Arbitrum spoke):
///   PRIVATE_KEY=0x... CHAIN=arbitrum HOME=false 
///     forge script script/DeployGRS.s.sol:DeployGRS --rpc-url arbitrum --broadcast --verify
///
/// Set Solana peer:
///   PRIVATE_KEY=0x... GRS=0x... SOLANA_PEER=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "setSolanaPeer()" --rpc-url sepolia --broadcast
contract DeployGRS is Script {
    /// @dev LayerZero V2 EndpointV2 — shared across most EVM mainnets.
    ///      https://docs.layerzero.network/v2/deployments/deployed-contracts
    address internal constant ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @dev LayerZero V2 EndpointV2 — shared across most EVM testnets (Sepolia, Base Sepolia, …).
    ///      https://docs.layerzero.network/v2/deployments/chains/sepolia
    address internal constant ENDPOINT_SEPOLIA = 0x6EDCE65403992e310A62460808c4b910D972f10f;

    struct Network {
        string name;
        uint256 chainId;
        uint32 eid;
        address endpoint;
        bool testnet;
        bool solana;
    }

    function run() external returns (GRS grs) {
        Network memory net = _homeNetwork();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address delegate = vm.envOr("DELEGATE", vm.addr(pk));
        bool home = vm.envOr("HOME", _defaultHome(net));
        address endpoint = vm.envOr("LZ_ENDPOINT", net.endpoint);

        console2.log("chain     ", net.name);
        console2.log("chainId   ", net.chainId);
        console2.log("lzEid     ", uint256(net.eid));
        console2.log("lzEndpoint", endpoint);
        console2.log("delegate  ", delegate);
        console2.log("home      ", home);

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return GRS(address(0));
        }

        require(block.chainid == net.chainId, "CHAIN / rpc mismatch");
        require(endpoint != address(0), "LZ_ENDPOINT required");

        vm.startBroadcast(pk);
        grs = new GRS(endpoint, delegate, home);

        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (ownerMultisig != address(0)) {
            grs.transferOwnership(ownerMultisig);
            console2.log("Pending owner (call acceptOwnership):", ownerMultisig);
        }
        vm.stopBroadcast();

        console2.log("GRS       ", address(grs));
        console2.log("home      ", grs.home());
        console2.log("supply    ", grs.totalSupply());
        console2.log("owner     ", grs.owner());
    }

    /// @notice Point GRS at the Solana OFT store (`SOLANA_PEER` env, bytes32 hex).
    function setSolanaPeer() external {
        Network memory home = _homeNetwork();
        Network memory solana = _defaultSolanaPeer(home);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address grsAddr = vm.envAddress("GRS");
        bytes32 peer = vm.envBytes32("SOLANA_PEER");
        uint32 eid = uint32(vm.envOr("SOLANA_EID", uint256(solana.eid)));

        require(grsAddr != address(0), "GRS required");
        require(peer != bytes32(0), "SOLANA_PEER required");

        GRS grs = GRS(grsAddr);
        console2.log("GRS         ", grsAddr);
        console2.log("home        ", home.name);
        console2.log("solanaPeerN ", solana.name);
        console2.log("solanaEid   ", uint256(eid));
        console2.log("solanaPeer  ");
        console2.logBytes32(peer);
        console2.log("owner       ", grs.owner());

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return;
        }

        require(block.chainid == home.chainId, "CHAIN / rpc mismatch");
        require(grs.owner() == vm.addr(pk), "PRIVATE_KEY is not GRS owner");

        vm.startBroadcast(pk);
        grs.setPeer(eid, peer);
        vm.stopBroadcast();

        console2.log("setPeer ok");
        console2.logBytes32(grs.peers(eid));
    }

    function _homeNetwork() internal view returns (Network memory) {
        try vm.envString("CHAIN") returns (string memory name) {
            if (bytes(name).length != 0) return _byName(name);
        } catch {}
        return _byChainId(block.chainid);
    }

    function _defaultHome(Network memory net) internal pure returns (bool) {
        // Sepolia is the canonical testnet home (see TODO); others default to spoke.
        return keccak256(bytes(net.name)) == keccak256("Sepolia");
    }

    function _defaultSolanaPeer(Network memory home) internal pure returns (Network memory) {
        require(!home.solana, "home is Solana");
        return home.testnet ? _byName("solana-devnet") : _byName("solana");
    }

    function _byName(string memory name) internal pure returns (Network memory) {
        bytes32 k = keccak256(bytes(name));
        if (k == keccak256("ethereum")) {
            return Network("Ethereum", 1, 30_101, ENDPOINT_MAINNET, false, false);
        }
        if (k == keccak256("arbitrum")) {
            return Network("Arbitrum", 42_161, 30_110, ENDPOINT_MAINNET, false, false);
        }
        if (k == keccak256("base")) {
            return Network("Base", 8453, 30_184, ENDPOINT_MAINNET, false, false);
        }
        if (k == keccak256("sepolia")) {
            return Network("Sepolia", 11_155_111, 40_161, ENDPOINT_SEPOLIA, true, false);
        }
        if (k == keccak256("base-sepolia")) {
            return Network("Base Sepolia", 84_532, 40_245, ENDPOINT_SEPOLIA, true, false);
        }
        if (k == keccak256("arbitrum-sepolia")) {
            return Network("Arbitrum Sepolia", 421_614, 40_231, ENDPOINT_SEPOLIA, true, false);
        }
        if (k == keccak256("solana")) {
            return Network("Solana", 0, 30_168, address(0), false, true);
        }
        if (k == keccak256("solana-devnet")) {
            return Network("Solana Devnet", 0, 40_168, address(0), true, true);
        }
        revert("unknown CHAIN");
    }

    function _byChainId(uint256 chainId) internal pure returns (Network memory) {
        if (chainId == 1) return _byName("ethereum");
        if (chainId == 42_161) return _byName("arbitrum");
        if (chainId == 8453) return _byName("base");
        if (chainId == 11_155_111) return _byName("sepolia");
        if (chainId == 84_532) return _byName("base-sepolia");
        if (chainId == 421_614) return _byName("arbitrum-sepolia");
        revert("unknown chainId (set CHAIN=)");
    }

    function _dryRun() internal view returns (bool) {
        try vm.envBool("DRY_RUN") returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }
}
