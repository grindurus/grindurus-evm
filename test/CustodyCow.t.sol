// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {CoWCustodian, GPv2Order} from "../src/custodies/CoWCustodian.sol";
import {Custodian} from "../src/Custodian.sol";

contract CustodyCowTest is GRAIFixture {
    CoWCustodian custodyWallet;

    uint256 ownerKey;
    address owner;

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("custodyOwner");

        treasuryNft.setOwner(1, owner);

        CoWCustodian impl = new CoWCustodian();
        custodyWallet = CoWCustodian(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            CoWCustodian.initialize, (address(treasuryNft), 1, usdc, weth)
                        )
                    )
                )
            )
        );
        treasuryNft.setCustodian(address(custodyWallet), 1);
    }

    function _swapParams(uint32 validTo) internal view returns (CoWCustodian.SwapParams memory) {
        return CoWCustodian.SwapParams({
            sellToken: usdc,
            buyToken: weth,
            sellAmount: 10e6,
            buyAmount: 1e15,
            validTo: validTo,
            appData: bytes32(0)
        });
    }

    function test_InitializeApprovesVaultRelayer() public view {
        assertEq(custodyWallet.treasury(), address(treasuryNft));
        assertEq(address(custodyWallet.grai()), address(grai));
        assertEq(custodyWallet.custodianId(), 1);
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
        CoWCustodian.SwapParams memory params = _swapParams(validTo);
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

    function test_SetAssets() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Custodian.AssetsUpdated(address(usdc), address(dai));
        custodyWallet.setAssets(usdc, dai);

        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(dai));
        assertEq(dai.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetAssets_revertsSameAsset() public {
        vm.prank(owner);
        vm.expectRevert(Custodian.SameAsset.selector);
        custodyWallet.setAssets(usdc, usdc);
    }

    function test_SetAssets_revertsNonZeroBalance() public {
        usdc.mint(address(custodyWallet), 1e6);

        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(owner);
        vm.expectRevert(Custodian.NonZeroBalance.selector);
        custodyWallet.setAssets(usdc, dai);
    }

    function test_UpgradePreservesState() public {
        CoWCustodian implV2 = new CoWCustodian();

        vm.prank(owner);
        custodyWallet.upgradeToAndCall(address(implV2), "");

        assertEq(custodyWallet.owner(), owner);
        assertEq(address(custodyWallet.grai()), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetUpgradesDisabled_blocksFutureUpgrade() public {
        vm.prank(owner);
        custodyWallet.setUpgradesDisabled(true);
        assertTrue(custodyWallet.upgradesDisabled());

        CoWCustodian implV2 = new CoWCustodian();
        vm.prank(owner);
        vm.expectRevert(Custodian.FeatureDisabled.selector);
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_reenableAfterDelay() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.stopPrank();

        CoWCustodian implV2 = new CoWCustodian();
        vm.prank(owner);
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_revertsReenableBeforeDelay() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);

        CoWCustodian implV2 = new CoWCustodian();
        vm.expectRevert(Custodian.FeatureDelay.selector);
        custodyWallet.upgradeToAndCall(address(implV2), "");
        vm.stopPrank();
    }

    function test_SetUpgradesDisabled_revertsScheduleTwice() public {
        vm.startPrank(owner);
        custodyWallet.setUpgradesDisabled(true);
        custodyWallet.setUpgradesDisabled(false);
        vm.expectRevert(Custodian.FeatureEnabled.selector);
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
        vm.expectRevert(Custodian.FeatureDisabled.selector);
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
        vm.expectRevert(Custodian.FeatureDelay.selector);
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
        vm.expectRevert(CoWCustodian.NotTradingAsset.selector);
        custodyWallet.approve(dai, 1e18);
    }
}
