// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DumpGrinderArtTest is Test {
    function test_DumpGrinderArt() public {
        address admin = address(0xA11CE);

        GRAI grai = GRAI(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new GRAI()), abi.encodeCall(GRAI.initialize, (admin))
                    )
                )
            )
        );
        Treasury treasury = Treasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new Treasury()),
                        abi.encodeCall(Treasury.initialize, (admin, address(grai)))
                    )
                )
            )
        );

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        CoWCustodian cow = new CoWCustodian();

        vm.startPrank(admin);
        treasury.setCustodyImplementation(cow.custodianKind(), address(cow));
        for (uint256 i; i < 10; ++i) {
            treasury.mint(cow.custodianKind(), admin, usdc, weth);
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.writeFile(
                string.concat("out/bull-tokenuri-", vm.toString(i), ".txt"), treasury.tokenURI(i)
            );
        }
        vm.stopPrank();
    }
}
