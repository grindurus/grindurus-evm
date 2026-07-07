// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {CoWCustody, GPv2Order} from "../src/CoWCustody.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";

contract CustodyCowTest is GRAIFixture {
    CoWCustody custodyWallet;

    uint256 ownerKey;
    address owner;

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("custodyOwner");

        CoWCustody impl = new CoWCustody();
        custodyWallet = CoWCustody(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(CoWCustody.initialize, (owner, grai, usdc, weth))
                    )
                )
            )
        );
    }

    function _swapParams(uint32 validTo) internal view returns (CoWCustody.SwapParams memory) {
        return CoWCustody.SwapParams({
            sellToken: usdc,
            buyToken: weth,
            sellAmount: 10e6,
            buyAmount: 1e15,
            validTo: validTo,
            appData: bytes32(0)
        });
    }

    function test_InitializeApprovesVaultRelayer() public view {
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_OrderUid() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        bytes memory uid = custodyWallet.orderUid(_swapParams(validTo));
        assertEq(uid.length, GPv2Order.UID_LENGTH);
    }

    function test_IsValidSignature_acceptsOwner() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        CoWCustody.SwapParams memory params = _swapParams(validTo);
        bytes32 digest = custodyWallet.orderDigest(params);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0x1626ba7e));
    }

    function test_IsValidSignature_rejectsWrongSigner() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        bytes32 digest = custodyWallet.orderDigest(_swapParams(validTo));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("not-owner")), digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_EmergencyWithdrawERC20() public {
        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        grai.allocate(address(usdc), address(custodyWallet), 50e6);

        vm.prank(owner);
        custodyWallet.emergencyWithdraw(address(usdc), 20e6);

        assertEq(usdc.balanceOf(owner), 20e6);
        assertEq(usdc.balanceOf(address(custodyWallet)), 30e6);
    }

    function test_EmergencyWithdrawEther() public {
        vm.deal(address(custodyWallet), 1 ether);

        vm.prank(owner);
        custodyWallet.emergencyWithdraw(address(0), 0.4 ether);

        assertEq(owner.balance, 0.4 ether);
        assertEq(address(custodyWallet).balance, 0.6 ether);
    }

    function test_SetGRAI() public {
        GRAI impl = new GRAI();
        GRAI newGrai = GRAI(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(GRAI.initialize, (admin, address(oracle), treasury))
                    )
                )
            )
        );

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CoWCustody.GraiUpdated(address(newGrai));
        custodyWallet.setGRAI(newGrai);

        assertEq(address(custodyWallet.GRAI()), address(newGrai));
    }

    function test_SetGRAI_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("grai=0"));
        custodyWallet.setGRAI(IGRAI(address(0)));
    }

    function test_SetAssets() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CoWCustody.AssetsUpdated(address(usdc), address(dai));
        custodyWallet.setAssets(usdc, dai);

        assertEq(address(custodyWallet.BASE_ASSET()), address(usdc));
        assertEq(address(custodyWallet.QUOTE_ASSET()), address(dai));
        assertEq(dai.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetAssets_revertsSameAsset() public {
        vm.prank(owner);
        vm.expectRevert(bytes("same asset"));
        custodyWallet.setAssets(usdc, usdc);
    }

    function test_UpgradePreservesState() public {
        CoWCustody implV2 = new CoWCustody();

        vm.prank(owner);
        custodyWallet.upgradeToAndCall(address(implV2), "");

        assertEq(custodyWallet.owner(), owner);
        assertEq(address(custodyWallet.GRAI()), address(grai));
        assertEq(address(custodyWallet.BASE_ASSET()), address(usdc));
        assertEq(address(custodyWallet.QUOTE_ASSET()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetUpgradesDisabled_blocksFutureUpgrade() public {
        vm.prank(owner);
        custodyWallet.setUpgradesDisabled(true);
        assertTrue(custodyWallet.upgradesDisabled());

        CoWCustody implV2 = new CoWCustody();
        vm.prank(owner);
        vm.expectRevert(bytes("disabled"));
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_reenableAfterDelay() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.stopPrank();

        CoWCustody implV2 = new CoWCustody();
        vm.prank(owner);
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_revertsReenableBeforeDelay() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);

        CoWCustody implV2 = new CoWCustody();
        vm.expectRevert(bytes("delay"));
        custodyWallet.upgradeToAndCall(address(implV2), "");
        vm.stopPrank();
    }

    function test_SetUpgradesDisabled_revertsScheduleTwice() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);
        vm.expectRevert(bytes("enabled"));
        custodyWallet.setUpgradesDisabled(false);
        vm.stopPrank();
    }

    function test_SetUpgradesDisabled_cancelReenableSchedule() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);
        custodyWallet.setUpgradesDisabled(true);
        vm.stopPrank();

        assertTrue(custodyWallet.upgradesDisabled());
        assertEq(custodyWallet.upgradesDisableScheduledAt(), type(uint48).max);
    }

    function test_SetEmergencyWithdrawDisabled_blocksWithdraw() public {
        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        grai.allocate(address(usdc), address(custodyWallet), 50e6);

        vm.prank(owner);
        custodyWallet.setEmergencyWithdrawDisabled(true);
        assertTrue(custodyWallet.emergencyWithdrawDisabled());

        vm.prank(owner);
        vm.expectRevert(bytes("disabled"));
        custodyWallet.emergencyWithdraw(address(usdc), 1e6);
    }

    function test_SetEmergencyWithdrawDisabled_reenableAfterDelay() public {
        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        grai.allocate(address(usdc), address(custodyWallet), 50e6);

        vm.startPrank(owner);
        custodyWallet.setEmergencyWithdrawDisabled(true);
        custodyWallet.setEmergencyWithdrawDisabled(false);
        vm.warp(block.timestamp + 24 hours + 1);
        custodyWallet.emergencyWithdraw(address(usdc), 1e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(owner), 1e6);
    }

    function test_SetEmergencyWithdrawDisabled_revertsReenableBeforeDelay() public {
        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        grai.allocate(address(usdc), address(custodyWallet), 50e6);

        vm.startPrank(owner);
        custodyWallet.setEmergencyWithdrawDisabled(true);
        custodyWallet.setEmergencyWithdrawDisabled(false);
        vm.expectRevert(bytes("delay"));
        custodyWallet.emergencyWithdraw(address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_Approve_acceptsTradingAssets() public {
        vm.startPrank(owner);
        custodyWallet.approve(usdc, 1e6);
        custodyWallet.approve(weth, 1e18);
        vm.stopPrank();

        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), 1e6);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), 1e18);
    }

    function test_Approve_revertsOtherToken() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(owner);
        vm.expectRevert(bytes("not trading asset"));
        custodyWallet.approve(dai, 1e18);
    }
}
