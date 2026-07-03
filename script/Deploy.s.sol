// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {GRAIVault} from "../src/GRAIVault.sol";
import {PriceOracleRouter} from "../src/PriceOracleRouter.sol";
import {PythPriceFeed} from "../src/PythPriceFeed.sol";
import {SeniorVault} from "../src/SeniorVault.sol";
import {JuniorVault} from "../src/JuniorVault.sol";

/// Usage:
///   ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL --broadcast
///
/// Then register each asset with a feed that implements AggregatorV3Interface:
///   - Chainlink (mainnet):
///       vault.addAsset(USDC, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6 /* USDC/USD */);
///   - Pyth (any network): deploy a per-asset adapter, then register it:
///       address feed = deployer.deployPythFeed(PYTH, USDC_USD_ID, "USDC/USD");
///       vault.addAsset(USDC, feed);
contract Deploy is Script {
    function deployPythFeed(address pyth, bytes32 priceId, string memory description)
        public
        returns (PythPriceFeed feed)
    {
        feed = new PythPriceFeed(pyth, priceId, description);
    }

    function run() external returns (GRAI grai, GRAIVault vault, PriceOracleRouter oracle) {
        address admin = vm.envOr("ADMIN", msg.sender);
        address treasury = vm.envOr("TREASURY", admin);

        vm.startBroadcast();

        // 1. tranche templates (cloned per asset in addAsset)
        address seniorImpl = address(new SeniorVault());
        address juniorImpl = address(new JuniorVault());

        // 2. oracle router
        oracle = new PriceOracleRouter();

        // 3. GRAI token (UUPS proxy)
        GRAI tokenImpl = new GRAI();
        grai = GRAI(address(new ERC1967Proxy(address(tokenImpl), abi.encodeCall(GRAI.initialize, (admin)))));

        // 4. GRAI vault (UUPS proxy)
        GRAIVault vaultImpl = new GRAIVault();
        vault = GRAIVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        GRAIVault.initialize, (admin, address(grai), address(oracle), seniorImpl, juniorImpl, treasury)
                    )
                )
            )
        );

        // 5. vault becomes the GRAI minter
        grai.grantRole(grai.MINTER_ROLE(), address(vault));

        vm.stopBroadcast();

        console2.log("GRAI proxy:", address(grai));
        console2.log("GRAIVault proxy:", address(vault));
        console2.log("PriceOracleRouter:", address(oracle));
        console2.log("SeniorVault impl:", seniorImpl);
        console2.log("JuniorVault impl:", juniorImpl);
    }
}
