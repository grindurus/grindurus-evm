// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {Grinders} from "../src/Grinders.sol";
import {IGrinders} from "../src/interfaces/IGrinders.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";

contract GrindersTest is GRAIFixture {
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
        grinders.set(cowKind, address(cowImpl));
        grinders.set(lifiKind, address(lifiImpl));
        vm.stopPrank();
    }

    function _registerTestCustodian() internal override {}

    function test_DistributePaysProtocolProfitToOwner() public {
        _setSettlementAsset(address(usdc)); // yieldShare of USDC accrues on GRAI (no auction)

        vm.prank(admin);
        address custodyWallet = grinders.mint(cowKind, address(usdc), address(weth), grinder);

        _deposit(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);
        vm.prank(admin);
        grinders.allocate(custodyWallet, address(usdc), 50e6);

        uint256 graiUsdcBefore = usdc.balanceOf(address(grai));
        vm.prank(grinder);
        CoWCustodian(payable(custodyWallet)).distribute(address(usdc), 20e6);

        assertEq(usdc.balanceOf(admin), 4e6); // 20% treasury
        assertEq(usdc.balanceOf(address(grai)), graiUsdcBefore + 16e6); // 80% settlement
        assertEq(grinders.balance(address(usdc)), 0);
    }

    function test_MintCoWCustodian() public {
        vm.prank(admin);
        CoWCustodian custodyWallet =
            CoWCustodian(payable(grinders.mint(cowKind, address(usdc), address(weth), grinder)));

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grinders()), address(grinders));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), cowKind);
        assertEq(grinders.custodians(0), address(custodyWallet));
        assertEq(grinders.custodianIds(address(custodyWallet)), 0);
        assertEq(grinders.ownerOf(0), grinder);
        assertTrue(grinders.isCustodian(address(custodyWallet)));
        assertFalse(grinders.isCustodian(address(0)));
        assertTrue(grinders.custodianImplementations(cowKind) != address(0));
        assertEq(grinders.totalSupply(), 1);

        string memory uri = grinders.tokenURI(0);
        assertTrue(bytes(uri).length > 100);
        assertEq(bytes(uri)[0], "d"); // data:...
    }

    function test_TokenURI_revertsForUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IGrinders.CustodianNonexistent.selector, 999));
        grinders.tokenURI(999);
    }

    function test_MintLiFiCustodian() public {
        vm.prank(admin);
        LiFiCustodian custodyWallet =
            LiFiCustodian(payable(grinders.mint(lifiKind, address(usdc), address(weth), grinder)));

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grinders()), address(grinders));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), lifiKind);
        assertTrue(grinders.custodianImplementations(lifiKind) != address(0));
    }

    function test_Mint_reusesImplementationPerType() public {
        vm.startPrank(admin);
        grinders.mint(cowKind, address(usdc), address(weth), grinder);
        address cowImpl = grinders.custodianImplementations(cowKind);
        grinders.mint(cowKind, address(usdc), address(weth), bob);

        grinders.mint(lifiKind, address(usdc), address(weth), grinder);
        address lifiImpl = grinders.custodianImplementations(lifiKind);
        grinders.mint(lifiKind, address(usdc), address(weth), bob);
        vm.stopPrank();

        assertEq(grinders.custodianImplementations(cowKind), cowImpl);
        assertEq(grinders.custodianImplementations(lifiKind), lifiImpl);
        assertTrue(cowImpl != lifiImpl);
        assertEq(grinders.totalSupply(), 4);
    }

    function test_Mint_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        grinders.mint(cowKind, address(usdc), address(weth), grinder);
    }

    function test_Mint_revertsUnknownKind() public {
        bytes32 unknownKind = keccak256("grindurus.custodian.unknown");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGrinders.UnknownCustodianKind.selector, unknownKind));
        grinders.mint(unknownKind, address(usdc), address(weth), grinder);
    }

    function test_MintRegistersMultipleCustodians() public {
        vm.startPrank(admin);
        address cow0 = grinders.mint(cowKind, address(usdc), address(weth), grinder);
        address lifi1 = grinders.mint(lifiKind, address(usdc), address(weth), grinder);
        address cow2 = grinders.mint(cowKind, address(usdc), address(weth), bob);
        vm.stopPrank();

        assertEq(grinders.ownerOf(0), grinder);
        assertEq(grinders.ownerOf(1), grinder);
        assertEq(grinders.ownerOf(2), bob);
        assertEq(grinders.custodians(0), cow0);
        assertEq(grinders.custodians(1), lifi1);
        assertEq(grinders.custodians(2), cow2);
        assertEq(grinders.totalSupply(), 3);
    }

    function test_CustodianOwnerFollowsOwnershipTransfer() public {
        vm.prank(admin);
        address custodyAddr = grinders.mint(cowKind, address(usdc), address(weth), grinder);
        CoWCustodian custodyWallet = CoWCustodian(payable(custodyAddr));

        assertEq(custodyWallet.owner(), grinder);

        vm.prank(grinder);
        grinders.transferFrom(grinder, bob, 0);

        assertEq(custodyWallet.owner(), bob);
        assertEq(grinders.ownerOf(0), bob);
    }

    function test_SetCustodianImplementation() public {
        CoWCustodian customImpl = new CoWCustodian();

        vm.prank(admin);
        grinders.set(cowKind, address(customImpl));

        assertEq(grinders.custodianImplementations(cowKind), address(customImpl));
    }

    function test_UpgradePreservesState() public {
        usdc.mint(address(grinders), 10e6);
        vm.deal(address(grinders), 1 ether);

        vm.prank(admin);
        grinders.mint(cowKind, address(usdc), address(weth), grinder);
        address cowImpl = grinders.custodianImplementations(cowKind);

        vm.prank(admin);
        grinders.mint(lifiKind, address(usdc), address(weth), grinder);
        address lifiImpl = grinders.custodianImplementations(lifiKind);

        Grinders implV2 = new Grinders();
        vm.prank(admin);
        grinders.upgradeToAndCall(address(implV2), "");

        assertEq(grinders.custodianImplementations(cowKind), cowImpl);
        assertEq(grinders.custodianImplementations(lifiKind), lifiImpl);
        assertEq(usdc.balanceOf(address(grinders)), 10e6);
        assertEq(address(grinders).balance, 1 ether);
    }
}
