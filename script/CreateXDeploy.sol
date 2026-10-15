// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

/// @dev Minimal CreateX surface for CREATE3 deploys.
/// @notice Canonical factory: https://github.com/pcaversaccio/createx
interface ICreateX {
    struct Values {
        uint256 constructorAmount;
        uint256 initCallAmount;
    }

    function deployCreate3(bytes32 salt, bytes memory initCode)
        external
        payable
        returns (address newContract);

    function deployCreate3AndInit(
        bytes32 salt,
        bytes memory initCode,
        bytes memory data,
        Values memory values
    ) external payable returns (address newContract);

    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

/// @dev CreateX CREATE3 helpers for Foundry scripts.
///
/// Salt layout (CreateX `_guard`):
///   - salt[0:20] = deployer (`PRIVATE_KEY` addr) → only that EOA can use the salt
///   - salt[20]   = `0x00` → same address across chains (no chainId in guarded salt)
///   - salt[21:32]= per-contract id (`uint88`, free to mine for vanity)
///
/// Env: `PRIVATE_KEY` (salt guardian / broadcast sender), optional `CREATEX=`.
abstract contract CreateXDeploy is Script {
    /// @dev Canonical CreateX (same address on supported EVMs).
    address internal constant CREATEX_DEFAULT = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @dev CreateX salt flag: permissioned deployer, same address cross-chain.
    uint8 internal constant CREATE3_FLAG_CROSS_CHAIN_REDEPLOY_OFF = 0x00;

    function _createX() internal view returns (ICreateX) {
        return ICreateX(vm.envOr("CREATEX", CREATEX_DEFAULT));
    }

    function _deployer() internal view returns (address) {
        return vm.addr(vm.envUint("PRIVATE_KEY"));
    }

    function _saltId(string memory label) internal pure returns (uint88) {
        return uint88(uint256(keccak256(bytes(label))));
    }

    /// @dev CreateX permissioned salt: `[deployer | 0x00 | id88]`.
    ///      Must broadcast from `deployer` (`PRIVATE_KEY`) so CreateX `msg.sender` matches.
    function _permissionedSalt(address deployer, uint88 id) internal pure returns (bytes32) {
        return bytes32(
            (uint256(uint160(deployer)) << 96)
                | (uint256(CREATE3_FLAG_CROSS_CHAIN_REDEPLOY_OFF) << 88)
                | uint256(id)
        );
    }

    function _permissionedSalt(address deployer, string memory label) internal pure returns (bytes32) {
        return _permissionedSalt(deployer, _saltId(label));
    }

    /// @dev Mirrors CreateX `_guard` for permissioned + flag `0x00` (address prediction).
    function _guardedSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        require(address(bytes20(salt)) == deployer, "salt deployer mismatch");
        require(bytes1(salt[20]) == bytes1(CREATE3_FLAG_CROSS_CHAIN_REDEPLOY_OFF), "bad salt flag");
        // CreateX `_efficientHash(bytes32(uint160(msg.sender)), salt)` when msg.sender == deployer.
        return keccak256(bytes.concat(bytes32(uint256(uint160(deployer))), salt));
    }

    /// @notice Predict CREATE3 address for salt guardian `deployer` + `id` (pure; no RPC).
    /// @dev `deployer` here is the permissioned salt prefix / CreateX `msg.sender`, not CreateX itself.
    function _predictCreate3(address deployer, uint88 id) internal view returns (address predicted, bytes32 salt) {
        salt = _permissionedSalt(deployer, id);
        predicted = _computeCreate3Address(address(_createX()), _guardedSalt(deployer, salt));
    }

    /// @dev CreateX / Solady CREATE3 address: CREATE2(proxy) then CREATE(nonce=1).
    function _computeCreate3Address(address createX, bytes32 guardedSalt) internal pure returns (address) {
        address proxy;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x00, createX)
            mstore8(0x0b, 0xff)
            mstore(0x20, guardedSalt)
            mstore(
                0x40,
                hex"21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f"
            )
            mstore(0x14, keccak256(0x0b, 0x55))
            mstore(0x40, ptr)
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01)
            proxy := and(keccak256(0x1e, 0x17), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        return proxy;
    }

    /// @notice CREATE3 via CreateX. Salt id from `keccak256(label)` (u88).
    function _deployCreate3(string memory label, bytes memory initCode) internal returns (address) {
        return _deployCreate3(label, _saltId(label), initCode);
    }

    /// @notice CREATE3 via CreateX with an explicit salt id (e.g. vanity-mined).
    function _deployCreate3(string memory label, uint88 id, bytes memory initCode)
        internal
        returns (address deployed)
    {
        address deployer = _deployer();
        (address predicted, bytes32 salt) = _predictCreate3(deployer, id);
        console2.log("CREATE3:", label);
        console2.log("  salt id:", uint256(id));
        console2.log("  predicted:", predicted);

        deployed = _createX().deployCreate3(salt, initCode);
        require(deployed == predicted, "CREATE3 address mismatch");
        require(deployed.code.length > 0, "CREATE3 empty code");
    }
}

