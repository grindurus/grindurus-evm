// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev CREATE3 via Nick's CREATE2 factory + Solmate-style fixed proxy.
///      Final address depends only on `salt` (and the universal factory), not on init code.
library Create3Factory {
    /// @dev Nick's deterministic deployment proxy — same address on most EVM chains.
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Solmate CREATE3 proxy creation code (deploys a tiny runtime that CREATEs from calldata).
    bytes internal constant PROXY_BYTECODE = hex"67363d3d37363d34f03d5260086018f3";

    /// @dev `keccak256(PROXY_BYTECODE)`.
    bytes32 internal constant PROXY_BYTECODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    error FactoryNotDeployed();
    error ProxyDeployFailed(address proxy);
    error DeployFailed(address expected);

    function isAvailable() internal view returns (bool) {
        return DEPLOYER.code.length > 0;
    }

    /// @notice CREATE3 address for `salt` (independent of creation bytecode).
    function computeAddress(bytes32 salt) internal pure returns (address) {
        return _createAddress(_create2Address(salt));
    }

    /// @notice Intermediate CREATE2 proxy address used by CREATE3.
    function computeProxyAddress(bytes32 salt) internal pure returns (address) {
        return _create2Address(salt);
    }

    function deploy(bytes32 salt, bytes memory creationCode) internal returns (address deployed) {
        if (!isAvailable()) revert FactoryNotDeployed();

        deployed = computeAddress(salt);
        if (deployed.code.length > 0) {
            return deployed;
        }

        address proxy = _create2Address(salt);
        if (proxy.code.length == 0) {
            (bool ok,) = DEPLOYER.call(abi.encodePacked(salt, PROXY_BYTECODE));
            if (!ok || proxy.code.length == 0) revert ProxyDeployFailed(proxy);
        }

        (bool success,) = proxy.call(creationCode);
        if (!success || deployed.code.length == 0) revert DeployFailed(deployed);
    }

    function makeSalt(string memory label, string memory tag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("grindurus/", tag, "/", label));
    }

    function proxyCreationCode(address implementation, bytes memory initData) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));
    }

    function _create2Address(bytes32 salt) private pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), PROXY_BYTECODE_HASH)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, DEPLOYER)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            addr := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev `address(keccak256(rlp([proxy, nonce=1])))` — first CREATE from a fresh proxy.
    function _createAddress(address proxy) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }
}
