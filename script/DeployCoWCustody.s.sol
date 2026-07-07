// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoWCustody} from "../src/CoWCustody.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

/// @title CoWCustody deploy
/// @notice Deploys a UUPS CoWCustody proxy (impl + ERC1967Proxy).
///
/// Required env:
///   PRIVATE_KEY  - deployer key; also becomes CoWCustody owner (EIP-1271 signer)
///   BASE_ASSET     - base token (e.g. USDC), max-approved to CoW VaultRelayer at init
///   QUOTE_ASSET    - quote token (e.g. WETH), max-approved to CoW VaultRelayer at init
///
/// Optional env:
///   GRAI=0x...   - GRAI proxy address (defaults to address(0))
///   DRY_RUN=1    - log params only, skip broadcast
///
/// Deploy:
///   PRIVATE_KEY=0x... GRAI=0x... BASE_ASSET=0x... QUOTE_ASSET=0x... \
///     forge script script/DeployCoWCustody.s.sol:DeployCoWCustody \
///     --rpc-url $RPC_URL --broadcast
contract DeployCoWCustody is Script {
    function run() external returns (CoWCustody custody) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        address grai = vm.envOr("GRAI", address(0));
        address baseAsset = vm.envAddress("BASE_ASSET");
        address quoteAsset = vm.envAddress("QUOTE_ASSET");

        _logConfig(owner, grai, baseAsset, quoteAsset);

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return CoWCustody(payable(address(0)));
        }

        vm.startBroadcast(deployerPrivateKey);

        CoWCustody impl = new CoWCustody();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    CoWCustody.initialize,
                    (owner, IGRAI(grai), IERC20(baseAsset), IERC20(quoteAsset))
                )
            )
        );

        vm.stopBroadcast();

        custody = CoWCustody(payable(proxy));

        require(custody.owner() == owner, "owner mismatch");
        require(address(custody.GRAI()) == grai, "grai mismatch");
        require(address(custody.BASE_ASSET()) == baseAsset, "base mismatch");
        require(address(custody.QUOTE_ASSET()) == quoteAsset, "quote mismatch");
        require(
            IERC20(baseAsset).allowance(proxy, custody.COW_VAULT_RELAYER()) == type(uint256).max, "base allowance"
        );
        require(
            IERC20(quoteAsset).allowance(proxy, custody.COW_VAULT_RELAYER()) == type(uint256).max, "quote allowance"
        );

        console2.log("CoWCustody impl:", address(impl));
        console2.log("CoWCustody proxy:", proxy);
        console2.log("Deploy complete.");
    }

    function _dryRun() internal view returns (bool) {
        try vm.envBool("DRY_RUN") returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    function _logConfig(address owner, address grai, address baseAsset, address quoteAsset) internal pure {
        console2.log("CUSTODY_OWNER (from PRIVATE_KEY):", owner);
        console2.log("GRAI:", grai);
        console2.log("BASE_ASSET:", baseAsset);
        console2.log("QUOTE_ASSET:", quoteAsset);
    }
}

/**

    BASE_ASSET=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 \
    QUOTE_ASSET=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 \
    forge script script/DeployCoWCustody.s.sol:DeployCoWCustody \
    --rpc-url https://rpc.nodeflare.app/arb/public
 
 */