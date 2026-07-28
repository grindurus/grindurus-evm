// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract DumpGrinderArtTest is Test {
    function test_DumpGrinderArt() public {
        address admin = address(0xA11CE);
        MockWETH wethToken = new MockWETH();

        GRAI grai = GRAI(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new GRAI()), abi.encodeCall(GRAI.initialize, (admin, address(wethToken)))
                    )
                )
            )
        );

        Grinders grinders = Grinders(
            payable(address(
                    new ERC1967Proxy(
                        address(new Grinders()), abi.encodeCall(Grinders.initialize, (admin, address(grai)))
                    )
                ))
        );

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        CoWCustodian cow = new CoWCustodian();

        vm.startPrank(admin);
        grinders.set(cow.custodianKind(), address(cow));
        for (uint256 i; i < 10; ++i) {
            grinders.mint(cow.custodianKind(), address(usdc), address(wethToken), admin);
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.writeFile(string.concat("out/bull-tokenuri-", vm.toString(i), ".txt"), grinders.tokenURI(i));
        }
        vm.stopPrank();
    }
}
