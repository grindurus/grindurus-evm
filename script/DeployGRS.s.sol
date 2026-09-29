// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {GRS} from "../src/GRS.sol";
import {IGRS} from "../src/interfaces/IGRS.sol";

/// @title Deploy GRS (LayerZero OFT) on an EVM chain
/// @notice Non-upgradeable OFT. Pick network via `CHAIN` (default: sepolia) or `block.chainid`.
///
/// Env:
///   PRIVATE_KEY       — deployer / current GRS owner
///   CHAIN             — ethereum | arbitrum | base | sepolia | base-sepolia | arbitrum-sepolia
///                       (default: sepolia). Must match `--rpc-url` chain id.
///   DELEGATE          — OFT owner / endpoint delegate (default: deployer)
///   HOME_ADDRESS      — bytes32 of canonical home GRS (`0x0…0` = this deploy is home).
///                       Default: `0` on Sepolia, required non-zero elsewhere (or set HOME=true for
///                       an alternate home chain).
///   HOME_EID          — LZ eid of home (required for spoke; constructor `setPeer`). Default: Sepolia
///                       40161 on testnets, Ethereum 30101 on mainnets.
///   HOME              — if true, force `HOME_ADDRESS=0` (this chain is home). Default: Sepolia only.
///   OWNER_MULTISIG    — optional Ownable2Step handoff (`acceptOwnership` required)
///   LZ_ENDPOINT       — optional Endpoint V2 override
///   DRY_RUN=1         — log only
///
/// Wire Solana peer (`setSolanaPeer`):
///   GRS               — deployed GRS address
///   SOLANA_PEER       — Solana OFT store as `bytes32` hex (32-byte pubkey)
///   SOLANA_EID        — optional (default: Solana Devnet 40168 on testnets, Solana 30168 on mainnets)
///
/// Note: GRS.setPeer also installs default enforcedOptions (Solana: CU + ATA rent lamports).
///       Owner may still call setEnforcedOptions to tune.

