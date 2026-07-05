// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {PriceOracleRouter} from "../src/PriceOracleRouter.sol";

/// Usage:
///   ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL --broadcast
///
/// Then register each asset feed on the oracle router, then add it to GRAI:
///   - Chainlink (mainnet):
///       oracle.addChainlinkFeed(USDC, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
///       grai.addAsset(USDC);
///   - Pyth (any network):
///       oracle.addPythFeed(WETH, PYTH, WETH_USD_ID);
///       grai.addAsset(WETH);
///   - Custom:
///       oracle.addCustomFeed(TOKEN, 8, oracleSigner);
///       grai.addAsset(TOKEN);
contract Deploy is Script {
    function run() external returns (GRAI grai, PriceOracleRouter oracle) {
        address admin = vm.envOr("ADMIN", msg.sender);
        address treasury = vm.envOr("TREASURY", admin);

        vm.startBroadcast();

        PriceOracleRouter oracleImpl = new PriceOracleRouter();
        oracle = PriceOracleRouter(
            address(
                new ERC1967Proxy(address(oracleImpl), abi.encodeCall(PriceOracleRouter.initialize, (admin)))
            )
        );

        GRAI impl = new GRAI();
        grai = GRAI(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(GRAI.initialize, (admin, address(oracle), treasury))
                )
            )
        );

        vm.stopBroadcast();

        console2.log("GRAI proxy:", address(grai));
        console2.log("SeniorVault:", address(grai.seniorVault()));
        console2.log("JuniorVault:", address(grai.juniorVault()));
        console2.log("PriceOracleRouter proxy:", address(oracle));
    }
}
