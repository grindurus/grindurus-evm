// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {CoWCustodian, GPv2Order} from "../src/custodians/CoWCustodian.sol";
import {Custodian} from "../src/Custodian.sol";

contract CustodyCowTest is GRAIFixture {
    CoWCustodian custodyWallet;

    uint256 ownerKey;
    address owner;

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("custodyOwner");

        CoWCustodian impl = new CoWCustodian();
        custodyWallet = CoWCustodian(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            CoWCustodian.initialize, (address(grai), usdc, weth)
                        )
                    )
                )
            )
        );
        vm.startPrank(admin);
        grai.register(address(custodyWallet), owner);
        vm.stopPrank();
    }

    function _order(uint32 validTo) internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: usdc,
            buyToken: weth,
            receiver: address(custodyWallet),
            sellAmount: 10e6,
            buyAmount: 1e15,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: keccak256("sell"),
            partiallyFillable: false,
            sellTokenBalance: keccak256("erc20"),
            buyTokenBalance: keccak256("erc20")
        });
    }

    function _orderDigest(GPv2Order.Data memory order) internal view returns (bytes32) {
        return GPv2Order.hash(order, custodyWallet.COW_DOMAIN_SEPARATOR());
    }

    function test_InitializeApprovesVaultRelayer() public view {
        assertEq(custodyWallet.grinders(), address(grai));
        assertEq(custodyWallet.grinders(), address(grai));
        assertEq(custodyWallet.custodianId(), 1);
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_nav_sumsBaseAndQuoteBalances() public {
        usdc.mint(address(custodyWallet), 100e6);
        weth.mint(address(custodyWallet), 1e18);

        assertEq(custodyWallet.nav(), 100e6 + 2000e6);
    }

    function test_IsValidSignature_acceptsOwner() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        GPv2Order.Data memory order = _order(validTo);
        bytes32 digest = _orderDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encode(abi.encodePacked(r, s, v), order);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0x1626ba7e));
    }

    function test_IsValidSignature_rejectsBareEcdsa() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        GPv2Order.Data memory order = _order(validTo);
        bytes32 digest = _orderDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_IsValidSignature_rejectsWrongSigner() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        GPv2Order.Data memory order = _order(validTo);
        bytes32 digest = _orderDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("not-owner")), digest);
        bytes memory sig = abi.encode(abi.encodePacked(r, s, v), order);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_IsValidSignature_rejectsWrongReceiver() public view {
        uint32 validTo = uint32(block.timestamp + 120);
        GPv2Order.Data memory order = _order(validTo);

        GPv2Order.Data memory maliciousOrder = GPv2Order.Data({
            sellToken: order.sellToken,
            buyToken: order.buyToken,
            receiver: owner,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: validTo,
            appData: order.appData,
            feeAmount: 0,
            kind: keccak256("sell"),
            partiallyFillable: false,
            sellTokenBalance: keccak256("erc20"),
            buyTokenBalance: keccak256("erc20")
        });
        bytes32 digest = GPv2Order.hash(maliciousOrder, custodyWallet.COW_DOMAIN_SEPARATOR());

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encode(abi.encodePacked(r, s, v), order);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_IsValidSignature_rejectsOtherToken() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        uint32 validTo = uint32(block.timestamp + 120);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: dai,
            buyToken: weth,
            receiver: address(custodyWallet),
            sellAmount: 10e18,
            buyAmount: 1e15,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: keccak256("sell"),
            partiallyFillable: false,
            sellTokenBalance: keccak256("erc20"),
            buyTokenBalance: keccak256("erc20")
        });
        bytes32 digest = _orderDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encode(abi.encodePacked(r, s, v), order);

        assertEq(custodyWallet.isValidSignature(digest, sig), bytes4(0xffffffff));
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
        assertEq(custodyWallet.grinders(), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetUpgradesDisabled_blocksFutureUpgrade() public {
        vm.prank(owner);
        custodyWallet.toggleUpgradeable();
        assertTrue(custodyWallet.isUpgradeableDisabled());

        CoWCustodian implV2 = new CoWCustodian();
        vm.prank(owner);
        vm.expectRevert(Custodian.FeatureDisabled.selector);
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_reenableAfterDelay() public {
        vm.startPrank(owner);
        custodyWallet.toggleUpgradeable();
        custodyWallet.toggleUpgradeable();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.stopPrank();

        CoWCustodian implV2 = new CoWCustodian();
        vm.prank(owner);
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_SetUpgradesDisabled_revertsReenableBeforeDelay() public {
        vm.startPrank(owner);
        custodyWallet.toggleUpgradeable();
        custodyWallet.toggleUpgradeable();

        CoWCustodian implV2 = new CoWCustodian();
        vm.expectRevert(Custodian.FeatureDelay.selector);
        custodyWallet.upgradeToAndCall(address(implV2), "");
        vm.stopPrank();
    }

    function test_toggleUpgradeable_locksDuringPendingUnlock() public {
        vm.startPrank(owner);
        custodyWallet.toggleUpgradeable();
        custodyWallet.toggleUpgradeable();
        custodyWallet.toggleUpgradeable();
        vm.stopPrank();

        assertTrue(custodyWallet.isUpgradeableDisabled());
        assertEq(custodyWallet.upgradesDisableScheduledAt(), type(uint48).max);
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
