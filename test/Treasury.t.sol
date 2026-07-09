// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAIFixture} from "./GRAIFixture.sol";
import {Treasury} from "../src/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {CoWCustodian} from "../src/custodies/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodies/LiFiCustodian.sol";

contract TreasuryTest is GRAIFixture {
    Treasury treasuryContract;
    address grinder = makeAddr("grinder");
    bytes32 cowKind;
    bytes32 lifiKind;

    function setUp() public override {
        super.setUp();

        Treasury impl = new Treasury();
        treasuryContract = Treasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Treasury.initialize, (grai, admin))
                    )
                )
            )
        );

        vm.startPrank(admin);
        grai.setTreasury(address(treasuryContract));
        CoWCustodian cowImpl = new CoWCustodian();
        LiFiCustodian lifiImpl = new LiFiCustodian();
        cowKind = cowImpl.custodyKind();
        lifiKind = lifiImpl.custodyKind();
        treasuryContract.setCustodyImplementation(cowKind, address(cowImpl));
        treasuryContract.setCustodyImplementation(lifiKind, address(lifiImpl));
        vm.stopPrank();
    }

    function test_ReceivesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(treasuryContract).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(treasuryContract.balance(address(0)), 0.5 ether);
    }

    function test_ReceivesYieldFromDistribute() public {
        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        grai.allocate(address(usdc), custody, 50e6);

        vm.prank(custody);
        usdc.approve(address(grai), 20e6);
        vm.prank(custody);
        grai.distribute(address(usdc), 20e6);

        assertEq(usdc.balanceOf(address(treasuryContract)), 4e6);
    }

    function test_WithdrawERC20() public {
        usdc.mint(address(treasuryContract), 10e6);

        vm.prank(admin);
        treasuryContract.withdraw(address(usdc), alice, 6e6);

        assertEq(usdc.balanceOf(alice), 1_006e6);
        assertEq(usdc.balanceOf(address(treasuryContract)), 4e6);
    }

    function test_WithdrawEth() public {
        vm.deal(address(treasuryContract), 1 ether);

        vm.prank(admin);
        treasuryContract.withdraw(address(0), alice, 0.25 ether);

        assertEq(alice.balance, 0.25 ether);
        assertEq(address(treasuryContract).balance, 0.75 ether);
    }

    function test_MintCoWCustodian() public {
        vm.prank(admin);
        CoWCustodian custodyWallet = CoWCustodian(
            payable(
                treasuryContract.mint(cowKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grai()), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(custodyWallet.treasury(), address(treasuryContract));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodyKind(), cowKind);
        assertEq(treasuryContract.custodians(0), address(custodyWallet));
        assertTrue(treasuryContract.custodyImplementations(cowKind) != address(0));
        assertEq(treasuryContract.ownerOf(0), grinder);
        assertEq(treasuryContract.balanceOf(grinder), 1);
        assertEq(treasuryContract.tokenOfOwnerByIndex(grinder, 0), 0);
        assertEq(treasuryContract.nextCustodianId(), 1);
    }

    function test_MintLiFiCustodian() public {
        vm.prank(admin);
        LiFiCustodian custodyWallet = LiFiCustodian(
            payable(
                treasuryContract.mint(lifiKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grai()), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(custodyWallet.treasury(), address(treasuryContract));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodyKind(), lifiKind);
        assertTrue(treasuryContract.custodyImplementations(lifiKind) != address(0));
    }

    function test_Mint_reusesImplementationPerType() public {
        vm.startPrank(admin);
        treasuryContract.mint(cowKind, grinder, usdc, weth);
        address cowImpl = treasuryContract.custodyImplementations(cowKind);
        treasuryContract.mint(cowKind, bob, usdc, weth);

        treasuryContract.mint(lifiKind, grinder, usdc, weth);
        address lifiImpl = treasuryContract.custodyImplementations(lifiKind);
        treasuryContract.mint(lifiKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(treasuryContract.custodyImplementations(cowKind), cowImpl);
        assertEq(treasuryContract.custodyImplementations(lifiKind), lifiImpl);
        assertTrue(cowImpl != lifiImpl);
    }

    function test_Mint_revertsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        treasuryContract.mint(cowKind, grinder, usdc, weth);
    }

    function test_Mint_revertsUnknownKind() public {
        bytes32 unknownKind = keccak256("grindurus.custodian.unknown");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITreasury.UnknownCustodyKind.selector, unknownKind));
        treasuryContract.mint(unknownKind, grinder, usdc, weth);
    }

    function test_MintEnumerableListsAllGrinderNfts() public {
        vm.startPrank(admin);
        treasuryContract.mint(cowKind, grinder, usdc, weth);
        treasuryContract.mint(lifiKind, grinder, usdc, weth);
        treasuryContract.mint(cowKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(treasuryContract.balanceOf(grinder), 2);
        assertEq(treasuryContract.tokenOfOwnerByIndex(grinder, 0), 0);
        assertEq(treasuryContract.tokenOfOwnerByIndex(grinder, 1), 1);
        assertEq(treasuryContract.ownerOf(2), bob);
    }

    function test_CustodianOwnerFollowsNftTransfer() public {
        vm.prank(admin);
        address custodyAddr = treasuryContract.mint(cowKind, grinder, usdc, weth);
        CoWCustodian custodyWallet = CoWCustodian(payable(custodyAddr));

        assertEq(custodyWallet.owner(), grinder);

        vm.prank(grinder);
        treasuryContract.transferFrom(grinder, bob, 0);

        assertEq(custodyWallet.owner(), bob);
    }

    function test_SetCustodyImplementation() public {
        CoWCustodian customImpl = new CoWCustodian();

        vm.prank(admin);
        treasuryContract.setCustodyImplementation(cowKind, address(customImpl));

        assertEq(treasuryContract.custodyImplementations(cowKind), address(customImpl));
    }

    function test_UpgradePreservesState() public {
        usdc.mint(address(treasuryContract), 10e6);
        vm.deal(address(treasuryContract), 1 ether);

        vm.prank(admin);
        treasuryContract.mint(cowKind, grinder, usdc, weth);
        address cowImpl = treasuryContract.custodyImplementations(cowKind);

        vm.prank(admin);
        treasuryContract.mint(lifiKind, grinder, usdc, weth);
        address lifiImpl = treasuryContract.custodyImplementations(lifiKind);

        Treasury implV2 = new Treasury();
        vm.prank(admin);
        treasuryContract.upgradeToAndCall(address(implV2), "");

        assertEq(address(treasuryContract.grai()), address(grai));
        assertEq(treasuryContract.owner(), admin);
        assertEq(treasuryContract.custodyImplementations(cowKind), cowImpl);
        assertEq(treasuryContract.custodyImplementations(lifiKind), lifiImpl);
        assertEq(usdc.balanceOf(address(treasuryContract)), 10e6);
        assertEq(address(treasuryContract).balance, 1 ether);
    }

    receive() external payable {}
}
