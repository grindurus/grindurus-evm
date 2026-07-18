// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAIFixture} from "./GRAIFixture.sol";
import {SwapCustodian} from "../src/custodians/SwapCustodian.sol";
import {Custodian} from "../src/Custodian.sol";

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    function sellBaseForQuote(IERC20 base, IERC20 quote, uint256 baseIn, uint256 quoteOut) external {
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransfer(msg.sender, quoteOut);
    }

    function buyBaseWithQuote(IERC20 base, IERC20 quote, uint256 quoteIn, uint256 baseOut) external {
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        base.safeTransfer(msg.sender, baseOut);
    }

    function alwaysRevert() external pure {
        revert("fail");
    }

    function noop() external pure returns (uint32) {
        return 1;
    }
}

contract CustodySwapTest is GRAIFixture {
    SwapCustodian custodyWallet;
    MockSwapRouter router;

    address owner = makeAddr("custodyOwner");
    address stranger = makeAddr("stranger");

    uint256 constant SELL_BASE_IN = 10e6;
    uint256 constant SELL_QUOTE_OUT = 5e15; // 0.005 WETH per 10 USDC
    uint256 constant SELL_EXEC_PRICE = 5e14; // 0.0005 WETH per 1 USDC, 18 decimals

    uint256 constant BUY_QUOTE_IN = 5e15;
    uint256 constant BUY_BASE_OUT = 10e6;
    uint256 constant BUY_EXEC_PRICE = 5e14;

    function setUp() public override {
        super.setUp();
        router = new MockSwapRouter();

        SwapCustodian impl = new SwapCustodian();
        custodyWallet = SwapCustodian(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            SwapCustodian.initialize, (address(grinders), usdc, weth)
                        )
                    )
                )
            )
        );
        vm.startPrank(admin);
        grinders.register(address(custodyWallet), owner);
        vm.stopPrank();

        usdc.mint(address(custodyWallet), 100e6);
        weth.mint(address(custodyWallet), 10e18);
        usdc.mint(address(router), 100e6);
        weth.mint(address(router), 10e18);
    }

    function test_swap_sellBase_passesLimit() public {
        bytes memory data = abi.encodeCall(
            MockSwapRouter.sellBaseForQuote, (usdc, weth, SELL_BASE_IN, SELL_QUOTE_OUT)
        );
        vm.prank(owner);
        custodyWallet.swap(SELL_EXEC_PRICE - 1, address(router), data);

        assertEq(usdc.balanceOf(address(custodyWallet)), 100e6 - SELL_BASE_IN);
        assertEq(weth.balanceOf(address(custodyWallet)), 10e18 + SELL_QUOTE_OUT);
        assertEq(usdc.allowance(address(custodyWallet), address(router)), 0);
        assertEq(weth.allowance(address(custodyWallet), address(router)), 0);
    }

    function test_swap_sellBase_revertsPriceLimit() public {
        bytes memory data = abi.encodeCall(
            MockSwapRouter.sellBaseForQuote, (usdc, weth, SELL_BASE_IN, SELL_QUOTE_OUT)
        );
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.ExceededPriceLimit.selector);
        custodyWallet.swap(SELL_EXEC_PRICE + 1, address(router), data);
    }

    function test_swap_buyBase_passesLimit() public {
        bytes memory data = abi.encodeCall(
            MockSwapRouter.buyBaseWithQuote, (usdc, weth, BUY_QUOTE_IN, BUY_BASE_OUT)
        );
        vm.prank(owner);
        custodyWallet.swap(BUY_EXEC_PRICE + 1, address(router), data);

        assertEq(usdc.balanceOf(address(custodyWallet)), 100e6 + BUY_BASE_OUT);
        assertEq(weth.balanceOf(address(custodyWallet)), 10e18 - BUY_QUOTE_IN);
    }

    function test_swap_buyBase_revertsPriceLimit() public {
        bytes memory data = abi.encodeCall(
            MockSwapRouter.buyBaseWithQuote, (usdc, weth, BUY_QUOTE_IN, BUY_BASE_OUT)
        );
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.ExceededPriceLimit.selector);
        custodyWallet.swap(BUY_EXEC_PRICE - 1, address(router), data);
    }

    function test_swap_revertsNoTradeWhenBalancesUnchanged() public {
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.NoTrade.selector);
        custodyWallet.swap(0, address(router), abi.encodeCall(MockSwapRouter.noop, ()));
    }

    function test_swap_revertsForNonOwner() public {
        bytes memory data = abi.encodeCall(
            MockSwapRouter.sellBaseForQuote, (usdc, weth, SELL_BASE_IN, SELL_QUOTE_OUT)
        );

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Custodian.NotOwner.selector, stranger));
        custodyWallet.swap(0, address(router), data);
    }

    function test_swap_revertsTargetZero() public {
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.TargetZero.selector);
        custodyWallet.swap(0, address(0), abi.encodeCall(MockSwapRouter.alwaysRevert, ()));
    }

    function test_swap_revertsDataEmpty() public {
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.DataEmpty.selector);
        custodyWallet.swap(0, address(router), "");
    }

    function test_swap_revertsOnTargetFailure() public {
        vm.prank(owner);
        vm.expectRevert(SwapCustodian.SwapFailed.selector);
        custodyWallet.swap(0, address(router), abi.encodeCall(MockSwapRouter.alwaysRevert, ()));
    }
}
