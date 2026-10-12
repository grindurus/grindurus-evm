// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAIFixture} from "./GRAIFixture.sol";
import {SwapCustodian} from "../src/custodians/SwapCustodian.sol";

contract MockSwapRouter2 {
    using SafeERC20 for IERC20;

    function sellBaseForQuote(IERC20 base, IERC20 quote, uint256 baseIn, uint256 quoteOut) external {
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransfer(msg.sender, quoteOut);
    }
}

contract CustodySwapCustodianTest is GRAIFixture {
    SwapCustodian custodyWallet;
    MockSwapRouter2 router;

    address owner = makeAddr("custodyOwner");

    uint256 constant SELL_BASE_IN = 10e6;
    uint256 constant SELL_QUOTE_OUT = 5e15;
    uint256 constant SELL_EXEC_PRICE = 5e14;

    function setUp() public override {
        super.setUp();
        router = new MockSwapRouter2();

        SwapCustodian impl = new SwapCustodian();
        custodyWallet = SwapCustodian(
            payable(address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(SwapCustodian.initialize, (address(grinders))))
                ))
        );
        vm.startPrank(admin);
        grinders.register(address(custodyWallet), owner);
        grinders.setAssets(address(custodyWallet), address(usdc), address(weth));
        vm.stopPrank();

        usdc.mint(address(custodyWallet), 100e6);
        weth.mint(address(custodyWallet), 10e18);
        usdc.mint(address(router), 100e6);
        weth.mint(address(router), 10e18);
    }

    function test_label_is_swap_not_cow_or_path() public view {
        assertEq(custodyWallet.labelId(), string.concat("grinder.custodian.swap@eip155:", vm.toString(block.chainid)));
        assertEq(custodyWallet.label(), keccak256(bytes(custodyWallet.labelId())));
    }

    function test_path_swap_works() public {
        bytes memory data = abi.encodeCall(MockSwapRouter2.sellBaseForQuote, (usdc, weth, SELL_BASE_IN, SELL_QUOTE_OUT));
        vm.prank(owner);
        custodyWallet.swap(SELL_EXEC_PRICE - 1, address(router), data);

        assertEq(usdc.balanceOf(address(custodyWallet)), 100e6 - SELL_BASE_IN);
        assertEq(weth.balanceOf(address(custodyWallet)), 10e18 + SELL_QUOTE_OUT);
    }

    function test_cow_surface_present() public view {
        assertTrue(address(custodyWallet.COW_SETTLEMENT()) != address(0));
        assertTrue(custodyWallet.COW_DOMAIN_SEPARATOR() != bytes32(0));
        assertEq(custodyWallet.COW_VAULT_RELAYER(), 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110);
    }

    function test_vault_relayer_approved_on_setAssets() public view {
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }
}
