// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAIFixture} from "./GRAIFixture.sol";
import {JuniorToken} from "../src/JuniorToken.sol";
import {IJuniorToken} from "../src/interfaces/IJuniorToken.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";

contract JuniorTokenTest is GRAIFixture {
    JuniorToken juniorTokenContract;
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
        juniorTokenContract.setCustodianImplementation(cowKind, address(cowImpl));
        juniorTokenContract.setCustodianImplementation(lifiKind, address(lifiImpl));
        vm.stopPrank();
    }

    function _wireJuniorToken() internal override {
        JuniorToken impl = new JuniorToken();
        juniorTokenContract = JuniorToken(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(JuniorToken.initialize, (address(grai)))
                    )
                )
            )
        );
        juniorToken = address(juniorTokenContract);
        grai.setJuniorToken(juniorToken);
    }

    function test_ReceivesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(juniorTokenContract).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(juniorTokenContract.balance(address(0)), 0.5 ether);
    }

    function test_DistributePaysProtocolProfitToOwner() public {
        vm.prank(admin);
        address custodyWallet = juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);

        _mint(alice, usdc, 100e6);
        vm.prank(admin);
        juniorTokenContract.allocate(address(usdc), custodyWallet, 50e6);

        vm.prank(grinder);
        CoWCustodian(payable(custodyWallet)).distribute(address(usdc), 20e6);

        assertEq(usdc.balanceOf(admin), 4e6);
        assertEq(usdc.balanceOf(address(juniorTokenContract)), 0);
    }

    function test_MintCoWCustodian() public {
        vm.prank(admin);
        CoWCustodian custodyWallet = CoWCustodian(
            payable(
                juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(custodyWallet.grai(), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(usdc.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(weth.allowance(address(custodyWallet), custodyWallet.COW_VAULT_RELAYER()), type(uint256).max);
        assertEq(custodyWallet.juniorToken(), address(juniorTokenContract));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), cowKind);
        assertEq(juniorTokenContract.custodians(0), address(custodyWallet));
        assertEq(juniorTokenContract.custodianIds(address(custodyWallet)), 0);
        assertEq(juniorTokenContract.custodianOwners(address(custodyWallet)), grinder);
        assertEq(juniorTokenContract.ownerOf(0), grinder);
        assertTrue(juniorTokenContract.isCustodian(address(custodyWallet)));
        assertTrue(juniorTokenContract.custodianImplementations(cowKind) != address(0));
        assertEq(juniorTokenContract.custodianCount(), 1);
        assertEq(juniorTokenContract.name(), "Grinders Junior Token");
        assertEq(juniorTokenContract.symbol(), "JT");

        string memory uri = juniorTokenContract.tokenURI(0);
        assertTrue(bytes(uri).length > 100);
        assertEq(bytes(uri)[0], "d"); // data:...
    }

    function test_TokenURI_revertsForUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IJuniorToken.CustodianNonexistent.selector, 999));
        juniorTokenContract.tokenURI(999);
    }

    function test_MintLiFiCustodian() public {
        vm.prank(admin);
        LiFiCustodian custodyWallet = LiFiCustodian(
            payable(
                juniorTokenContract.mintCustodian(lifiKind, grinder, usdc, weth)
            )
        );

        assertEq(custodyWallet.owner(), grinder);
        assertEq(custodyWallet.grai(), address(grai));
        assertEq(address(custodyWallet.baseAsset()), address(usdc));
        assertEq(address(custodyWallet.quoteAsset()), address(weth));
        assertEq(custodyWallet.juniorToken(), address(juniorTokenContract));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), lifiKind);
        assertTrue(juniorTokenContract.custodianImplementations(lifiKind) != address(0));
    }

    function test_Mint_reusesImplementationPerType() public {
        vm.startPrank(admin);
        juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);
        address cowImpl = juniorTokenContract.custodianImplementations(cowKind);
        juniorTokenContract.mintCustodian(cowKind, bob, usdc, weth);

        juniorTokenContract.mintCustodian(lifiKind, grinder, usdc, weth);
        address lifiImpl = juniorTokenContract.custodianImplementations(lifiKind);
        juniorTokenContract.mintCustodian(lifiKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(juniorTokenContract.custodianImplementations(cowKind), cowImpl);
        assertEq(juniorTokenContract.custodianImplementations(lifiKind), lifiImpl);
        assertTrue(cowImpl != lifiImpl);
        assertEq(juniorTokenContract.custodianCount(), 4);
    }

    function test_Mint_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IJuniorToken.NotAdmin.selector);
        juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);
    }

    function test_Mint_revertsUnknownKind() public {
        bytes32 unknownKind = keccak256("grindurus.custodian.unknown");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IJuniorToken.UnknownCustodianKind.selector, unknownKind));
        juniorTokenContract.mintCustodian(unknownKind, grinder, usdc, weth);
    }

    function test_MintRegistersMultipleCustodians() public {
        vm.startPrank(admin);
        address cow0 = juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);
        address lifi1 = juniorTokenContract.mintCustodian(lifiKind, grinder, usdc, weth);
        address cow2 = juniorTokenContract.mintCustodian(cowKind, bob, usdc, weth);
        vm.stopPrank();

        assertEq(juniorTokenContract.custodianOwners(cow0), grinder);
        assertEq(juniorTokenContract.custodianOwners(lifi1), grinder);
        assertEq(juniorTokenContract.custodianOwners(cow2), bob);
        assertEq(juniorTokenContract.custodianCount(), 3);
    }

    function test_CustodianOwnerFollowsOwnershipTransfer() public {
        vm.prank(admin);
        address custodyAddr = juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);
        CoWCustodian custodyWallet = CoWCustodian(payable(custodyAddr));

        assertEq(custodyWallet.owner(), grinder);

        vm.prank(grinder);
        juniorTokenContract.transferCustodianOwnership(custodyAddr, bob);

        assertEq(custodyWallet.owner(), bob);
        assertEq(juniorTokenContract.custodianOwners(custodyAddr), bob);
        assertEq(juniorTokenContract.ownerOf(0), bob);
    }

    function test_SetCustodianImplementation() public {
        CoWCustodian customImpl = new CoWCustodian();

        vm.prank(admin);
        juniorTokenContract.setCustodianImplementation(cowKind, address(customImpl));

        assertEq(juniorTokenContract.custodianImplementations(cowKind), address(customImpl));
    }

    function test_UpgradePreservesState() public {
        usdc.mint(address(juniorTokenContract), 10e6);
        vm.deal(address(juniorTokenContract), 1 ether);

        vm.prank(admin);
        juniorTokenContract.mintCustodian(cowKind, grinder, usdc, weth);
        address cowImpl = juniorTokenContract.custodianImplementations(cowKind);

        vm.prank(admin);
        juniorTokenContract.mintCustodian(lifiKind, grinder, usdc, weth);
        address lifiImpl = juniorTokenContract.custodianImplementations(lifiKind);

        JuniorToken implV2 = new JuniorToken();
        vm.prank(admin);
        juniorTokenContract.upgradeToAndCall(address(implV2), "");

        assertEq(juniorTokenContract.grai(), address(grai));
        assertEq(juniorTokenContract.custodianImplementations(cowKind), cowImpl);
        assertEq(juniorTokenContract.custodianImplementations(lifiKind), lifiImpl);
        assertEq(usdc.balanceOf(address(juniorTokenContract)), 10e6);
        assertEq(address(juniorTokenContract).balance, 1 ether);
    }

    receive() external payable {}
}
