// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ForkFixture} from "./ForkFixture.sol";
import {AaveV3Custodian, IAToken} from "../../src/custodians/AaveV3Custodian.sol";
import {ICustodian} from "../../src/interfaces/ICustodian.sol";

/// @notice Arbitrum fork: Aave V3 USDC sleeve (standalone grinders = EOA).
contract AaveV3CustodianForkTest is ForkFixture {
    /// Native USDC on Arbitrum One.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// Aave V3 aUSDC (Arbitrum).
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    uint256 internal constant AMOUNT = 1_000e6; // 1_000 USDC

    AaveV3Custodian internal sleeve;
    address internal owner;
    address internal stranger;

    function setUp() public {
        _forkArbitrum();

        owner = makeAddr("aaveOwner");
        stranger = makeAddr("stranger");

        require(IAToken(A_USDC).UNDERLYING_ASSET_ADDRESS() == USDC, "aUSDC underlying");
        require(IAToken(A_USDC).POOL() == AAVE_POOL, "aUSDC pool");

        AaveV3Custodian impl = new AaveV3Custodian();
        sleeve = AaveV3Custodian(
            payable(
                address(new ERC1967Proxy(address(impl), abi.encodeCall(AaveV3Custodian.initialize, (owner))))
            )
        );

        vm.prank(owner);
        sleeve.setAssets(A_USDC, USDC);

        deal(USDC, address(sleeve), AMOUNT);
    }

    function test_setAssets_bindsATokenAndQuote() public view {
        assertEq(sleeve.baseAsset(), A_USDC);
        assertEq(sleeve.quoteAsset(), USDC);
        assertEq(address(sleeve.pool()), AAVE_POOL);
        assertEq(
            sleeve.custodianKind(),
            keccak256("grindurus.custodian.aave_v3")
        );
        assertEq(sleeve.balance(USDC), AMOUNT);
        assertEq(sleeve.balance(A_USDC), 0);
    }

    function test_setAssets_revertsWrongUnderlying() public {
        // Fresh sleeve so balances are zero.
        AaveV3Custodian impl = new AaveV3Custodian();
        AaveV3Custodian fresh = AaveV3Custodian(
            payable(
                address(new ERC1967Proxy(address(impl), abi.encodeCall(AaveV3Custodian.initialize, (owner))))
            )
        );

        vm.prank(owner);
        vm.expectRevert(AaveV3Custodian.ATokenMismatch.selector);
        fresh.setAssets(A_USDC, address(0xdead));
    }

    function test_supply_and_withdraw_usdc() public {
        vm.prank(owner);
        sleeve.supply(AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(sleeve)), 0);
        assertEq(sleeve.balance(USDC), 0);
        uint256 aBal = sleeve.balance(A_USDC);
        assertApproxEqAbs(aBal, AMOUNT, 2); // aToken rounding

        uint256 half = AMOUNT / 2;
        vm.prank(owner);
        uint256 withdrawn = sleeve.withdraw(half);

        assertApproxEqAbs(withdrawn, half, 2);
        assertApproxEqAbs(sleeve.balance(USDC), half, 2);
        assertApproxEqAbs(sleeve.balance(A_USDC) + sleeve.balance(USDC), AMOUNT, 3);

        vm.prank(owner);
        sleeve.withdraw(type(uint256).max);

        assertEq(sleeve.balance(A_USDC), 0);
        assertApproxEqAbs(sleeve.balance(USDC), AMOUNT, 3);
    }

    function test_supply_revertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICustodian.NotOwner.selector, stranger));
        sleeve.supply(AMOUNT);
    }

    function test_deallocate_redeemsATokensWhenIdleShort() public {
        vm.prank(owner);
        sleeve.supply(AMOUNT);
        assertEq(sleeve.balance(USDC), 0);

        uint256 ownerBefore = IERC20(USDC).balanceOf(owner);

        // grinders == owner (standalone); pulls quote while all funds are in aTokens.
        vm.prank(owner);
        sleeve.deallocate(USDC, AMOUNT);

        assertApproxEqAbs(IERC20(USDC).balanceOf(owner) - ownerBefore, AMOUNT, 3);
        assertEq(sleeve.balance(A_USDC), 0);
        assertEq(sleeve.balance(USDC), 0);
    }

    function test_supply_revertsInsufficientIdle() public {
        vm.prank(owner);
        vm.expectRevert(AaveV3Custodian.InsufficientIdle.selector);
        sleeve.supply(AMOUNT + 1);
    }
}
