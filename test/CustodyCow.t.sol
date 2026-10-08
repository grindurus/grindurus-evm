// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {GRAIFixture} from "./GRAIFixture.sol";
import {CoWCustodian, GPv2Order} from "../src/custodians/CoWCustodian.sol";
import {ICustodian} from "../src/interfaces/ICustodian.sol";

contract CustodyCowTest is GRAIFixture {
    CoWCustodian custodyWallet;

    uint256 ownerKey;
    address owner;

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("custodyOwner");

        CoWCustodian impl = new CoWCustodian();
        custodyWallet = CoWCustodian(
            payable(address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(CoWCustodian.initialize, (address(grinders))))
                ))
        );
        vm.startPrank(admin);
        grinders.register(address(custodyWallet), owner);
        grinders.setAssets(address(custodyWallet), address(usdc), address(weth));
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
        assertEq(address(custodyWallet.grinders()), address(grinders));
        assertEq(address(custodyWallet.grinders()), address(grinders));
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

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit ICustodian.SetAssets(address(usdc), address(dai));
        grinders.setAssets(address(custodyWallet), address(usdc), address(dai));

        assertEq(custodyWallet.baseAsset(), address(usdc));
        assertEq(custodyWallet.quoteAsset(), address(dai));
        assertEq(dai.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
    }

    function test_SetAssets_revertsSameAsset() public {
        vm.prank(admin);
        vm.expectRevert(ICustodian.SameAsset.selector);
        grinders.setAssets(address(custodyWallet), address(usdc), address(usdc));
    }

    function test_SetAssets_revertsNonZeroBalance() public {
        usdc.mint(address(custodyWallet), 1e6);

        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(admin);
        vm.expectRevert(ICustodian.NonZeroBalance.selector);
        grinders.setAssets(address(custodyWallet), address(usdc), address(dai));
    }

    bytes32 private constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPL_SLOT))));
    }

    function test_Upgrade_revertsForNftOwner() public {
        CoWCustodian implV2 = new CoWCustodian();
        bytes32 kind = implV2.label();
        vm.prank(admin);
        grinders.set(kind, address(implV2));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICustodian.NotOwner.selector, owner));
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_Upgrade_revertsUnregisteredImpl() public {
        CoWCustodian implV2 = new CoWCustodian();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICustodian.UnauthorizedImplementation.selector, address(implV2)));
        custodyWallet.upgradeToAndCall(address(implV2), "");
    }

    function test_Upgrade_adminToRegisteredImpl() public {
        address before = _implementation(address(custodyWallet));
        CoWCustodian implV2 = new CoWCustodian();
        bytes32 kind = implV2.label();
        assertTrue(address(implV2) != before);

        vm.startPrank(admin);
        grinders.set(kind, address(implV2));
        custodyWallet.upgradeToAndCall(address(implV2), "");
        vm.stopPrank();

        assertEq(_implementation(address(custodyWallet)), address(implV2));
        assertEq(custodyWallet.baseAsset(), address(usdc));
        assertEq(custodyWallet.quoteAsset(), address(weth));
        assertEq(custodyWallet.label(), kind);
    }

    function test_Upgrade_viaGrindersUpgradeCustodian() public {
        CoWCustodian implV2 = new CoWCustodian();
        bytes32 kind = implV2.label();

        vm.startPrank(admin);
        grinders.set(kind, address(implV2));
        grinders.upgradeCustodian(address(custodyWallet));
        vm.stopPrank();

        assertEq(_implementation(address(custodyWallet)), address(implV2));
    }

    function test_Approve_acceptsTradingAssets() public {
        vm.startPrank(owner);
        custodyWallet.approve(address(usdc), 1e6);
        custodyWallet.approve(address(weth), 1e18);
        vm.stopPrank();

        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), 1e6);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), 1e18);
    }

    function test_Approve_revertsOtherToken() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.prank(owner);
        vm.expectRevert(CoWCustodian.NotTradingAsset.selector);
        custodyWallet.approve(address(dai), 1e18);
    }
}
