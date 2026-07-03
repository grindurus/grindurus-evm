// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Base fixture for live-network fork tests.
///
/// Forks are created against public RPC endpoints by default. Override them by
/// exporting your own (faster / higher rate-limit) endpoints before running:
///
///     export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<key>"
///     export ARBITRUM_RPC_URL="https://arb-mainnet.g.alchemy.com/v2/<key>"
///     forge test --match-path "test/fork/*"
abstract contract ForkFixture is Test {
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;

    string internal constant DEFAULT_ETH_RPC = "https://ethereum-rpc.publicnode.com";
    string internal constant DEFAULT_ARBITRUM_RPC = "https://arbitrum-one-rpc.publicnode.com";

    function _ethRpc() internal view returns (string memory) {
        return vm.envOr("ETH_RPC_URL", DEFAULT_ETH_RPC);
    }

    function _arbitrumRpc() internal view returns (string memory) {
        return vm.envOr("ARBITRUM_RPC_URL", DEFAULT_ARBITRUM_RPC);
    }

    function _forkEthereum() internal returns (uint256 forkId) {
        forkId = vm.createSelectFork(_ethRpc());
        assertEq(block.chainid, ETHEREUM_CHAIN_ID, "expected ethereum mainnet fork");
    }

    function _forkArbitrum() internal returns (uint256 forkId) {
        forkId = vm.createSelectFork(_arbitrumRpc());
        assertEq(block.chainid, ARBITRUM_CHAIN_ID, "expected arbitrum one fork");
    }
}
