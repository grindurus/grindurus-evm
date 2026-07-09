// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoWCustodian} from "../src/custodies/CoWCustodian.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {MockTreasuryNFT} from "../test/mocks/MockTreasuryNFT.sol";

/// @title CoWCustodian deploy
/// @notice Deploys a UUPS CoWCustodian proxy (impl + ERC1967Proxy).
///
/// Required env:
///   PRIVATE_KEY  - deployer key; also becomes CoWCustodian owner (EIP-1271 signer)
///   BASE_ASSET     - base token (e.g. USDC), max-approved to CoW VaultRelayer at init
///   QUOTE_ASSET    - quote token (e.g. WETH), max-approved to CoW VaultRelayer at init
///
/// Optional env:
///   GRAI=0x...   - GRAI proxy address (defaults to address(0))
///   TREASURY=0x... - Treasury ERC721 registry (defaults to a local MockTreasuryNFT)
///   DRY_RUN=1    - log params only, skip broadcast
///
/// Deploy:
///   PRIVATE_KEY=0x... GRAI=0x... BASE_ASSET=0x... QUOTE_ASSET=0x... \
///     forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
///     --rpc-url $RPC_URL --broadcast
contract DeployCoWCustodian is Script {
    function run() external returns (CoWCustodian custody) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        address grai = vm.envOr("GRAI", address(0));
        address baseAsset = vm.envAddress("BASE_ASSET");
        address quoteAsset = vm.envAddress("QUOTE_ASSET");
        address treasury = vm.envOr("TREASURY", address(0));
        uint256 custodianId = vm.envOr("CUSTODIAN_ID", uint256(0));

        if (treasury == address(0)) {
            MockTreasuryNFT mockTreasury = new MockTreasuryNFT();
            mockTreasury.setGrai(IGRAI(grai));
            mockTreasury.setOwner(custodianId, owner);
            treasury = address(mockTreasury);
        }

        _logConfig(owner, grai, baseAsset, quoteAsset, treasury, custodianId);

        if (_dryRun()) {
            console2.log("DRY_RUN=1 - skipping broadcast");
            return CoWCustodian(payable(address(0)));
        }

        vm.startBroadcast(deployerPrivateKey);

        CoWCustodian impl = new CoWCustodian();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    CoWCustodian.initialize,
                    (treasury, custodianId, IERC20(baseAsset), IERC20(quoteAsset))
                )
            )
        );

        vm.stopBroadcast();

        custody = CoWCustodian(payable(proxy));

        require(custody.owner() == owner, "owner mismatch");
        require(address(custody.grai()) == address(ITreasury(treasury).grai()), "grai mismatch");
        require(address(custody.baseAsset()) == baseAsset, "base mismatch");
        require(address(custody.quoteAsset()) == quoteAsset, "quote mismatch");
        require(custody.treasury() == treasury, "treasury mismatch");
        require(custody.custodianId() == custodianId, "custodian id mismatch");
        require(
            IERC20(baseAsset).allowance(proxy, custody.COW_VAULT_RELAYER()) == type(uint256).max, "base allowance"
        );
        require(
            IERC20(quoteAsset).allowance(proxy, custody.COW_VAULT_RELAYER()) == type(uint256).max, "quote allowance"
        );

        console2.log("CoWCustodian impl:", address(impl));
        console2.log("CoWCustodian proxy:", proxy);
        console2.log("Deploy complete.");
    }

    function _dryRun() internal view returns (bool) {
        try vm.envBool("DRY_RUN") returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    function _logConfig(
        address owner,
        address grai,
        address baseAsset,
        address quoteAsset,
        address treasury,
        uint256 custodianId
    ) internal pure {
        console2.log("CUSTODY_OWNER (from PRIVATE_KEY):", owner);
        console2.log("GRAI:", grai);
        console2.log("BASE_ASSET:", baseAsset);
        console2.log("QUOTE_ASSET:", quoteAsset);
        console2.log("TREASURY:", treasury);
        console2.log("CUSTODIAN_ID:", custodianId);
    }
}

/**

    export ARBISCAN_API_KEY=...   # https://arbiscan.io/myapikey
    export ARBITRUM_RPC_URL=https://rpc.nodeflare.app/arb/public

    BASE_ASSET=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 \
    QUOTE_ASSET=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 \
    forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
    --rpc-url arbitrum --broadcast --verify --chain arbitrum
 
 */