// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {Grinders} from "../src/Grinders.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";

contract GrindersCustodianTest is GRAIFixture {
    address grinder = makeAddr("grinder");
    bytes32 cowKind;
    bytes32 lifiKind;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        CoWCustodian cowImpl = new CoWCustodian();
        LiFiCustodian lifiImpl = new LiFiCustodian();
        cowKind = cowImpl.custodianKind();
        lifiKind = lifiImpl.custodianKind();
        grai.setCustodianImplementation(cowKind, address(cowImpl));
        grai.setCustodianImplementation(lifiKind, address(lifiImpl));
        vm.stopPrank();
    }

    function _registerTestCustodian() internal override {}

    function test_DistributePaysProtocolProfitToOwner() public {
        vm.prank(admin);
        address custodyWallet = grai.mint(cowKind, grinder, usdc, weth);

        _mint(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);
        vm.prank(admin);
        grai.allocate(custodyWallet, address(usdc), 50e6);

        vm.prank(grinder);
        CoWCustodian(payable(custodyWallet)).distribute(address(usdc), 20e6);

        assertEq(usdc.balanceOf(admin), 4e6);
        assertEq(grai.balance(address(usdc)), 0);
    }

    function test_MintCoWCustodian() public {
        vm.prank(admin);
        CoWCustodian custodyWallet = CoWCustodian(
            payable(
                grai.mint(cowKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(custodyWallet.grinders(), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), cowKind);
        assertEq(grai.custodians(0), address(custodyWallet));
        assertEq(grai.custodianIds(address(custodyWallet)), 0);
        assertEq(grai.ownerOf(0), grinder);
        assertTrue(grai.isCustodian(address(custodyWallet)));
        assertFalse(grai.isCustodian(address(0)));
        assertTrue(grai.custodianImplementations(cowKind) != address(0));
        assertEq(grai.totalSupply(), 1);

        string memory uri = grai.tokenURI(0);
        assertTrue(bytes(uri).length > 100);
        assertEq(bytes(uri)[0], "d"); // data:...
    }

    function test_TokenURI_revertsForUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IGrinders.CustodianNonexistent.selector, 999));
        grai.tokenURI(999);
    }

    function test_MintLiFiCustodian() public {
        vm.prank(admin);
        LiFiCustodian custodyWallet = LiFiCustodian(
            payable(
                grai.mint(lifiKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(custodyWallet.grinders(), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), lifiKind);
        assertTrue(grai.custodianImplementations(lifiKind) != address(0));
    }

    function test_Mint_reusesImplementationPerType() public {
        vm.startPrank(admin);
        grai.mint(cowKind, grinder, usdc, weth);
        address cowImpl = grai.custodianImplementations(cowKind);
        grai.mint(cowKind, bob, usdc, weth);

        grai.mint(lifiKind, grinder, usdc, weth);
        address lifiImpl = grai.custodianImplementations(lifiKind);
        grai.mint(lifiKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(grai.custodianImplementations(cowKind), cowImpl);
        assertEq(grai.custodianImplementations(lifiKind), lifiImpl);
        assertTrue(cowImpl != lifiImpl);
        assertEq(grai.totalSupply(), 4);
    }

    function test_Mint_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        grai.mint(cowKind, grinder, usdc, weth);
    }

    function test_Mint_revertsUnknownKind() public {
        bytes32 unknownKind = keccak256("grindurus.custodian.unknown");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGrinders.UnknownCustodianKind.selector, unknownKind));
        grai.mint(unknownKind, grinder, usdc, weth);
    }

    function test_MintRegistersMultipleCustodians() public {
        vm.startPrank(admin);
        address cow0 = grai.mint(cowKind, grinder, usdc, weth);
        address lifi1 = grai.mint(lifiKind, grinder, usdc, weth);
        address cow2 = grai.mint(cowKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(grai.ownerOf(0), grinder);
        assertEq(grai.ownerOf(1), grinder);
        assertEq(grai.ownerOf(2), bob);
        assertEq(grai.custodians(0), cow0);
        assertEq(grai.custodians(1), lifi1);
        assertEq(grai.custodians(2), cow2);
        assertEq(grai.totalSupply(), 3);
    }

    function test_CustodianOwnerFollowsOwnershipTransfer() public {
        vm.prank(admin);
        address custodyAddr = grai.mint(cowKind, grinder, usdc, weth);
        CoWCustodian custodyWallet = CoWCustodian(payable(custodyAddr));

        assertEq(custodyWallet.owner(), grinder);

        vm.prank(grinder);
        grai.transferFrom(grinder, bob, 0);

        assertEq(custodyWallet.owner(), bob);
        assertEq(grai.ownerOf(0), bob);
    }

    function test_SetCustodianImplementation() public {
        CoWCustodian customImpl = new CoWCustodian();

        vm.prank(admin);
        grai.setCustodianImplementation(cowKind, address(customImpl));

        assertEq(grai.custodianImplementations(cowKind), address(customImpl));
    }

    function test_UpgradePreservesState() public {
        usdc.mint(address(grai), 10e6);
        vm.deal(address(grai), 1 ether);

        vm.prank(admin);
        grai.mint(cowKind, grinder, usdc, weth);
        address cowImpl = grai.custodianImplementations(cowKind);

        vm.prank(admin);
        grai.mint(lifiKind, grinder, usdc, weth);
        address lifiImpl = grai.custodianImplementations(lifiKind);

        Grinders implV2 = new Grinders();
        vm.prank(admin);
        grai.upgradeToAndCall(address(implV2), "");

        assertEq(grai.custodianImplementations(cowKind), cowImpl);
        assertEq(grai.custodianImplementations(lifiKind), lifiImpl);
        assertEq(usdc.balanceOf(address(grai)), 10e6);
        assertEq(address(grai).balance, 1 ether);
    }
}