/// @dev CreateX deployments at CREATEX_DEFAULT (same address on all listed chains).
///      Source: https://github.com/pcaversaccio/createx/blob/main/deployments/deployments.json
///      Live:   https://createx.rocks/deployments  (199 chains; re-check before deploy)
///
/// chainId | name
///          1 | Ethereum
///         10 | OP (Optimism)
///         25 | Cronos
///         30 | Rootstock
///         31 | Rootstock Testnet
///         40 | Telos
///         41 | Telos Testnet
///         42 | LUKSO
///         50 | XDC Network
///         51 | XDC Network Testnet (Apothem)
///         56 | BNB Smart Chain
///         97 | BNB Smart Chain Testnet
///        100 | Gnosis Chain
///        111 | BOB Sepolia Testnet
///        122 | Fuse Network
///        123 | Fuse Network Testnet (Spark)
///        130 | Unichain
///        137 | Polygon
///        143 | Monad
///        146 | Sonic
///        169 | Manta Pacific
///        195 | X Layer Sepolia Testnet
///        196 | X Layer
///        204 | opBNB
///        232 | Lens
///        239 | TAC
///        250 | Fantom
///        252 | Fraxtal
///        288 | Boba Network
///        300 | ZKsync Era Sepolia Testnet
///        314 | Filecoin
///        324 | ZKsync Era
///        338 | Cronos Testnet
///        360 | Shape
///        369 | PulseChain
///        480 | World Chain
///        545 | EVM on Flow Testnet
///        648 | Endurance
///        747 | EVM on Flow
///        841 | Taraxa
///        842 | Taraxa Testnet
///        919 | Mode Sepolia Testnet
///        943 | PulseChain Testnet (Testnet-V4)
///        988 | Stable
///        995 | 5ireChain
///        997 | 5ireChain Testnet
///        998 | HyperEVM Testnet
///        999 | HyperEVM
///       1088 | Metis Andromeda
///       1101 | Polygon zkEVM
///       1115 | Core Testnet
///       1116 | Core
///       1135 | Lisk
///       1155 | Intuition
///       1284 | Moonbeam
///       1285 | Moonriver
///       1287 | Moonbeam Testnet (Moonbase Alpha)
///       1301 | Unichain Sepolia Testnet
///       1315 | DATA Network Testnet (Aeneid)
///       1328 | Sei Atlantic Testnet
///       1329 | Sei
///       1442 | Polygon Testnet (zkEVM)
///       1514 | DATA Network
///       1625 | Gravity Alpha
///       1740 | Metal L2 Sepolia Testnet
///       1750 | Metal L2
///       1868 | Soneium
///       1890 | LightLink Phoenix
///       1891 | LightLink Testnet (Pegasus)
///       1923 | Swellchain
///       1924 | Swellchain Sepolia Testnet
///       1946 | Soneium Sepolia Testnet (Minato)
///       2020 | Ronin
///       2021 | Ronin Testnet (Saigon)
///       2201 | Stable Sepolia Testnet
///       2222 | Kava
///       2391 | TAC Testnet (Saint Petersburg)
///       2523 | Fraxtal Hoodi Testnet
///       2741 | Abstract
///       2818 | Morph
///       2910 | Morph Hoodi Testnet
///       2911 | HYCHAIN
///       3636 | Botanix Testnet
///       3637 | Botanix
///       3939 | DOS Chain Testnet
///       4002 | Fantom Testnet
///       4114 | Citrea
///       4162 | SX Network
///       4201 | LUKSO Testnet
///       4202 | Lisk Sepolia Testnet
///       4217 | Tempo
///       4326 | MegaETH
///       4352 | MemeCore
///       4663 | Robinhood Chain
///       4689 | IoTeX
///       4690 | IoTeX Testnet
///       4801 | World Chain Sepolia Testnet
///       5000 | Mantle
///       5003 | Mantle Sepolia Testnet
///       5042 | Arc
///       5115 | Citrea Testnet
///       5330 | Superseed
///       5611 | opBNB Testnet
///       6343 | MegaETH Testnet
///       7000 | ZetaChain
///       7001 | ZetaChain Testnet (Athens-3)
///       7700 | Canto
///       7701 | Canto Testnet
///       7897 | Arena-Z
///       7979 | DOS Chain
///       8217 | Kaia
///       8453 | Base
///       9000 | Evmos Testnet
///       9001 | Evmos
///       9745 | Plasma
///       9746 | Plasma Testnet
///       9897 | Arena-Z Sepolia Testnet
///      10143 | Monad Testnet
///      10200 | Gnosis Chain Testnet (Chiado)
///      11011 | Shape Sepolia Testnet
///      11124 | Abstract Sepolia Testnet
///      13371 | Immutable zkEVM
///      13473 | Immutable zkEVM Sepolia Testnet
///      13579 | Intuition Sepolia Testnet
///      17771 | DMD Diamond
///      23294 | Oasis Sapphire
///      23295 | Oasis Sapphire Testnet
///      28882 | Boba Network Sepolia Testnet
///      29112 | HYCHAIN Testnet
///      33111 | ApeChain Sepolia Testnet (Curtis)
///      33139 | ApeChain
///      34443 | Mode
///      37111 | Lens Sepolia Testnet
///      37373 | DMD Diamond Testnet
///      42161 | Arbitrum One
///      42170 | Arbitrum Nova
///      42220 | Celo
///      42431 | Tempo Testnet (Moderato)
///      42793 | Etherlink
///      43111 | Hemi
///      43113 | Avalanche Testnet (Fuji)
///      43114 | Avalanche
///      43522 | MemeCore Testnet (Insectarium)
///      46630 | Robinhood Chain Testnet
///      48898 | Zircuit Sepolia Testnet (Garfield)
///      48900 | Zircuit
///      50104 | Sophon
///      53302 | Superseed Sepolia Testnet
///      57054 | Sonic Testnet (Blaze)
///      57073 | Ink
///      59141 | Linea Sepolia Testnet
///      59144 | Linea
///      59902 | Metis Sepolia Testnet
///      60808 | BOB
///      80002 | Polygon Sepolia Testnet (Amoy)
///      80069 | Berachain Testnet (Bepolia)
///      80094 | Berachain
///      81457 | Blast
///      84532 | Base Sepolia Testnet
///      88882 | Chiliz Testnet (Spicy)
///      88888 | Chiliz
///      98866 | Plume
///      98867 | Plume Sepolia Testnet
///     127823 | Etherlink Testnet (Shadownet)
///     128064 | Tezos X Testnet (Previewnet)
///     167000 | Taiko Alethia
///     167013 | Taiko Hoodi Testnet
///     200810 | Bitlayer Testnet
///     200901 | Bitlayer
///     314159 | Filecoin Testnet (Calibration)
///     421614 | Arbitrum Sepolia Testnet
///     534351 | Scroll Sepolia Testnet
///     534352 | Scroll
///     560048 | Hoodi
///     713715 | Sei Arctic Devnet
///     737373 | Katana Sepolia Testnet (Bokuto)
///     743111 | Hemi Sepolia Testnet
///     747474 | Katana
///     763373 | Ink Sepolia Testnet
///    1440000 | XRPL EVM
///    1449000 | XRPL EVM Testnet
///    2019775 | Jovay Sepolia Testnet
///    3441006 | Manta Pacific Sepolia Testnet
///    5042002 | Arc Testnet
///    5734951 | Jovay
///    7777777 | Zora
///   11142220 | Celo Sepolia Testnet
///   11155111 | Sepolia
///   11155420 | OP (Optimism) Sepolia Testnet
///   21000000 | Corn Maizenet
///   21000001 | Corn Sepolia Testnet
///   79479957 | SX Network Sepolia Testnet (Toronto)
///  168587773 | Blast Sepolia Testnet
///  531050104 | Sophon Sepolia Testnet
///  999999999 | Zora Sepolia Testnet
/// 1313161554 | Aurora
/// 1313161555 | Aurora Testnet
/// 1666600000 | Harmony
/// 1666700000 | Harmony Testnet