/// Deploy (Sepolia home):
///   PRIVATE_KEY=0x... 
///     forge script script/DeployGRS.s.sol:DeployGRS --rpc-url sepolia --broadcast --verify
///
/// Deploy (Arbitrum spoke):
///   PRIVATE_KEY=0x... CHAIN=arbitrum HOME_ADDRESS=0x0000…<home GRS left-padded> HOME_EID=40161 \
///     forge script script/DeployGRS.s.sol:DeployGRS --rpc-url arbitrum --broadcast --verify
///
/// Set Solana peer:
///   PRIVATE_KEY=0x... GRS=0x... SOLANA_PEER=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "setSolanaPeer()" --rpc-url sepolia --broadcast
///
/// List TGE-style sales on home (local `dstEid=0`; override with DST_EID / GRS_AMOUNT / RECIPIENT):
///   PRIVATE_KEY=0x... GRS=0x... USDC=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "listSaleUsdc1M()" --rpc-url $RPC --broadcast
///   PRIVATE_KEY=0x... GRS=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "listSaleEth400()" --rpc-url $RPC --broadcast
///
/// Publish to Solana spoke (home must already `setPeer`; quote asset is Solana-native):
///   PRIVATE_KEY=0x... GRS=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "listSaleUsdc1MToSolana()" --rpc-url $RPC --broadcast
///   PRIVATE_KEY=0x... GRS=0x... \
///     forge script script/DeployGRS.s.sol:DeployGRS --sig "listSaleSol9090ToSolana()" --rpc-url $RPC --broadcast
contract DeployGRS is Script {
    /// @dev Canonical USDC (6 decimals). Override with `USDC=`.
    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Default lot size at $0.02 / GRS: $1M USDC or ~$1M in ETH → 50M GRS.
    uint256 internal constant SALE_GRS_50M = 50_000_000 ether;
    uint256 internal constant SALE_USDC_1M = 1_000_000e6;
    uint256 internal constant SALE_ETH_400 = 400 ether;
    /// @dev 9090 SOL in lamports (9 decimals) — Solana native quote for spoke sales.
    uint256 internal constant SALE_SOL_9090_LAMPORTS = 9090 * 1e9;

    /// @dev Solana USDC mint as bytes32 (Pubkey). Override with `SOLANA_USDC=`.
    ///      Mainnet `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`
    bytes32 internal constant SOLANA_USDC_MAINNET =
        0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
    ///      Devnet `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU`
    bytes32 internal constant SOLANA_USDC_DEVNET =
        0x3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b7790608df002ea7;

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
        bytes32 homeAddress = _deployHomeAddress(net);
        uint32 homeEid = _deployHomeEid(net, homeAddress);
        address endpoint = vm.envOr("LZ_ENDPOINT", net.endpoint);

        console2.log("chain     ", net.name);
        console2.log("chainId   ", net.chainId);
        console2.log("lzEid     ", uint256(net.eid));
        console2.log("lzEndpoint", endpoint);
        console2.log("delegate  ", delegate);
        console2.log("homeAddr  ");
        console2.logBytes32(homeAddress);
        console2.log("homeEid   ", uint256(homeEid));
        console2.log("isHome    ", homeAddress == bytes32(0));

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return GRS(address(0));
        }

        require(block.chainid == net.chainId, "CHAIN / rpc mismatch");
        require(endpoint != address(0), "LZ_ENDPOINT required");

        vm.startBroadcast(pk);
        grs = new GRS(endpoint, delegate, homeEid, homeAddress);

        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (ownerMultisig != address(0)) {
            grs.transferOwnership(ownerMultisig);
            console2.log("Pending owner (call acceptOwnership):", ownerMultisig);
        }
        vm.stopBroadcast();

        console2.log("GRS       ", address(grs));
        console2.log("homeAddr  ");
        console2.logBytes32(grs.homeAddress());
        console2.log("homeEid   ", uint256(grs.homeEid()));
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

    /// @notice Home local (or `DST_EID`) sale: **1,000,000 USDC** for `GRS_AMOUNT` (default 50M @ $0.02).
    ///         Env: `GRS`, `USDC` (or network default), optional `RECIPIENT`, `DST_EID`, `GRS_AMOUNT`.
    function listSaleUsdc1M() external returns (uint256 id) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        GRS grs = GRS(vm.envAddress("GRS"));
        address usdc = vm.envOr("USDC", _defaultUsdc());
        require(usdc != address(0), "USDC required (set USDC=)");

        uint256 grsAmount = vm.envOr("GRS_AMOUNT", SALE_GRS_50M);
        address recipient = vm.envOr("RECIPIENT", address(0));
        uint32 dstEid = uint32(vm.envOr("DST_EID", uint256(0)));
        uint256 fee = dstEid == 0 ? 0 : grs.quoteSale(_q(usdc), SALE_USDC_1M, grsAmount, _q(recipient), dstEid);

        console2.log("GRS        ", address(grs));
        console2.log("USDC       ", usdc);
        console2.log("assetAmount", SALE_USDC_1M);
        console2.log("grsAmount  ", grsAmount);
        console2.log("recipient  ", recipient);
        console2.log("dstEid     ", uint256(dstEid));
        console2.log("lzFee      ", fee);
        console2.log("reserved   ", grs.salesReserved());
        console2.log("remaining  ", grs.remaining(IGRS.Bucket.TokenSales));

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return 0;
        }

        require(grs.homeAddress() == bytes32(0), "GRS not home");
        require(grs.owner() == vm.addr(pk), "PRIVATE_KEY is not GRS owner");

        vm.startBroadcast(pk);
        id = grs.sale{value: fee}(_q(usdc), SALE_USDC_1M, grsAmount, _q(recipient), dstEid);
        vm.stopBroadcast();

        console2.log("sale id    ", id);
        console2.log("reserved   ", grs.salesReserved());
    }

    /// @notice Home local (or `DST_EID`) sale: **400 ETH** for `GRS_AMOUNT` (default 50M @ ~$0.02 / ETH~$2.5k).
    ///         Env: `GRS`, optional `RECIPIENT`, `DST_EID`, `GRS_AMOUNT`.
    function listSaleEth400() external returns (uint256 id) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        GRS grs = GRS(vm.envAddress("GRS"));

        uint256 grsAmount = vm.envOr("GRS_AMOUNT", SALE_GRS_50M);
        address recipient = vm.envOr("RECIPIENT", address(0));
        uint32 dstEid = uint32(vm.envOr("DST_EID", uint256(0)));
        uint256 fee = dstEid == 0 ? 0 : grs.quoteSale(bytes32(0), SALE_ETH_400, grsAmount, _q(recipient), dstEid);

        console2.log("GRS        ", address(grs));
        console2.log("asset      ", "native ETH");
        console2.log("assetAmount", SALE_ETH_400);
        console2.log("grsAmount  ", grsAmount);
        console2.log("recipient  ", recipient);
        console2.log("dstEid     ", uint256(dstEid));
        console2.log("lzFee      ", fee);
        console2.log("reserved   ", grs.salesReserved());
        console2.log("remaining  ", grs.remaining(IGRS.Bucket.TokenSales));

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return 0;
        }

        require(grs.homeAddress() == bytes32(0), "GRS not home");
        require(grs.owner() == vm.addr(pk), "PRIVATE_KEY is not GRS owner");

        vm.startBroadcast(pk);
        id = grs.sale{value: fee}(bytes32(0), SALE_ETH_400, grsAmount, _q(recipient), dstEid);
        vm.stopBroadcast();

        console2.log("sale id    ", id);
        console2.log("reserved   ", grs.salesReserved());
    }

    /// @notice Home → Solana: **1,000,000 USDC** (SPL mint) for `GRS_AMOUNT` (default 50M).
    ///         Burns GRS on home and LZ-publishes so the spoke mints escrow.
    ///         Env: `GRS`, optional `SOLANA_EID`, `SOLANA_USDC`, `SOLANA_RECIPIENT` (bytes32), `GRS_AMOUNT`.
    function listSaleUsdc1MToSolana() external returns (uint256 id) {
        Network memory home = _homeNetwork();
        Network memory solana = _defaultSolanaPeer(home);
        uint32 eid = uint32(vm.envOr("SOLANA_EID", uint256(solana.eid)));
        bytes32 usdcMint = vm.envOr("SOLANA_USDC", _defaultSolanaUsdc(solana));
        bytes32 recipient = vm.envOr("SOLANA_RECIPIENT", bytes32(0));
        id = _publishSaleToSolana(usdcMint, SALE_USDC_1M, "Solana USDC", eid, recipient);
    }

    /// @notice Home → Solana: **9090 SOL** (lamports) for `GRS_AMOUNT` (default 50M).
    ///         Native quote on spoke (`asset = 0`). Env: `GRS`, optional `SOLANA_EID`,
    ///         `SOLANA_RECIPIENT` (bytes32), `GRS_AMOUNT`.
    function listSaleSol9090ToSolana() external returns (uint256 id) {
        Network memory home = _homeNetwork();
        Network memory solana = _defaultSolanaPeer(home);
        uint32 eid = uint32(vm.envOr("SOLANA_EID", uint256(solana.eid)));
        bytes32 recipient = vm.envOr("SOLANA_RECIPIENT", bytes32(0));
        id = _publishSaleToSolana(bytes32(0), SALE_SOL_9090_LAMPORTS, "native SOL", eid, recipient);
    }

    function _publishSaleToSolana(
        bytes32 asset,
        uint256 assetAmount,
        string memory assetLabel,
        uint32 dstEid,
        bytes32 recipient
    ) internal returns (uint256 id) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        GRS grs = GRS(vm.envAddress("GRS"));
        uint256 grsAmount = vm.envOr("GRS_AMOUNT", SALE_GRS_50M);
        // Dust-free for OFT shared decimals (6): local 18 → amount % 1e12 == 0.
        require(grsAmount % 1e12 == 0, "GRS_AMOUNT has dust vs shared decimals");
        // Solana sale codec packs assetAmount as u64.
        require(assetAmount <= type(uint64).max, "assetAmount exceeds Solana u64");

        uint256 fee = grs.quoteSale(asset, assetAmount, grsAmount, recipient, dstEid);

        console2.log("GRS        ", address(grs));
        console2.log("asset      ", assetLabel);
        console2.log("assetAmount", assetAmount);
        console2.log("grsAmount  ", grsAmount);
        console2.log("dstEid     ", uint256(dstEid));
        console2.log("lzFee      ", fee);
        console2.log("remaining  ", grs.remaining(IGRS.Bucket.TokenSales));
        console2.log("asset mint ");
        console2.logBytes32(asset);
        console2.log("recipient  ");
        console2.logBytes32(recipient);
        console2.log("peer       ");
        console2.logBytes32(grs.peers(dstEid));

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return 0;
        }

        require(grs.homeAddress() == bytes32(0), "GRS not home");
        require(grs.owner() == vm.addr(pk), "PRIVATE_KEY is not GRS owner");
        require(grs.peers(dstEid) != bytes32(0), "Solana peer not set (setSolanaPeer)");

        vm.startBroadcast(pk);
        id = grs.sale{value: fee}(asset, assetAmount, grsAmount, recipient, dstEid);
        vm.stopBroadcast();

        console2.log("sale id    ", id);
        console2.log("home row closed (spoke buy after lzReceive)");
    }

    function _q(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _defaultUsdc() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 1) return USDC_ETHEREUM;
        if (id == 42_161) return USDC_ARBITRUM;
        if (id == 8453) return USDC_BASE;
        return address(0);
    }

    function _defaultSolanaUsdc(Network memory solana) internal pure returns (bytes32) {
        return solana.testnet ? SOLANA_USDC_DEVNET : SOLANA_USDC_MAINNET;
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

    /// @dev `HOME=true` or default-home chain → `bytes32(0)`. Else require `HOME_ADDRESS`.
    function _deployHomeAddress(Network memory net) internal view returns (bytes32 homeAddress) {
        if (vm.envOr("HOME", _defaultHome(net))) return bytes32(0);
        homeAddress = vm.envOr("HOME_ADDRESS", bytes32(0));
        require(homeAddress != bytes32(0), "HOME_ADDRESS required for spoke");
    }

    /// @dev Home deploy → `0`. Spoke → `HOME_EID` or Sepolia/Ethereum default from network class.
    function _deployHomeEid(Network memory net, bytes32 homeAddress) internal view returns (uint32) {
        if (homeAddress == bytes32(0)) return 0;
        uint32 eid = uint32(vm.envOr("HOME_EID", uint256(0)));
        if (eid != 0) return eid;
        return net.testnet ? 40_161 : 30_101; // Sepolia / Ethereum
    }

    function _defaultSolanaPeer(Network memory home) internal pure returns (Network memory) {
        require(!home.solana, "home is Solana");
        return home.testnet ? _byName("solana-devnet") : _byName("solana");
    }

    function _byName(string memory name) internal pure returns (Network memory) {
        bytes32 k = keccak256(bytes(name));
        if (k == keccak256("ethereum")) {
            return Network({
                name: "Ethereum",
                chainId: _lzChainId(30_101),
                eid: 30_101,
                endpoint: _lzEndpointV2(30_101),
                testnet: false,
                solana: false
            });
        }
        if (k == keccak256("arbitrum")) {
            return Network({
                name: "Arbitrum",
                chainId: _lzChainId(30_110),
                eid: 30_110,
                endpoint: _lzEndpointV2(30_110),
                testnet: false,
                solana: false
            });
        }
        if (k == keccak256("base")) {
            return Network({
                name: "Base",
                chainId: _lzChainId(30_184),
                eid: 30_184,
                endpoint: _lzEndpointV2(30_184),
                testnet: false,
                solana: false
            });
        }
        if (k == keccak256("sepolia")) {
            return Network({
                name: "Sepolia",
                chainId: _lzChainId(40_161),
                eid: 40_161,
                endpoint: _lzEndpointV2(40_161),
                testnet: true,
                solana: false
            });
        }
        if (k == keccak256("base-sepolia")) {
            return Network({
                name: "Base Sepolia",
                chainId: _lzChainId(40_245),
                eid: 40_245,
                endpoint: _lzEndpointV2(40_245),
                testnet: true,
                solana: false
            });
        }
        if (k == keccak256("arbitrum-sepolia")) {
            return Network({
                name: "Arbitrum Sepolia",
                chainId: _lzChainId(40_231),
                eid: 40_231,
                endpoint: _lzEndpointV2(40_231),
                testnet: true,
                solana: false
            });
        }
        if (k == keccak256("solana")) {
            return Network({
                name: "Solana", chainId: 0, eid: 30_168, endpoint: address(0), testnet: false, solana: true
            });
        }
        if (k == keccak256("solana-devnet")) {
            return Network({
                name: "Solana Devnet", chainId: 0, eid: 40_168, endpoint: address(0), testnet: true, solana: true
            });
        }
        revert("unknown CHAIN");
    }

    function _byChainId(uint256 chainId) internal pure returns (Network memory) {
        uint32 eid = _lzEid(chainId);
        if (eid == 30_101) return _byName("ethereum");
        if (eid == 30_110) return _byName("arbitrum");
        if (eid == 30_184) return _byName("base");
        if (eid == 40_161) return _byName("sepolia");
        if (eid == 40_245) return _byName("base-sepolia");
        if (eid == 40_231) return _byName("arbitrum-sepolia");
        revert("unknown chainId (set CHAIN=)");
    }

    function _dryRun() internal view returns (bool) {
        try vm.envBool("DRY_RUN") returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    /// @dev LayerZero V2 `EndpointV2` by eid (EVM only).
    ///      https://docs.layerzero.network/v2/deployments/deployed-contracts
    ///      Snapshot: metadata.layerzero-api.com/v1/metadata/deployments (v2, mainnet|testnet).
    function _lzEndpointV2(uint32 eid) internal pure returns (address) {
        // 74 chain(s): Binance Test Chain, Fuji, Mumbai, Fantom Testnet +70
        if (eid == 40102 || eid == 40106 || eid == 40109 || eid == 40112 || eid == 40125 || eid == 40126 || eid == 40138 || eid == 40145 || eid == 40150 || eid == 40153
            || eid == 40155 || eid == 40157 || eid == 40158 || eid == 40159 || eid == 40161 || eid == 40170 || eid == 40172 || eid == 40173 || eid == 40178 || eid == 40181
            || eid == 40195 || eid == 40196 || eid == 40197 || eid == 40199 || eid == 40200 || eid == 40201 || eid == 40202 || eid == 40210 || eid == 40211 || eid == 40216
            || eid == 40217 || eid == 40231 || eid == 40232 || eid == 40234 || eid == 40235 || eid == 40236 || eid == 40242 || eid == 40243 || eid == 40245 || eid == 40246
            || eid == 40247 || eid == 40249 || eid == 40251 || eid == 40252 || eid == 40255 || eid == 40256 || eid == 40258 || eid == 40259 || eid == 40260 || eid == 40262
            || eid == 40264 || eid == 40265 || eid == 40266 || eid == 40267 || eid == 40269 || eid == 40270 || eid == 40271 || eid == 40272 || eid == 40274 || eid == 40275
            || eid == 40277 || eid == 40278 || eid == 40279 || eid == 40280 || eid == 40281 || eid == 40282 || eid == 40284 || eid == 40287 || eid == 40289 || eid == 40291
            || eid == 40292 || eid == 40294 || eid == 40295 || eid == 40296) return 0x6EDCE65403992e310A62460808c4b910D972f10f;
        // 67 chain(s): Ethereum, BNB Chain, Avalanche, Polygon +63
        if (eid == 30101 || eid == 30102 || eid == 30106 || eid == 30109 || eid == 30110 || eid == 30111 || eid == 30112 || eid == 30115 || eid == 30116 || eid == 30118
            || eid == 30125 || eid == 30126 || eid == 30138 || eid == 30145 || eid == 30149 || eid == 30150 || eid == 30151 || eid == 30153 || eid == 30155 || eid == 30158
            || eid == 30159 || eid == 30167 || eid == 30173 || eid == 30175 || eid == 30177 || eid == 30181 || eid == 30182 || eid == 30183 || eid == 30184 || eid == 30195
            || eid == 30196 || eid == 30197 || eid == 30198 || eid == 30199 || eid == 30202 || eid == 30210 || eid == 30211 || eid == 30212 || eid == 30213 || eid == 30214
            || eid == 30215 || eid == 30216 || eid == 30217 || eid == 30234 || eid == 30235 || eid == 30236 || eid == 30237 || eid == 30243 || eid == 30255 || eid == 30257
            || eid == 30260 || eid == 30263 || eid == 30265 || eid == 30266 || eid == 30267 || eid == 30274 || eid == 30278 || eid == 30279 || eid == 30280 || eid == 30283
            || eid == 30284 || eid == 30285 || eid == 30290 || eid == 30291 || eid == 30293 || eid == 30294 || eid == 30295) return 0x1a44076050125825900e736c501f859c50fE728c;
        // 62 chain(s): EBI, peaq-mainnet, zircuit-mainnet, lightlink-mainnet +58
        if (eid == 30282 || eid == 30302 || eid == 30303 || eid == 30309 || eid == 30312 || eid == 30313 || eid == 30314 || eid == 30315 || eid == 30318 || eid == 30319
            || eid == 30320 || eid == 30321 || eid == 30322 || eid == 30327 || eid == 30329 || eid == 30332 || eid == 30337 || eid == 30338 || eid == 30361 || eid == 30362
            || eid == 30363 || eid == 30372 || eid == 30374 || eid == 30375 || eid == 30376 || eid == 30377 || eid == 30379 || eid == 30380 || eid == 30381 || eid == 30382
            || eid == 30383 || eid == 30384 || eid == 30386 || eid == 30390 || eid == 30391 || eid == 30393 || eid == 30394 || eid == 30395 || eid == 30396 || eid == 30397
            || eid == 30398 || eid == 30399 || eid == 30400 || eid == 30401 || eid == 30402 || eid == 30403 || eid == 30404 || eid == 30406 || eid == 30407 || eid == 30408
            || eid == 30409 || eid == 30412 || eid == 30413 || eid == 30414 || eid == 30415 || eid == 30416 || eid == 30417 || eid == 30418 || eid == 30461 || eid == 30464
            || eid == 30466 || eid == 30467) return 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        // 54 chain(s): besu1-testnet, dm2verse-testnet, animechain-testnet, stable-testnet +50
        if (eid == 40288 || eid == 40321 || eid == 40372 || eid == 40374 || eid == 40375 || eid == 40376 || eid == 40377 || eid == 40402 || eid == 40403 || eid == 40404
            || eid == 40406 || eid == 40407 || eid == 40408 || eid == 40409 || eid == 40410 || eid == 40411 || eid == 40413 || eid == 40414 || eid == 40415 || eid == 40416
            || eid == 40417 || eid == 40418 || eid == 40419 || eid == 40422 || eid == 40424 || eid == 40426 || eid == 40428 || eid == 40429 || eid == 40430 || eid == 40431
            || eid == 40433 || eid == 40435 || eid == 40436 || eid == 40437 || eid == 40438 || eid == 40440 || eid == 40442 || eid == 40445 || eid == 40446 || eid == 40447
            || eid == 40448 || eid == 40449 || eid == 40450 || eid == 40451 || eid == 40452 || eid == 40454 || eid == 40458 || eid == 40460 || eid == 40461 || eid == 40462
            || eid == 40463 || eid == 40464 || eid == 40466 || eid == 40467) return 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32;
        // 42 chain(s): monad-testnet, opencampus-testnet, vanar-testnet, peaq-testnet +38
        if (eid == 40204 || eid == 40297 || eid == 40298 || eid == 40299 || eid == 40300 || eid == 40301 || eid == 40304 || eid == 40306 || eid == 40307 || eid == 40308
            || eid == 40309 || eid == 40311 || eid == 40315 || eid == 40319 || eid == 40320 || eid == 40322 || eid == 40324 || eid == 40327 || eid == 40329 || eid == 40331
            || eid == 40336 || eid == 40338 || eid == 40342 || eid == 40344 || eid == 40345 || eid == 40346 || eid == 40347 || eid == 40349 || eid == 40350 || eid == 40351
            || eid == 40353 || eid == 40356 || eid == 40357 || eid == 40358 || eid == 40359 || eid == 40361 || eid == 40370 || eid == 40371 || eid == 40421 || eid == 40434
            || eid == 40455 || eid == 40457) return 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff;
        // 14 chain(s): lyra-mainnet, bevm-mainnet, codex-mainnet, islander-mainnet +10
        if (eid == 30311 || eid == 30317 || eid == 30323 || eid == 30330 || eid == 30331 || eid == 30333 || eid == 30335 || eid == 30336 || eid == 30342 || eid == 30365
            || eid == 30366 || eid == 30371 || eid == 30388 || eid == 30389) return 0xcb566e3B6934Fa77258d68ea18E931fa75e1aaAa;
        // 8 chain(s): tiltyard-mainnet, hedera-mainnet, edu-mainnet, cronosevm-mainnet +4
        if (eid == 30238 || eid == 30316 || eid == 30328 || eid == 30359 || eid == 30364 || eid == 30367 || eid == 30392 || eid == 30462) return 0x3A73033C0b1407574C76BdBAc67f126f6b4a9AA9;
        // 5 chain(s): ozean-testnet, kevnet-testnet, worldcoin-testnet, memecoreformicarium-testnet +1
        if (eid == 40323 || eid == 40328 || eid == 40335 || eid == 40354 || eid == 40412) return 0x145C041566B21Bec558B2A37F1a5Ff261aB55998;
        // 5 chain(s): zklink-mainnet, abstract-mainnet, sophon-mainnet, cronoszkevm-mainnet +1
        if (eid == 30301 || eid == 30324 || eid == 30334 || eid == 30360 || eid == 30373) return 0x5c6cfF4b7C49805F8295Ff73C204ac83f3bC4AE7;
        // 4 chain(s): ble-testnet, minato-testnet, gameswift-testnet, odyssey-testnet
        if (eid == 40330 || eid == 40334 || eid == 40339 || eid == 40340) return 0x6Ac7bdc07A0583A362F1497252872AE6c0A5F5B8;
        // 3 chain(s): sophon-testnet, treasure-testnet, cronoszkevm-testnet
        if (eid == 40341 || eid == 40348 || eid == 40360) return 0x9EC2DB700a3c3D35888acCa134F3f860B4a0b41a;
        // 3 chain(s): etherlink-mainnet, space-mainnet, dinari-mainnet
        if (eid == 30292 || eid == 30341 || eid == 30385) return 0xAaB5A48CFC03Efa9cC34A2C1aAcCCB84b4b770e4;
        // 3 chain(s): masa-testnet, apexfusionnexus-testnet, megaeth2-testnet
        if (eid == 40263 || eid == 40355 || eid == 40427) return 0xb23b28012ee92E8dE39DEb57Af31722223034747;
        // 2 chain(s): doma-testnet, seismic-testnet
        if (eid == 40425 || eid == 40456) return 0x2072a32Df77bAE5713853d666f26bA5e47E54717;
        // 1 chain(s): lens-testnet
        if (eid == 40373) return 0x00B7b8ebA1c60183B0D2a10Fc3552902e8DD4f5f;
        // 1 chain(s): DOS Tesnet
        if (eid == 40286) return 0x08416c0eAa8ba93F907eC8D6a9cAb24821C53E64;
        // 1 chain(s): Moninet Testnet
        if (eid == 40459) return 0x0ac2924460A5b285fd205DeDB46738Ad46971061;
        // 1 chain(s): shimmer-mainnet
        if (eid == 30230) return 0x148f693af10ddfaE81cDdb36F4c93B31A90076e1;
        // 1 chain(s): abstract-testnet
        if (eid == 40313) return 0x16c693A3924B947298F7227792953Cd6BBb21Ac8;
        // 1 chain(s): nibiru-testnet
        if (eid == 40369) return 0x19Aa25541F9f1414dcEd4C9bA4225c2a24c77CFe;
        // 1 chain(s): tempo-mainnet
        if (eid == 30410) return 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
        // 1 chain(s): nibiru-mainnet
        if (eid == 30369) return 0x2a5E79DEE6E3544588BB3b675B1Cc3354Df2AEFD;
        // 1 chain(s): Meter Testnet
        if (eid == 40156) return 0x3E03163f253ec436d4562e5eFd038cf98827B7eC;
        // 1 chain(s): anubis-testnet
        if (eid == 40465) return 0x417cb9E12cfe7301c8b6ef8f63ffac55263e147C;
        // 1 chain(s): soneium-mainnet
        if (eid == 30340) return 0x4bCb6A963a9563C33569D7A512D35754221F3A19;
        // 1 chain(s): tempodev1-testnet
        if (eid == 40439) return 0x50C21fE63c28191ccDc167961992A63e14393565;
        // 1 chain(s): sagaevm-testnet
        if (eid == 40432) return 0x619Eb6de16b479Ec0bE4c81d5ca9402dd4746681;
        // 1 chain(s): Dexalot Subnet Testnet
        if (eid == 40118) return 0x72884B17f92a863fD056Ec3695Bd3484D601f39a;
        // 1 chain(s): somniashannon-testnet
        if (eid == 40405) return 0x75B3bDfB2b31728104711f52a5DF9f6319128c5d;
        // 1 chain(s): anubis-mainnet
        if (eid == 30465) return 0x76111DE813F83AAAdBD62773Bf41247634e2319a;
        // 1 chain(s): zkSync Era Testnet
        if (eid == 40165) return 0x82Bb8E5Ffd47Be07f0568C9aB0900DDA9D913aFD;
        // 1 chain(s): skale-testnet
        if (eid == 40273) return 0x82b7dc04A4ABCF2b4aE570F317dcab49f5a10f24;
        // 1 chain(s): DFK Chain Test
        if (eid == 40115) return 0x94FF3a4d9E9792dc59193ff753B5038A14c59570;
        // 1 chain(s): otherworld-testnet
        if (eid == 40337) return 0xBa8dF7424dAE9C2CDB4BC1aD2b63ABD97194fDb6;
        // 1 chain(s): plumephoenix-mainnet
        if (eid == 30370) return 0xC1b15d3B262bEeC0e3565C11C9e0F6134BdaCB36;
        // 1 chain(s): zklink-testnet
        if (eid == 40283) return 0xF3e37ca248Ff739b8d0BebCcEAe1eeB199223dba;
        // 1 chain(s): moderato-testnet
        if (eid == 40444) return 0xFB34352bA2e2D9cB93837bb19D36db5d93BcFC41;
        // 1 chain(s): sagaevm-mainnet
        if (eid == 30405) return 0xa20DB4Ffe74A31D17fc24BD32a7DD7555441058e;
        // 1 chain(s): unichain-testnet
        if (eid == 40333) return 0xb8815f3f882614048CbE201a67eF9c6F10fe5035;
        // 1 chain(s): hedera-testnet
        if (eid == 40285) return 0xbD672D1562Dd32C23B563C989d8140122483631d;
        // 1 chain(s): root-testnet
        if (eid == 40318) return 0xbc2a00d907a6Aa5226Fb9444953E4464a5f4844a;
        // 1 chain(s): ink-mainnet
        if (eid == 30339) return 0xca29f3A6f966Cb2fc0dE625F8f325c0C46dbE958;
        // 1 chain(s): zkSync Era Mainnet
        if (eid == 30165) return 0xd07C30aF3Ff30D96BDc9c6044958230Eb797DDBF;
        // 1 chain(s): skale-mainnet
        if (eid == 30273) return 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
        // 1 chain(s): zksyncsep-testnet
        if (eid == 40305) return 0xe2Ef622A13e71D9Dd2BBd12cd4b27e1516FA8a09;
        // 1 chain(s): etherlink-testnet
        if (eid == 40239) return 0xec28645346D781674B4272706D8a938dB2BAA2C6;
        // 1 chain(s): Meter Mainnet
        if (eid == 30176) return 0xef02BacD67C0AB45510927749009F6B9ffCE0631;
        // 1 chain(s): hyperliquid-testnet
        if (eid == 40362) return 0xf9e1815F151024bDE4B7C10BAC10e8Ba9F6b53E1;
        revert("unknown LZ eid");
    }

    /// @dev LayerZero V2 `native chainId by eid (EVM only)`.
    ///      https://docs.layerzero.network/v2/deployments/deployed-contracts
    ///      Snapshot: metadata.layerzero-api.com/v1/metadata/deployments (v2, mainnet|testnet).
    function _lzChainId(uint32 eid) internal pure returns (uint256) {
        if (eid == 30101) return 1; // Ethereum / ethereum-mainnet
        if (eid == 30102) return 56; // BNB Chain / bsc-mainnet
        if (eid == 30106) return 43114; // Avalanche / avalanche-mainnet
        if (eid == 30109) return 137; // Polygon / polygon-mainnet
        if (eid == 30110) return 42161; // Arbitrum / arbitrum-mainnet
        if (eid == 30111) return 10; // Optimism / optimism-mainnet
        if (eid == 30112) return 250; // Fantom / fantom-mainnet
        if (eid == 30115) return 53935; // DFK / dfk-mainnet
        if (eid == 30116) return 1666600000; // Harmony / harmony-mainnet
        if (eid == 30118) return 432204; // Dexalot Subnet / dexalot-mainnet
        if (eid == 30125) return 42220; // Celo Mainnet / celo-mainnet
        if (eid == 30126) return 1284; // Moonbeam / moonbeam-mainnet
        if (eid == 30138) return 122; // Fuse Mainnet / fuse-mainnet
        if (eid == 30145) return 100; // Gnosis / gnosis-mainnet
        if (eid == 30149) return 7979; // DOS Chain / dos-mainnet
        if (eid == 30150) return 8217; // Kaia Mainnet Cypress / klaytn-mainnet
        if (eid == 30151) return 1088; // Metis / metis-mainnet
        if (eid == 30153) return 1116; // Core Blockchain Mainnet / coredao-mainnet
        if (eid == 30155) return 66; // OKXChain Mainnet / okx-mainnet
        if (eid == 30158) return 1101; // Polygon zkEVM / zkpolygon-mainnet
        if (eid == 30159) return 7700; // Canto / canto-mainnet
        if (eid == 30165) return 324; // zkSync Era Mainnet / zksync-mainnet
        if (eid == 30167) return 1285; // Moonriver / moonriver-mainnet
        if (eid == 30173) return 1559; // Tenet / tenet-mainnet
        if (eid == 30175) return 42170; // Arbitrum Nova / nova-mainnet
        if (eid == 30176) return 82; // Meter Mainnet / meter-mainnet
        if (eid == 30177) return 2222; // Kava / kava-mainnet
        if (eid == 30181) return 5000; // Mantle / mantle-mainnet
        if (eid == 30182) return 1992; // hubble-mainnet / hubble-mainnet
        if (eid == 30183) return 59144; // Linea / zkconsensys-mainnet
        if (eid == 30184) return 8453; // Base / base-mainnet
        if (eid == 30195) return 7777777; // Zora / zora-mainnet
        if (eid == 30196) return 88; // Viction / tomo-mainnet
        if (eid == 30197) return 5151706; // loot-mainnet / loot-mainnet
        if (eid == 30198) return 4337; // Merit Circle / meritcircle-mainnet
        if (eid == 30199) return 40; // TelosEVM / telos-mainnet
        if (eid == 30202) return 204; // opBNB Mainnet / opbnb-mainnet
        if (eid == 30210) return 592; // Astar / astar-mainnet
        if (eid == 30211) return 1313161554; // Aurora Mainnet / aurora-mainnet
        if (eid == 30212) return 1030; // Conflux eSpace / conflux-mainnet
        if (eid == 30213) return 291; // Orderly Mainnet / orderly-mainnet
        if (eid == 30214) return 534352; // Scroll / scroll-mainnet
        if (eid == 30215) return 7332; // Horizen EON Mainnet / eon-mainnet
        if (eid == 30216) return 37; // XPLA Mainnet / xpla-mainnet
        if (eid == 30217) return 169; // Manta / manta-mainnet
        if (eid == 30230) return 148; // shimmer-mainnet / shimmer-mainnet
        if (eid == 30234) return 2525; // Injective / bb1-mainnet
        if (eid == 30235) return 1380012617; // Rari Chain / rarible-mainnet
        if (eid == 30236) return 660279; // xai-mainnet / xai-mainnet
        if (eid == 30237) return 111188; // real-mainnet / real-mainnet
        if (eid == 30238) return 710420; // tiltyard-mainnet / tiltyard-mainnet
        if (eid == 30243) return 81457; // Blast / blast-mainnet
        if (eid == 30255) return 252; // Fraxtal / fraxtal-mainnet
        if (eid == 30257) return 3776; // Astar zkEVM / zkatana-mainnet
        if (eid == 30260) return 34443; // Mode / mode-mainnet
        if (eid == 30263) return 13396; // masa-mainnet / masa-mainnet
        if (eid == 30265) return 19011; // homeverse-mainnet / homeverse-mainnet
        if (eid == 30266) return 4200; // merlin-mainnet / merlin-mainnet
        if (eid == 30267) return 666666666; // degen-mainnet / degen-mainnet
        if (eid == 30273) return 2046399126; // skale-mainnet / skale-mainnet
        if (eid == 30274) return 196; // xlayer-mainnet / xlayer-mainnet
        if (eid == 30278) return 1996; // sanko-mainnet / sanko-mainnet
        if (eid == 30279) return 60808; // bob-mainnet / bob-mainnet
        if (eid == 30280) return 1329; // sei-mainnet / sei-mainnet
        if (eid == 30282) return 98881; // EBI / ebi-mainnet
        if (eid == 30283) return 7560; // cyber-mainnet / cyber-mainnet
        if (eid == 30284) return 8822; // IOTA EVM / iota-mainnet
        if (eid == 30285) return 81; // joc-mainnet / joc-mainnet
        if (eid == 30290) return 167000; // taiko-mainnet / taiko-mainnet
        if (eid == 30291) return 94524; // xchain-mainnet / xchain-mainnet
        if (eid == 30292) return 42793; // etherlink-mainnet / etherlink-mainnet
        if (eid == 30293) return 6001; // bouncebit-mainnet / bouncebit-mainnet
        if (eid == 30294) return 1625; // gravity-mainnet / gravity-mainnet
        if (eid == 30295) return 14; // flare-mainnet / flare-mainnet
        if (eid == 30301) return 810180; // zklink-mainnet / zklink-mainnet
        if (eid == 30302) return 3338; // peaq-mainnet / peaq-mainnet
        if (eid == 30303) return 48900; // zircuit-mainnet / zircuit-mainnet
        if (eid == 30309) return 1890; // lightlink-mainnet / lightlink-mainnet
        if (eid == 30311) return 957; // lyra-mainnet / lyra-mainnet
        if (eid == 30312) return 33139; // ape-mainnet / ape-mainnet
        if (eid == 30313) return 1729; // reya-mainnet / reya-mainnet
        if (eid == 30314) return 200901; // bitlayer-mainnet / bitlayer-mainnet
        if (eid == 30315) return 68770; // dm2verse-mainnet / dm2verse-mainnet
        if (eid == 30316) return 295; // hedera-mainnet / hedera-mainnet
        if (eid == 30317) return 11501; // bevm-mainnet / bevm-mainnet
        if (eid == 30318) return 98865; // plume-mainnet / plume-mainnet
        if (eid == 30319) return 480; // worldchain-mainnet / worldchain-mainnet
        if (eid == 30320) return 130; // unichain-mainnet / unichain-mainnet
        if (eid == 30321) return 1135; // lisk-mainnet / lisk-mainnet
        if (eid == 30322) return 2818; // morph-mainnet / morph-mainnet
        if (eid == 30323) return 81224; // codex-mainnet / codex-mainnet
        if (eid == 30324) return 2741; // abstract-mainnet / abstract-mainnet
        if (eid == 30327) return 55244; // superposition-mainnet / superposition-mainnet
        if (eid == 30328) return 41923; // edu-mainnet / edu-mainnet
        if (eid == 30329) return 43111; // hemi-mainnet / hemi-mainnet
        if (eid == 30330) return 1480; // islander-mainnet / islander-mainnet
        if (eid == 30331) return 21000000; // Corn / mp1-mainnet
        if (eid == 30332) return 146; // sonic-mainnet / sonic-mainnet
        if (eid == 30333) return 30; // rootstock-mainnet / rootstock-mainnet
        if (eid == 30334) return 50104; // sophon-mainnet / sophon-mainnet
        if (eid == 30335) return 1923; // swell-mainnet / swell-mainnet
        if (eid == 30336) return 747; // flow-mainnet / flow-mainnet
        if (eid == 30339) return 57073; // ink-mainnet / ink-mainnet
        if (eid == 30340) return 1868; // soneium-mainnet / soneium-mainnet
        if (eid == 30341) return 8227; // space-mainnet / space-mainnet
        if (eid == 30342) return 1300; // glue-mainnet / glue-mainnet
        if (eid == 30359) return 25; // cronosevm-mainnet / cronosevm-mainnet
        if (eid == 30360) return 388; // cronoszkevm-mainnet / cronoszkevm-mainnet
        if (eid == 30361) return 2345; // goat-mainnet / goat-mainnet
        if (eid == 30362) return 80094; // bera-mainnet / bera-mainnet
        if (eid == 30363) return 5165; // bahamut-mainnet / bahamut-mainnet
        if (eid == 30364) return 1514; // Data / story-mainnet
        if (eid == 30365) return 50; // xdc-mainnet / xdc-mainnet
        if (eid == 30366) return 12739; // concrete-mainnet / concrete-mainnet
        if (eid == 30367) return 999; // hyperliquid-mainnet / hyperliquid-mainnet
        if (eid == 30369) return 6900; // nibiru-mainnet / nibiru-mainnet
        if (eid == 30370) return 98866; // plumephoenix-mainnet / plumephoenix-mainnet
        if (eid == 30371) return 43419; // gunz-mainnet / gunz-mainnet
        if (eid == 30372) return 69000; // animechain-mainnet / animechain-mainnet
        if (eid == 30373) return 232; // lens-mainnet / lens-mainnet
        if (eid == 30374) return 964; // subtensorevm-mainnet / subtensorevm-mainnet
        if (eid == 30375) return 747474; // katana-mainnet / katana-mainnet
        if (eid == 30376) return 3637; // botanix-mainnet / botanix-mainnet
        if (eid == 30377) return 239; // tac-mainnet / tac-mainnet
        if (eid == 30379) return 2355; // silicon-mainnet / silicon-mainnet
        if (eid == 30380) return 5031; // somnia-mainnet / somnia-mainnet
        if (eid == 30381) return 484; // camp-mainnet / camp-mainnet
        if (eid == 30382) return 6985385; // humanity-mainnet / humanity-mainnet
        if (eid == 30383) return 9745; // plasma-mainnet / plasma-mainnet
        if (eid == 30384) return 9069; // apexfusionnexus-mainnet / apexfusionnexus-mainnet
        if (eid == 30385) return 202110; // dinari-mainnet / dinari-mainnet
        if (eid == 30386) return 1408; // zkVerify / zkverify-mainnet
        if (eid == 30388) return 16661; // 0G / og-mainnet
        if (eid == 30389) return 10088; // gatelayer-mainnet / gatelayer-mainnet
        if (eid == 30390) return 143; // monad-mainnet / monad-mainnet
        if (eid == 30391) return 5064014; // ethereal-mainnet / ethereal-mainnet
        if (eid == 30392) return 1612; // openledger-mainnet / openledger-mainnet
        if (eid == 30393) return 97477; // doma-mainnet / doma-mainnet
        if (eid == 30394) return 1776; // injectiveevm-mainnet / injectiveevm-mainnet
        if (eid == 30395) return 7208; // nexera-mainnet / nexera-mainnet
        if (eid == 30396) return 988; // stable-mainnet / stable-mainnet
        if (eid == 30397) return 261131; // zama-mainnet / zama-mainnet
        if (eid == 30398) return 4326; // megaeth-mainnet / megaeth-mainnet
        if (eid == 30399) return 26514; // horizen-mainnet / horizen-mainnet
        if (eid == 30400) return 432; // converge-mainnet / converge-mainnet
        if (eid == 30401) return 4153; // rise-mainnet / rise-mainnet
        if (eid == 30402) return 151; // redbelly-mainnet / redbelly-mainnet
        if (eid == 30403) return 4114; // citrea-mainnet / citrea-mainnet
        if (eid == 30404) return 2288; // moca-mainnet / moca-mainnet
        if (eid == 30405) return 5464; // sagaevm-mainnet / sagaevm-mainnet
        if (eid == 30406) return 2366; // kite-mainnet / kite-mainnet
        if (eid == 30407) return 1672; // pharos-mainnet / pharos-mainnet
        if (eid == 30408) return 3282; // irys-mainnet / irys-mainnet
        if (eid == 30409) return 88888; // chiliz-mainnet / chiliz-mainnet
        if (eid == 30410) return 4217; // tempo-mainnet / tempo-mainnet
        if (eid == 30412) return 685689; // gensyn-mainnet / gensyn-mainnet
        if (eid == 30413) return 904; // ault-mainnet / ault-mainnet
        if (eid == 30414) return 47763; // neox-mainnet / neox-mainnet
        if (eid == 30415) return 72957; // rayls-mainnet / rayls-mainnet
        if (eid == 30416) return 4663; // robinhood-mainnet / robinhood-mainnet
        if (eid == 30417) return 5042; // arc-mainnet / arc-mainnet
        if (eid == 30461) return 21211; // onemoney-mainnet / onemoney-mainnet
        if (eid == 30462) return 784; // ritual-mainnet / ritual-mainnet
        if (eid == 30464) return 222; // opn-mainnet / opn-mainnet
        if (eid == 30465) return 6714; // anubis-mainnet / anubis-mainnet
        if (eid == 30466) return 4352; // memecore-mainnet / memecore-mainnet
        if (eid == 30467) return 177; // hashkey-mainnet / hashkey-mainnet
        if (eid == 40102) return 97; // Binance Test Chain / bsc-testnet
        if (eid == 40106) return 43113; // Fuji / avalanche-testnet
        if (eid == 40109) return 80001; // Mumbai / polygon-testnet
        if (eid == 40112) return 4002; // Fantom Testnet / fantom-testnet
        if (eid == 40115) return 335; // DFK Chain Test / dfk-testnet
        if (eid == 40118) return 432201; // Dexalot Subnet Testnet / dexalot-testnet
        if (eid == 40125) return 44787; // Celo Alfajores Testnet / celo-testnet
        if (eid == 40126) return 1287; // Moonbase Alpha / moonbeam-testnet
        if (eid == 40138) return 123; // fuse-testnet / fuse-testnet
        if (eid == 40145) return 10200; // Gnosis Chiado Testnet / gnosis-testnet
        if (eid == 40150) return 1001; // Kaia Testnet Baobab / klaytn-testnet
        if (eid == 40153) return 1115; // CoreDAO Testnet / coredao-testnet
        if (eid == 40155) return 65; // OKX Testnet / okx-testnet
        if (eid == 40156) return 83; // Meter Testnet / meter-testnet
        if (eid == 40157) return 59140; // Linea Testnet / zkconsensys-testnet
        if (eid == 40158) return 1442; // Polygon zkEVM Testnet / zkpolygon-testnet
        if (eid == 40159) return 7701; // Canto Tesnet / canto-testnet
        if (eid == 40161) return 11155111; // Sepolia / sepolia-testnet
        if (eid == 40165) return 280; // zkSync Era Testnet / zksync-testnet
        if (eid == 40170) return 534351; // Scroll Sepolia Testnet / scroll-testnet
        if (eid == 40172) return 2221; // Kava Testnet / kava-testnet
        if (eid == 40173) return 155; // Tenet Testnet / tenet-testnet
        if (eid == 40178) return 13337; // Merit Circle Testnet / meritcircle-testnet
        if (eid == 40181) return 5001; // Mantle Testnet / mantle-testnet
        if (eid == 40195) return 999999999; // Wanchain Testnet / zora-testnet
        if (eid == 40196) return 89; // Viction Testnet / tomo-testnet
        if (eid == 40197) return 9088912; // loot-testnet / loot-testnet
        if (eid == 40199) return 41; // Telos EVM Testnet / telos-testnet
        if (eid == 40200) return 4460; // Orderly Sepolia Testnet / orderly-testnet
        if (eid == 40201) return 1313161555; // Aurora Testnet / aurora-testnet
        if (eid == 40202) return 5611; // opBNB Testnet / opbnb-testnet
        if (eid == 40204) return 10143; // monad-testnet / monad-testnet
        if (eid == 40210) return 81; // Astar EVM Testnet / astar-testnet
        if (eid == 40211) return 71; // Conflux Testnet / conflux-testnet
        if (eid == 40216) return 47; // XPLA Testnet / xpla-testnet
        if (eid == 40217) return 17000; // Holesky / holesky-testnet
        if (eid == 40231) return 421614; // Arbitrum Sepolia Testnet / arbsep-testnet
        if (eid == 40232) return 11155420; // Optimism Sepolia / optsep-testnet
        if (eid == 40235) return 1918988905; // rarible-testnet / rarible-testnet
        if (eid == 40236) return 49321; // gunzilla-testnet / gunzilla-testnet
        if (eid == 40239) return 128123; // etherlink-testnet / etherlink-testnet
        if (eid == 40242) return 10081; // Japan Open Chain Testnet / joc-testnet
        if (eid == 40243) return 168587773; // blast-testnet / blast-testnet
        if (eid == 40245) return 84532; // basesep-testnet / basesep-testnet
        if (eid == 40246) return 5003; // mantlesep-testnet / mantlesep-testnet
        if (eid == 40247) return 2442; // Polygon zkEVM Sepolia / zkpolygonsep-testnet
        if (eid == 40249) return 999999999; // zorasep-testnet / zorasep-testnet
        if (eid == 40251) return 37714555429; // xai-testnet / xai-testnet
        if (eid == 40255) return 2522; // fraxtal-testnet / fraxtal-testnet
        if (eid == 40256) return 80084; // Berachain Testnet / bera-testnet
        if (eid == 40258) return 713715; // sei-testnet / sei-testnet
        if (eid == 40259) return 233; // exocore-testnet / exocore-testnet
        if (eid == 40260) return 919; // mode-testnet / mode-testnet
        if (eid == 40262) return 18233; // unreal-testnet / unreal-testnet
        if (eid == 40263) return 103454; // masa-testnet / masa-testnet
        if (eid == 40264) return 686868; // merlin-testnet / merlin-testnet
        if (eid == 40265) return 40875; // homeverse-testnet / homeverse-testnet
        if (eid == 40266) return 6038361; // zkastar-testnet / zkastar-testnet
        if (eid == 40267) return 80002; // amoy-testnet / amoy-testnet
        if (eid == 40269) return 195; // xlayer-testnet / xlayer-testnet
        if (eid == 40270) return 478; // form-testnet / form-testnet
        if (eid == 40271) return 1337; // ll1-testnet / ll1-testnet
        if (eid == 40272) return 3441006; // mantasep-testnet / mantasep-testnet
        if (eid == 40273) return 1444673419; // skale-testnet / skale-testnet
        if (eid == 40274) return 167009; // taiko-testnet / taiko-testnet
        if (eid == 40275) return 48899; // zircuit-testnet / zircuit-testnet
        if (eid == 40277) return 8101902; // olive-testnet / olive-testnet
        if (eid == 40278) return 1992; // sanko-testnet / sanko-testnet
        if (eid == 40279) return 111; // bob-testnet / bob-testnet
        if (eid == 40280) return 111557560; // cyber-testnet / cyber-testnet
        if (eid == 40281) return 3636; // botanix-testnet / botanix-testnet
        if (eid == 40282) return 64002; // XChain Testnet / xchain-testnet
        if (eid == 40283) return 810181; // zklink-testnet / zklink-testnet
        if (eid == 40284) return 98882; // ebi-testnet / ebi-testnet
        if (eid == 40285) return 296; // hedera-testnet / hedera-testnet
        if (eid == 40286) return 3939; // DOS Tesnet / dos-testnet
        if (eid == 40287) return 59141; // lineasep-testnet / lineasep-testnet
        if (eid == 40288) return 1337; // besu1-testnet / besu1-testnet
        if (eid == 40289) return 6000; // bouncebit-testnet / bouncebit-testnet
        if (eid == 40291) return 80084; // bartio-testnet / bartio-testnet
        if (eid == 40292) return 59902; // metissep-testnet / metissep-testnet
        if (eid == 40294) return 114; // flare-testnet / flare-testnet
        if (eid == 40295) return 325000; // camp-testnet / camp-testnet
        if (eid == 40296) return 1300; // glue-testnet / glue-testnet
        if (eid == 40297) return 656476; // opencampus-testnet / opencampus-testnet
        if (eid == 40298) return 78600; // vanar-testnet / vanar-testnet
        if (eid == 40299) return 9990; // peaq-testnet / peaq-testnet
        if (eid == 40300) return 1811; // lif3-testnet / lif3-testnet
        if (eid == 40301) return 18026; // fi-testnet / fi-testnet
        if (eid == 40304) return 161221135; // plume-testnet / plume-testnet
        if (eid == 40305) return 300; // zksyncsep-testnet / zksyncsep-testnet
        if (eid == 40306) return 33111; // curtis-testnet / curtis-testnet
        if (eid == 40307) return 1075; // IOTA EVM / iota-testnet
        if (eid == 40308) return 901; // lyra-testnet / lyra-testnet
        if (eid == 40309) return 1891; // lightlink-testnet / lightlink-testnet
        if (eid == 40311) return 6513784; // codex-testnet / codex-testnet
        if (eid == 40313) return 11124; // abstract-testnet / abstract-testnet
        if (eid == 40315) return 1513; // story-testnet / story-testnet
        if (eid == 40318) return 7672; // root-testnet / root-testnet
        if (eid == 40319) return 89346162; // reya-testnet / reya-testnet
        if (eid == 40320) return 200810; // bitlayer-testnet / bitlayer-testnet
        if (eid == 40321) return 68775; // dm2verse-testnet / dm2verse-testnet
        if (eid == 40322) return 2810; // morph-testnet / morph-testnet
        if (eid == 40323) return 7849306; // ozean-testnet / ozean-testnet
        if (eid == 40324) return 11503; // bevm-testnet / bevm-testnet
        if (eid == 40327) return 4202; // lisk-testnet / lisk-testnet
        if (eid == 40328) return 1301; // kevnet-testnet / kevnet-testnet
        if (eid == 40329) return 18230; // plume2-testnet / plume2-testnet
        if (eid == 40330) return 52085143; // ble-testnet / ble-testnet
        if (eid == 40331) return 71461164656; // bl2-testnet / bl2-testnet
        if (eid == 40333) return 1301; // unichain-testnet / unichain-testnet
        if (eid == 40334) return 1946; // minato-testnet / minato-testnet
        if (eid == 40335) return 4801; // worldcoin-testnet / worldcoin-testnet
        if (eid == 40336) return 98985; // superposition-testnet / superposition-testnet
        if (eid == 40337) return 48795; // otherworld-testnet / otherworld-testnet
        if (eid == 40338) return 743111; // hemi-testnet / hemi-testnet
        if (eid == 40339) return 10888; // gameswift-testnet / gameswift-testnet
        if (eid == 40340) return 1516; // odyssey-testnet / odyssey-testnet
        if (eid == 40341) return 531050104; // sophon-testnet / sophon-testnet
        if (eid == 40342) return 14800; // moksha-testnet / moksha-testnet
        if (eid == 40344) return 5115; // citrea-testnet / citrea-testnet
        if (eid == 40345) return 21000001; // Corn Testnet / mp1-testnet
        if (eid == 40346) return 80000; // bl3-testnet / bl3-testnet
        if (eid == 40347) return 2552; // bahamut-testnet / bahamut-testnet
        if (eid == 40348) return 978658; // treasure-testnet / treasure-testnet
        if (eid == 40349) return 57054; // sonic-testnet / sonic-testnet
        if (eid == 40350) return 31; // rootstock-testnet / rootstock-testnet
        if (eid == 40351) return 545; // flow-testnet / flow-testnet
        if (eid == 40353) return 1924; // swell-testnet / swell-testnet
        if (eid == 40354) return 43522; // memecoreformicarium-testnet / memecoreformicarium-testnet
        if (eid == 40355) return 9070; // apexfusionnexus-testnet / apexfusionnexus-testnet
        if (eid == 40356) return 48816; // goat-testnet / goat-testnet
        if (eid == 40357) return 996353; // bl6-testnet / bl6-testnet
        if (eid == 40358) return 763373; // ink-testnet / ink-testnet
        if (eid == 40359) return 338; // cronosevm-testnet / cronosevm-testnet
        if (eid == 40360) return 240; // cronoszkevm-testnet / cronoszkevm-testnet
        if (eid == 40361) return 2201; // stabledevnet-testnet / stabledevnet-testnet
        if (eid == 40362) return 998; // hyperliquid-testnet / hyperliquid-testnet
        if (eid == 40369) return 7210; // nibiru-testnet / nibiru-testnet
        if (eid == 40370) return 6342; // megaeth-testnet / megaeth-testnet
        if (eid == 40371) return 80069; // bepolia-testnet / bepolia-testnet
        if (eid == 40372) return 6900; // animechain-testnet / animechain-testnet
        if (eid == 40373) return 37111; // lens-testnet / lens-testnet
        if (eid == 40374) return 2201; // stable-testnet / stable-testnet
        if (eid == 40375) return 9000; // ondo-testnet / ondo-testnet
        if (eid == 40376) return 50312; // somnia-testnet / somnia-testnet
        if (eid == 40377) return 945; // subtensorevm-testnet / subtensorevm-testnet
        if (eid == 40402) return 52085144; // converge-testnet / converge-testnet
        if (eid == 40403) return 129399; // katana-testnet / katana-testnet
        if (eid == 40404) return 2391; // tacspb-testnet / tacspb-testnet
        if (eid == 40405) return 50312; // somniashannon-testnet / somniashannon-testnet
        if (eid == 40406) return 1414; // siliconsepolia-testnet / siliconsepolia-testnet
        if (eid == 40407) return 657468; // ethereal-testnet / ethereal-testnet
        if (eid == 40408) return 1439; // injective1439-testnet / injective1439-testnet
        if (eid == 40409) return 9746; // plasma-testnet / plasma-testnet
        if (eid == 40410) return 7080969; // humanity-testnet / humanity-testnet
        if (eid == 40411) return 9746; // plasma2-testnet / plasma2-testnet
        if (eid == 40412) return 179205; // dinari-testnet / dinari-testnet
        if (eid == 40413) return 161201; // openledger-testnet / openledger-testnet
        if (eid == 40414) return 1409; // zkVerify / zkverify-testnet
        if (eid == 40415) return 2368; // kite-testnet / kite-testnet
        if (eid == 40416) return 1952; // xlayer2-testnet / xlayer2-testnet
        if (eid == 40417) return 9746; // plasma3-testnet / plasma3-testnet
        if (eid == 40419) return 16601; // og-testnet / og-testnet
        if (eid == 40421) return 10087; // gate-testnet / gate-testnet
        if (eid == 40422) return 13374202; // ethereal2-testnet / ethereal2-testnet
        if (eid == 40424) return 10901; // zama-testnet / zama-testnet
        if (eid == 40425) return 97476; // doma-testnet / doma-testnet
        if (eid == 40426) return 72080; // nexera-testnet / nexera-testnet
        if (eid == 40427) return 6343; // megaeth2-testnet / megaeth2-testnet
        if (eid == 40428) return 16602; // oggalileo-testnet / oggalileo-testnet
        if (eid == 40429) return 153; // redbelly-testnet / redbelly-testnet
        if (eid == 40430) return 127823; // etherlinkshadownet-testnet / etherlinkshadownet-testnet
        if (eid == 40432) return 54647359; // sagaevm-testnet / sagaevm-testnet
        if (eid == 40433) return 222888; // moca-testnet / moca-testnet
        if (eid == 40434) return 5042002; // arc-testnet / arc-testnet
        if (eid == 40435) return 2651420; // horizen-testnet / horizen-testnet
        if (eid == 40436) return 688689; // atlanticocean-testnet / atlanticocean-testnet
        if (eid == 40437) return 531050204; // sophonos-testnet / sophonos-testnet
        if (eid == 40438) return 11155931; // rise-testnet / rise-testnet
        if (eid == 40439) return 42429; // tempodev1-testnet / tempodev1-testnet
        if (eid == 40440) return 88882; // chilizspicy-testnet / chilizspicy-testnet
        if (eid == 40442) return 10143; // monad2-testnet / monad2-testnet
        if (eid == 40444) return 42431; // moderato-testnet / moderato-testnet
        if (eid == 40445) return 2019775; // jovay-testnet / jovay-testnet
        if (eid == 40446) return 123123; // raylsdevnet-testnet / raylsdevnet-testnet
        if (eid == 40447) return 1270; // irys-testnet / irys-testnet
        if (eid == 40448) return 737373; // bokuto-testnet / bokuto-testnet
        if (eid == 40449) return 560048; // hoodi-testnet / hoodi-testnet
        if (eid == 40450) return 98867; // plume4-testnet / plume4-testnet
        if (eid == 40451) return 46630; // robinhood-testnet / robinhood-testnet
        if (eid == 40452) return 10904; // ault-testnet / ault-testnet
        if (eid == 40454) return 685685; // gensyn-testnet / gensyn-testnet
        if (eid == 40455) return 1328; // sei2-testnet / sei2-testnet
        if (eid == 40456) return 5124; // seismic-testnet / seismic-testnet
        if (eid == 40457) return 12227332; // neox-testnet / neox-testnet
        if (eid == 40458) return 7295799; // rayls-testnet / rayls-testnet
        if (eid == 40460) return 1979; // Ritual Testnet / ritual-testnet
        if (eid == 40461) return 1212111; // 1money Testnet / onemoney-testnet
        if (eid == 40462) return 99999; // Chain A / adi-testnet
        if (eid == 40463) return 2017; // Adiri Testnet / adiri-testnet
        if (eid == 40464) return 984; // opn-testnet / opn-testnet
        if (eid == 40465) return 202601; // anubis-testnet / anubis-testnet
        if (eid == 40466) return 43522; // memecore-testnet / memecore-testnet
        if (eid == 40467) return 133; // hashkey-testnet / hashkey-testnet
        revert("unknown LZ eid");
    }

    /// @dev LayerZero V2 `eid by native chainId (EVM only; collisions prefer ACTIVE mainnet)`.
    ///      https://docs.layerzero.network/v2/deployments/deployed-contracts
    ///      Snapshot: metadata.layerzero-api.com/v1/metadata/deployments (v2, mainnet|testnet).
    function _lzEid(uint256 chainId) internal pure returns (uint32) {
        if (chainId == 1) return 30101; // Ethereum / ethereum-mainnet
        if (chainId == 10) return 30111; // Optimism / optimism-mainnet
        if (chainId == 14) return 30295; // flare-mainnet / flare-mainnet
        if (chainId == 25) return 30359; // cronosevm-mainnet / cronosevm-mainnet
        if (chainId == 30) return 30333; // rootstock-mainnet / rootstock-mainnet
        if (chainId == 31) return 40350; // rootstock-testnet / rootstock-testnet
        if (chainId == 37) return 30216; // XPLA Mainnet / xpla-mainnet
        if (chainId == 40) return 30199; // TelosEVM / telos-mainnet
        if (chainId == 41) return 40199; // Telos EVM Testnet / telos-testnet
        if (chainId == 47) return 40216; // XPLA Testnet / xpla-testnet
        if (chainId == 50) return 30365; // xdc-mainnet / xdc-mainnet
        if (chainId == 56) return 30102; // BNB Chain / bsc-mainnet
        if (chainId == 65) return 40155; // OKX Testnet / okx-testnet
        if (chainId == 66) return 30155; // OKXChain Mainnet / okx-mainnet
        if (chainId == 71) return 40211; // Conflux Testnet / conflux-testnet
        if (chainId == 81) return 30285; // joc-mainnet / joc-mainnet
        if (chainId == 82) return 30176; // Meter Mainnet / meter-mainnet
        if (chainId == 83) return 40156; // Meter Testnet / meter-testnet
        if (chainId == 88) return 30196; // Viction / tomo-mainnet
        if (chainId == 89) return 40196; // Viction Testnet / tomo-testnet
        if (chainId == 97) return 40102; // Binance Test Chain / bsc-testnet
        if (chainId == 100) return 30145; // Gnosis / gnosis-mainnet
        if (chainId == 111) return 40279; // bob-testnet / bob-testnet
        if (chainId == 114) return 40294; // flare-testnet / flare-testnet
        if (chainId == 122) return 30138; // Fuse Mainnet / fuse-mainnet
        if (chainId == 123) return 40138; // fuse-testnet / fuse-testnet
        if (chainId == 130) return 30320; // unichain-mainnet / unichain-mainnet
        if (chainId == 133) return 40467; // hashkey-testnet / hashkey-testnet
        if (chainId == 137) return 30109; // Polygon / polygon-mainnet
        if (chainId == 143) return 30390; // monad-mainnet / monad-mainnet
        if (chainId == 146) return 30332; // sonic-mainnet / sonic-mainnet
        if (chainId == 148) return 30230; // shimmer-mainnet / shimmer-mainnet
        if (chainId == 151) return 30402; // redbelly-mainnet / redbelly-mainnet
        if (chainId == 153) return 40429; // redbelly-testnet / redbelly-testnet
        if (chainId == 155) return 40173; // Tenet Testnet / tenet-testnet
        if (chainId == 169) return 30217; // Manta / manta-mainnet
        if (chainId == 177) return 30467; // hashkey-mainnet / hashkey-mainnet
        if (chainId == 195) return 40269; // xlayer-testnet / xlayer-testnet
        if (chainId == 196) return 30274; // xlayer-mainnet / xlayer-mainnet
        if (chainId == 204) return 30202; // opBNB Mainnet / opbnb-mainnet
        if (chainId == 222) return 30464; // opn-mainnet / opn-mainnet
        if (chainId == 232) return 30373; // lens-mainnet / lens-mainnet
        if (chainId == 233) return 40259; // exocore-testnet / exocore-testnet
        if (chainId == 239) return 30377; // tac-mainnet / tac-mainnet
        if (chainId == 240) return 40360; // cronoszkevm-testnet / cronoszkevm-testnet
        if (chainId == 250) return 30112; // Fantom / fantom-mainnet
        if (chainId == 252) return 30255; // Fraxtal / fraxtal-mainnet
        if (chainId == 280) return 40165; // zkSync Era Testnet / zksync-testnet
        if (chainId == 291) return 30213; // Orderly Mainnet / orderly-mainnet
        if (chainId == 295) return 30316; // hedera-mainnet / hedera-mainnet
        if (chainId == 296) return 40285; // hedera-testnet / hedera-testnet
        if (chainId == 300) return 40305; // zksyncsep-testnet / zksyncsep-testnet
        if (chainId == 324) return 30165; // zkSync Era Mainnet / zksync-mainnet
        if (chainId == 335) return 40115; // DFK Chain Test / dfk-testnet
        if (chainId == 338) return 40359; // cronosevm-testnet / cronosevm-testnet
        if (chainId == 388) return 30360; // cronoszkevm-mainnet / cronoszkevm-mainnet
        if (chainId == 432) return 30400; // converge-mainnet / converge-mainnet
        if (chainId == 478) return 40270; // form-testnet / form-testnet
        if (chainId == 480) return 30319; // worldchain-mainnet / worldchain-mainnet
        if (chainId == 484) return 30381; // camp-mainnet / camp-mainnet
        if (chainId == 545) return 40351; // flow-testnet / flow-testnet
        if (chainId == 592) return 30210; // Astar / astar-mainnet
        if (chainId == 747) return 30336; // flow-mainnet / flow-mainnet
        if (chainId == 784) return 30462; // ritual-mainnet / ritual-mainnet
        if (chainId == 901) return 40308; // lyra-testnet / lyra-testnet
        if (chainId == 904) return 30413; // ault-mainnet / ault-mainnet
        if (chainId == 919) return 40260; // mode-testnet / mode-testnet
        if (chainId == 945) return 40377; // subtensorevm-testnet / subtensorevm-testnet
        if (chainId == 957) return 30311; // lyra-mainnet / lyra-mainnet
        if (chainId == 964) return 30374; // subtensorevm-mainnet / subtensorevm-mainnet
        if (chainId == 984) return 40464; // opn-testnet / opn-testnet
        if (chainId == 988) return 30396; // stable-mainnet / stable-mainnet
        if (chainId == 998) return 40362; // hyperliquid-testnet / hyperliquid-testnet
        if (chainId == 999) return 30367; // hyperliquid-mainnet / hyperliquid-mainnet
        if (chainId == 1001) return 40150; // Kaia Testnet Baobab / klaytn-testnet
        if (chainId == 1030) return 30212; // Conflux eSpace / conflux-mainnet
        if (chainId == 1075) return 40307; // IOTA EVM / iota-testnet
        if (chainId == 1088) return 30151; // Metis / metis-mainnet
        if (chainId == 1101) return 30158; // Polygon zkEVM / zkpolygon-mainnet
        if (chainId == 1115) return 40153; // CoreDAO Testnet / coredao-testnet
        if (chainId == 1116) return 30153; // Core Blockchain Mainnet / coredao-mainnet
        if (chainId == 1135) return 30321; // lisk-mainnet / lisk-mainnet
        if (chainId == 1270) return 40447; // irys-testnet / irys-testnet
        if (chainId == 1284) return 30126; // Moonbeam / moonbeam-mainnet
        if (chainId == 1285) return 30167; // Moonriver / moonriver-mainnet
        if (chainId == 1287) return 40126; // Moonbase Alpha / moonbeam-testnet
        if (chainId == 1300) return 40296; // glue-testnet / glue-testnet
        if (chainId == 1301) return 40328; // kevnet-testnet / kevnet-testnet
        if (chainId == 1328) return 40455; // sei2-testnet / sei2-testnet
        if (chainId == 1329) return 30280; // sei-mainnet / sei-mainnet
        if (chainId == 1337) return 40271; // ll1-testnet / ll1-testnet
        if (chainId == 1408) return 30386; // zkVerify / zkverify-mainnet
        if (chainId == 1409) return 40414; // zkVerify / zkverify-testnet
        if (chainId == 1414) return 40406; // siliconsepolia-testnet / siliconsepolia-testnet
        if (chainId == 1439) return 40408; // injective1439-testnet / injective1439-testnet
        if (chainId == 1442) return 40158; // Polygon zkEVM Testnet / zkpolygon-testnet
        if (chainId == 1480) return 30330; // islander-mainnet / islander-mainnet
        if (chainId == 1513) return 40315; // story-testnet / story-testnet
        if (chainId == 1514) return 30364; // Data / story-mainnet
        if (chainId == 1516) return 40340; // odyssey-testnet / odyssey-testnet
        if (chainId == 1559) return 30173; // Tenet / tenet-mainnet
        if (chainId == 1612) return 30392; // openledger-mainnet / openledger-mainnet
        if (chainId == 1625) return 30294; // gravity-mainnet / gravity-mainnet
        if (chainId == 1672) return 30407; // pharos-mainnet / pharos-mainnet
        if (chainId == 1729) return 30313; // reya-mainnet / reya-mainnet
        if (chainId == 1776) return 30394; // injectiveevm-mainnet / injectiveevm-mainnet
        if (chainId == 1811) return 40300; // lif3-testnet / lif3-testnet
        if (chainId == 1868) return 30340; // soneium-mainnet / soneium-mainnet
        if (chainId == 1890) return 30309; // lightlink-mainnet / lightlink-mainnet
        if (chainId == 1891) return 40309; // lightlink-testnet / lightlink-testnet
        if (chainId == 1923) return 30335; // swell-mainnet / swell-mainnet
        if (chainId == 1924) return 40353; // swell-testnet / swell-testnet
        if (chainId == 1946) return 40334; // minato-testnet / minato-testnet
        if (chainId == 1952) return 40416; // xlayer2-testnet / xlayer2-testnet
        if (chainId == 1979) return 40460; // Ritual Testnet / ritual-testnet
        if (chainId == 1992) return 30182; // hubble-mainnet / hubble-mainnet
        if (chainId == 1996) return 30278; // sanko-mainnet / sanko-mainnet
        if (chainId == 2017) return 40463; // Adiri Testnet / adiri-testnet
        if (chainId == 2201) return 40361; // stabledevnet-testnet / stabledevnet-testnet
        if (chainId == 2221) return 40172; // Kava Testnet / kava-testnet
        if (chainId == 2222) return 30177; // Kava / kava-mainnet
        if (chainId == 2288) return 30404; // moca-mainnet / moca-mainnet
        if (chainId == 2345) return 30361; // goat-mainnet / goat-mainnet
        if (chainId == 2355) return 30379; // silicon-mainnet / silicon-mainnet
        if (chainId == 2366) return 30406; // kite-mainnet / kite-mainnet
        if (chainId == 2368) return 40415; // kite-testnet / kite-testnet
        if (chainId == 2391) return 40404; // tacspb-testnet / tacspb-testnet
        if (chainId == 2442) return 40247; // Polygon zkEVM Sepolia / zkpolygonsep-testnet
        if (chainId == 2522) return 40255; // fraxtal-testnet / fraxtal-testnet
        if (chainId == 2525) return 30234; // Injective / bb1-mainnet
        if (chainId == 2552) return 40347; // bahamut-testnet / bahamut-testnet
        if (chainId == 2741) return 30324; // abstract-mainnet / abstract-mainnet
        if (chainId == 2810) return 40322; // morph-testnet / morph-testnet
        if (chainId == 2818) return 30322; // morph-mainnet / morph-mainnet
        if (chainId == 3282) return 30408; // irys-mainnet / irys-mainnet
        if (chainId == 3338) return 30302; // peaq-mainnet / peaq-mainnet
        if (chainId == 3636) return 40281; // botanix-testnet / botanix-testnet
        if (chainId == 3637) return 30376; // botanix-mainnet / botanix-mainnet
        if (chainId == 3776) return 30257; // Astar zkEVM / zkatana-mainnet
        if (chainId == 3939) return 40286; // DOS Tesnet / dos-testnet
        if (chainId == 4002) return 40112; // Fantom Testnet / fantom-testnet
        if (chainId == 4114) return 30403; // citrea-mainnet / citrea-mainnet
        if (chainId == 4153) return 30401; // rise-mainnet / rise-mainnet
        if (chainId == 4200) return 30266; // merlin-mainnet / merlin-mainnet
        if (chainId == 4202) return 40327; // lisk-testnet / lisk-testnet
        if (chainId == 4217) return 30410; // tempo-mainnet / tempo-mainnet
        if (chainId == 4326) return 30398; // megaeth-mainnet / megaeth-mainnet
        if (chainId == 4337) return 30198; // Merit Circle / meritcircle-mainnet
        if (chainId == 4352) return 30466; // memecore-mainnet / memecore-mainnet
        if (chainId == 4460) return 40200; // Orderly Sepolia Testnet / orderly-testnet
        if (chainId == 4663) return 30416; // robinhood-mainnet / robinhood-mainnet
        if (chainId == 4801) return 40335; // worldcoin-testnet / worldcoin-testnet
        if (chainId == 5000) return 30181; // Mantle / mantle-mainnet
        if (chainId == 5001) return 40181; // Mantle Testnet / mantle-testnet
        if (chainId == 5003) return 40246; // mantlesep-testnet / mantlesep-testnet
        if (chainId == 5031) return 30380; // somnia-mainnet / somnia-mainnet
        if (chainId == 5042) return 30417; // arc-mainnet / arc-mainnet
        if (chainId == 5115) return 40344; // citrea-testnet / citrea-testnet
        if (chainId == 5124) return 40456; // seismic-testnet / seismic-testnet
        if (chainId == 5165) return 30363; // bahamut-mainnet / bahamut-mainnet
        if (chainId == 5464) return 30405; // sagaevm-mainnet / sagaevm-mainnet
        if (chainId == 5611) return 40202; // opBNB Testnet / opbnb-testnet
        if (chainId == 6000) return 40289; // bouncebit-testnet / bouncebit-testnet
        if (chainId == 6001) return 30293; // bouncebit-mainnet / bouncebit-mainnet
        if (chainId == 6342) return 40370; // megaeth-testnet / megaeth-testnet
        if (chainId == 6343) return 40427; // megaeth2-testnet / megaeth2-testnet
        if (chainId == 6714) return 30465; // anubis-mainnet / anubis-mainnet
        if (chainId == 6900) return 30369; // nibiru-mainnet / nibiru-mainnet
        if (chainId == 7208) return 30395; // nexera-mainnet / nexera-mainnet
        if (chainId == 7210) return 40369; // nibiru-testnet / nibiru-testnet
        if (chainId == 7332) return 30215; // Horizen EON Mainnet / eon-mainnet
        if (chainId == 7560) return 30283; // cyber-mainnet / cyber-mainnet
        if (chainId == 7672) return 40318; // root-testnet / root-testnet
        if (chainId == 7700) return 30159; // Canto / canto-mainnet
        if (chainId == 7701) return 40159; // Canto Tesnet / canto-testnet
        if (chainId == 7979) return 30149; // DOS Chain / dos-mainnet
        if (chainId == 8217) return 30150; // Kaia Mainnet Cypress / klaytn-mainnet
        if (chainId == 8227) return 30341; // space-mainnet / space-mainnet
        if (chainId == 8453) return 30184; // Base / base-mainnet
        if (chainId == 8822) return 30284; // IOTA EVM / iota-mainnet
        if (chainId == 9000) return 40375; // ondo-testnet / ondo-testnet
        if (chainId == 9069) return 30384; // apexfusionnexus-mainnet / apexfusionnexus-mainnet
        if (chainId == 9070) return 40355; // apexfusionnexus-testnet / apexfusionnexus-testnet
        if (chainId == 9745) return 30383; // plasma-mainnet / plasma-mainnet
        if (chainId == 9746) return 40409; // plasma-testnet / plasma-testnet
        if (chainId == 9990) return 40299; // peaq-testnet / peaq-testnet
        if (chainId == 10081) return 40242; // Japan Open Chain Testnet / joc-testnet
        if (chainId == 10087) return 40421; // gate-testnet / gate-testnet
        if (chainId == 10088) return 30389; // gatelayer-mainnet / gatelayer-mainnet
        if (chainId == 10143) return 40204; // monad-testnet / monad-testnet
        if (chainId == 10200) return 40145; // Gnosis Chiado Testnet / gnosis-testnet
        if (chainId == 10888) return 40339; // gameswift-testnet / gameswift-testnet
        if (chainId == 10901) return 40424; // zama-testnet / zama-testnet
        if (chainId == 10904) return 40452; // ault-testnet / ault-testnet
        if (chainId == 11124) return 40313; // abstract-testnet / abstract-testnet
        if (chainId == 11501) return 30317; // bevm-mainnet / bevm-mainnet
        if (chainId == 11503) return 40324; // bevm-testnet / bevm-testnet
        if (chainId == 12739) return 30366; // concrete-mainnet / concrete-mainnet
        if (chainId == 13337) return 40178; // Merit Circle Testnet / meritcircle-testnet
        if (chainId == 13396) return 30263; // masa-mainnet / masa-mainnet
        if (chainId == 14800) return 40342; // moksha-testnet / moksha-testnet
        if (chainId == 16601) return 40419; // og-testnet / og-testnet
        if (chainId == 16602) return 40428; // oggalileo-testnet / oggalileo-testnet
        if (chainId == 16661) return 30388; // 0G / og-mainnet
        if (chainId == 17000) return 40217; // Holesky / holesky-testnet
        if (chainId == 18026) return 40301; // fi-testnet / fi-testnet
        if (chainId == 18230) return 40329; // plume2-testnet / plume2-testnet
        if (chainId == 18233) return 40262; // unreal-testnet / unreal-testnet
        if (chainId == 19011) return 30265; // homeverse-mainnet / homeverse-mainnet
        if (chainId == 21211) return 30461; // onemoney-mainnet / onemoney-mainnet
        if (chainId == 26514) return 30399; // horizen-mainnet / horizen-mainnet
        if (chainId == 33111) return 40306; // curtis-testnet / curtis-testnet
        if (chainId == 33139) return 30312; // ape-mainnet / ape-mainnet
        if (chainId == 34443) return 30260; // Mode / mode-mainnet
        if (chainId == 37111) return 40373; // lens-testnet / lens-testnet
        if (chainId == 40875) return 40265; // homeverse-testnet / homeverse-testnet
        if (chainId == 41923) return 30328; // edu-mainnet / edu-mainnet
        if (chainId == 42161) return 30110; // Arbitrum / arbitrum-mainnet
        if (chainId == 42170) return 30175; // Arbitrum Nova / nova-mainnet
        if (chainId == 42220) return 30125; // Celo Mainnet / celo-mainnet
        if (chainId == 42429) return 40439; // tempodev1-testnet / tempodev1-testnet
        if (chainId == 42431) return 40444; // moderato-testnet / moderato-testnet
        if (chainId == 42793) return 30292; // etherlink-mainnet / etherlink-mainnet
        if (chainId == 43111) return 30329; // hemi-mainnet / hemi-mainnet
        if (chainId == 43113) return 40106; // Fuji / avalanche-testnet
        if (chainId == 43114) return 30106; // Avalanche / avalanche-mainnet
        if (chainId == 43419) return 30371; // gunz-mainnet / gunz-mainnet
        if (chainId == 43522) return 40466; // memecore-testnet / memecore-testnet
        if (chainId == 44787) return 40125; // Celo Alfajores Testnet / celo-testnet
        if (chainId == 46630) return 40451; // robinhood-testnet / robinhood-testnet
        if (chainId == 47763) return 30414; // neox-mainnet / neox-mainnet
        if (chainId == 48795) return 40337; // otherworld-testnet / otherworld-testnet
        if (chainId == 48816) return 40356; // goat-testnet / goat-testnet
        if (chainId == 48899) return 40275; // zircuit-testnet / zircuit-testnet
        if (chainId == 48900) return 30303; // zircuit-mainnet / zircuit-mainnet
        if (chainId == 49321) return 40236; // gunzilla-testnet / gunzilla-testnet
        if (chainId == 50104) return 30334; // sophon-mainnet / sophon-mainnet
        if (chainId == 50312) return 40376; // somnia-testnet / somnia-testnet
        if (chainId == 53935) return 30115; // DFK / dfk-mainnet
        if (chainId == 55244) return 30327; // superposition-mainnet / superposition-mainnet
        if (chainId == 57054) return 40349; // sonic-testnet / sonic-testnet
        if (chainId == 57073) return 30339; // ink-mainnet / ink-mainnet
        if (chainId == 59140) return 40157; // Linea Testnet / zkconsensys-testnet
        if (chainId == 59141) return 40287; // lineasep-testnet / lineasep-testnet
        if (chainId == 59144) return 30183; // Linea / zkconsensys-mainnet
        if (chainId == 59902) return 40292; // metissep-testnet / metissep-testnet
        if (chainId == 60808) return 30279; // bob-mainnet / bob-mainnet
        if (chainId == 64002) return 40282; // XChain Testnet / xchain-testnet
        if (chainId == 68770) return 30315; // dm2verse-mainnet / dm2verse-mainnet
        if (chainId == 68775) return 40321; // dm2verse-testnet / dm2verse-testnet
        if (chainId == 69000) return 30372; // animechain-mainnet / animechain-mainnet
        if (chainId == 72080) return 40426; // nexera-testnet / nexera-testnet
        if (chainId == 72957) return 30415; // rayls-mainnet / rayls-mainnet
        if (chainId == 78600) return 40298; // vanar-testnet / vanar-testnet
        if (chainId == 80000) return 40346; // bl3-testnet / bl3-testnet
        if (chainId == 80001) return 40109; // Mumbai / polygon-testnet
        if (chainId == 80002) return 40267; // amoy-testnet / amoy-testnet
        if (chainId == 80069) return 40371; // bepolia-testnet / bepolia-testnet
        if (chainId == 80084) return 40256; // Berachain Testnet / bera-testnet
        if (chainId == 80094) return 30362; // bera-mainnet / bera-mainnet
        if (chainId == 81224) return 30323; // codex-mainnet / codex-mainnet
        if (chainId == 81457) return 30243; // Blast / blast-mainnet
        if (chainId == 84532) return 40245; // basesep-testnet / basesep-testnet
        if (chainId == 88882) return 40440; // chilizspicy-testnet / chilizspicy-testnet
        if (chainId == 88888) return 30409; // chiliz-mainnet / chiliz-mainnet
        if (chainId == 94524) return 30291; // xchain-mainnet / xchain-mainnet
        if (chainId == 97476) return 40425; // doma-testnet / doma-testnet
        if (chainId == 97477) return 30393; // doma-mainnet / doma-mainnet
        if (chainId == 98865) return 30318; // plume-mainnet / plume-mainnet
        if (chainId == 98866) return 30370; // plumephoenix-mainnet / plumephoenix-mainnet
        if (chainId == 98867) return 40450; // plume4-testnet / plume4-testnet
        if (chainId == 98881) return 30282; // EBI / ebi-mainnet
        if (chainId == 98882) return 40284; // ebi-testnet / ebi-testnet
        if (chainId == 98985) return 40336; // superposition-testnet / superposition-testnet
        if (chainId == 99999) return 40462; // Chain A / adi-testnet
        if (chainId == 103454) return 40263; // masa-testnet / masa-testnet
        if (chainId == 111188) return 30237; // real-mainnet / real-mainnet
        if (chainId == 123123) return 40446; // raylsdevnet-testnet / raylsdevnet-testnet
        if (chainId == 127823) return 40430; // etherlinkshadownet-testnet / etherlinkshadownet-testnet
        if (chainId == 128123) return 40239; // etherlink-testnet / etherlink-testnet
        if (chainId == 129399) return 40403; // katana-testnet / katana-testnet
        if (chainId == 161201) return 40413; // openledger-testnet / openledger-testnet
        if (chainId == 167000) return 30290; // taiko-mainnet / taiko-mainnet
        if (chainId == 167009) return 40274; // taiko-testnet / taiko-testnet
        if (chainId == 179205) return 40412; // dinari-testnet / dinari-testnet
        if (chainId == 200810) return 40320; // bitlayer-testnet / bitlayer-testnet
        if (chainId == 200901) return 30314; // bitlayer-mainnet / bitlayer-mainnet
        if (chainId == 202110) return 30385; // dinari-mainnet / dinari-mainnet
        if (chainId == 202601) return 40465; // anubis-testnet / anubis-testnet
        if (chainId == 222888) return 40433; // moca-testnet / moca-testnet
        if (chainId == 261131) return 30397; // zama-mainnet / zama-mainnet
        if (chainId == 325000) return 40295; // camp-testnet / camp-testnet
        if (chainId == 421614) return 40231; // Arbitrum Sepolia Testnet / arbsep-testnet
        if (chainId == 432201) return 40118; // Dexalot Subnet Testnet / dexalot-testnet
        if (chainId == 432204) return 30118; // Dexalot Subnet / dexalot-mainnet
        if (chainId == 534351) return 40170; // Scroll Sepolia Testnet / scroll-testnet
        if (chainId == 534352) return 30214; // Scroll / scroll-mainnet
        if (chainId == 560048) return 40449; // hoodi-testnet / hoodi-testnet
        if (chainId == 656476) return 40297; // opencampus-testnet / opencampus-testnet
        if (chainId == 657468) return 40407; // ethereal-testnet / ethereal-testnet
        if (chainId == 660279) return 30236; // xai-mainnet / xai-mainnet
        if (chainId == 685685) return 40454; // gensyn-testnet / gensyn-testnet
        if (chainId == 685689) return 30412; // gensyn-mainnet / gensyn-mainnet
        if (chainId == 686868) return 40264; // merlin-testnet / merlin-testnet
        if (chainId == 688689) return 40436; // atlanticocean-testnet / atlanticocean-testnet
        if (chainId == 710420) return 30238; // tiltyard-mainnet / tiltyard-mainnet
        if (chainId == 713715) return 40258; // sei-testnet / sei-testnet
        if (chainId == 737373) return 40448; // bokuto-testnet / bokuto-testnet
        if (chainId == 743111) return 40338; // hemi-testnet / hemi-testnet
        if (chainId == 747474) return 30375; // katana-mainnet / katana-mainnet
        if (chainId == 763373) return 40358; // ink-testnet / ink-testnet
        if (chainId == 810180) return 30301; // zklink-mainnet / zklink-mainnet
        if (chainId == 810181) return 40283; // zklink-testnet / zklink-testnet
        if (chainId == 978658) return 40348; // treasure-testnet / treasure-testnet
        if (chainId == 996353) return 40357; // bl6-testnet / bl6-testnet
        if (chainId == 1212111) return 40461; // 1money Testnet / onemoney-testnet
        if (chainId == 2019775) return 40445; // jovay-testnet / jovay-testnet
        if (chainId == 2651420) return 40435; // horizen-testnet / horizen-testnet
        if (chainId == 3441006) return 40272; // mantasep-testnet / mantasep-testnet
        if (chainId == 5042002) return 40434; // arc-testnet / arc-testnet
        if (chainId == 5064014) return 30391; // ethereal-mainnet / ethereal-mainnet
        if (chainId == 5151706) return 30197; // loot-mainnet / loot-mainnet
        if (chainId == 6038361) return 40266; // zkastar-testnet / zkastar-testnet
        if (chainId == 6513784) return 40311; // codex-testnet / codex-testnet
        if (chainId == 6985385) return 30382; // humanity-mainnet / humanity-mainnet
        if (chainId == 7080969) return 40410; // humanity-testnet / humanity-testnet
        if (chainId == 7295799) return 40458; // rayls-testnet / rayls-testnet
        if (chainId == 7777777) return 30195; // Zora / zora-mainnet
        if (chainId == 7849306) return 40323; // ozean-testnet / ozean-testnet
        if (chainId == 8101902) return 40277; // olive-testnet / olive-testnet
        if (chainId == 9088912) return 40197; // loot-testnet / loot-testnet
        if (chainId == 11155111) return 40161; // Sepolia / sepolia-testnet
        if (chainId == 11155420) return 40232; // Optimism Sepolia / optsep-testnet
        if (chainId == 11155931) return 40438; // rise-testnet / rise-testnet
        if (chainId == 12227332) return 40457; // neox-testnet / neox-testnet
        if (chainId == 13374202) return 40422; // ethereal2-testnet / ethereal2-testnet
        if (chainId == 21000000) return 30331; // Corn / mp1-mainnet
        if (chainId == 21000001) return 40345; // Corn Testnet / mp1-testnet
        if (chainId == 52085143) return 40330; // ble-testnet / ble-testnet
        if (chainId == 52085144) return 40402; // converge-testnet / converge-testnet
        if (chainId == 54647359) return 40432; // sagaevm-testnet / sagaevm-testnet
        if (chainId == 89346162) return 40319; // reya-testnet / reya-testnet
        if (chainId == 111557560) return 40280; // cyber-testnet / cyber-testnet
        if (chainId == 161221135) return 40304; // plume-testnet / plume-testnet
        if (chainId == 168587773) return 40243; // blast-testnet / blast-testnet
        if (chainId == 531050104) return 40341; // sophon-testnet / sophon-testnet
        if (chainId == 531050204) return 40437; // sophonos-testnet / sophonos-testnet
        if (chainId == 666666666) return 30267; // degen-mainnet / degen-mainnet
        if (chainId == 999999999) return 40249; // zorasep-testnet / zorasep-testnet
        if (chainId == 1313161554) return 30211; // Aurora Mainnet / aurora-mainnet
        if (chainId == 1313161555) return 40201; // Aurora Testnet / aurora-testnet
        if (chainId == 1380012617) return 30235; // Rari Chain / rarible-mainnet
        if (chainId == 1444673419) return 40273; // skale-testnet / skale-testnet
        if (chainId == 1666600000) return 30116; // Harmony / harmony-mainnet
        if (chainId == 1918988905) return 40235; // rarible-testnet / rarible-testnet
        if (chainId == 2046399126) return 30273; // skale-mainnet / skale-mainnet
        if (chainId == 37714555429) return 40251; // xai-testnet / xai-testnet
        if (chainId == 71461164656) return 40331; // bl2-testnet / bl2-testnet
        revert("unknown LZ chainId");
    }

}
