// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GRAIFixture} from "./GRAIFixture.sol";
import {Grinders} from "../src/Grinders.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
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
        _setSettlementAsset(address(usdc));
        vm.startPrank(admin);
        _setYieldSplitFiftyFifty();
        address custodyWallet = grinders.mint(cowKind, grinder, address(usdc), address(weth));
        vm.stopPrank();

        _deposit(alice, usdc, 100e6);
        _fundGrinders(usdc, 50e6);
        vm.prank(admin);
        grinders.allocate(custodyWallet, address(usdc), 50e6);

        uint256 graiUsdcBefore = usdc.balanceOf(address(grai));
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        vm.prank(admin);
        grinders.distribute(custodyWallet, address(usdc), 20e6);

        // No eligible locks → full dividend cut spills to treasury with the treasury cut.
        assertEq(usdc.balanceOf(address(treasury)) - treasuryBefore, 20e6);
        assertEq(usdc.balanceOf(address(grai)), graiUsdcBefore);
        assertEq(grinders.balance(address(usdc)), 0);
    }

    function test_LiquidateTransfersIdleListedAssetsToGrai() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));
        _deposit(alice, usdc, 100e6);
        _fundGrinders(weth, 2e18);

        vm.prank(alice);
        grai.lock(100e6);
        vm.prank(alice);
        grai.vote(100e6);
        vm.warp(block.timestamp + uint256(grinders.grindPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();

        // GRAI.liquidate sweeps Grinders idle + all custodians onto GRAI.
        assertEq(usdc.balanceOf(address(grinders)), 0);
        assertEq(weth.balanceOf(address(grinders)), 0);
        assertEq(usdc.balanceOf(address(grai)), 100e6);
        assertEq(weth.balanceOf(address(grai)), 2e18);
    }

    function test_LiquidateIdleRevertsWhenStillGrinding() public {
        vm.expectRevert(IGrinders.LiquidationNotOpen.selector);
        grinders.liquidate(0, 0);
    }

    function test_LiquidateIdleRevertsWhenStillGrindingEvenIfStale() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));
        _deposit(alice, usdc, 100e6);
        _fundGrinders(weth, 2e18);

        vm.warp(block.timestamp + uint256(grinders.grindPeriod()) + 1);
        assertFalse(grinders.grinding());
        assertFalse(grai.liquidation());
        assertFalse(grinders.liquidation());

        uint256 grindersUsdcBefore = usdc.balanceOf(address(grinders));
        uint256 grindersWethBefore = weth.balanceOf(address(grinders));
        uint256 graiUsdcBefore = usdc.balanceOf(address(grai));
        uint256 graiWethBefore = weth.balanceOf(address(grai));

        vm.expectRevert(IGrinders.LiquidationNotOpen.selector);
        grinders.liquidate(0, 0);

        assertEq(usdc.balanceOf(address(grinders)), grindersUsdcBefore);
        assertEq(weth.balanceOf(address(grinders)), grindersWethBefore);
        assertEq(usdc.balanceOf(address(grai)), graiUsdcBefore);
        assertEq(weth.balanceOf(address(grai)), graiWethBefore);
    }

    function test_Heartbeat_DistributeAllocateDeallocateBump_SetMintDoNot() public {
        vm.startPrank(admin);
        uint48 baseline = grinders.heartbeatAt();
        address custodyWallet = grinders.mint(cowKind, grinder, address(usdc), address(weth));
        assertEq(grinders.heartbeatAt(), baseline, "mint must not bump heartbeat");
        assertTrue(grinders.grinding());

        skip(2 days);
        grinders.set(cowKind, grinders.custodianImplementations(cowKind));
        assertEq(grinders.heartbeatAt(), baseline, "set must not bump heartbeat");

        skip(2 days);
        grinders.mint(cowKind, bob, address(usdc), address(weth));
        assertEq(grinders.heartbeatAt(), baseline, "second mint must not bump heartbeat");

        usdc.mint(address(grinders), 50e6);
        grinders.allocate(custodyWallet, address(usdc), 20e6);
        uint48 afterAllocate = grinders.heartbeatAt();
        assertGt(afterAllocate, baseline);

        skip(2 days);
        grinders.deallocate(custodyWallet, address(usdc), 5e6);
        uint48 afterDeallocate = grinders.heartbeatAt();
        assertGt(afterDeallocate, afterAllocate);

        skip(2 days);
        grinders.distribute(custodyWallet, address(usdc), 5e6);
        uint48 afterDistribute = grinders.heartbeatAt();
        assertGt(afterDistribute, afterDeallocate);
        vm.stopPrank();

        skip(uint256(grinders.grindPeriod()) + 1);
        assertFalse(grinders.grinding());
    }

    function test_GraiLiquidate_RevertsWhileAlive_SucceedsWhenStale() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));
        _deposit(alice, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);
        assertTrue(grai.hasQuorum());
        assertTrue(grinders.grinding());

        vm.expectRevert(IGRAI.GrindersGrinding.selector);
        grai.liquidate();

        vm.warp(block.timestamp + uint256(grinders.grindPeriod()) + 1);
        assertFalse(grinders.grinding());
        vm.prank(admin);
        grai.liquidate();
        assertTrue(grai.liquidation());

        // Keeper paging works without grinding-check once REDEMPTION is open.
        grinders.liquidate(0, type(uint256).max);
        grinders.liquidate(0, 0);
    }

    function test_Revive_AfterStaleLiquidation() public {
        vm.prank(admin);
        grai.setGrinders(address(grinders));
        _deposit(alice, usdc, 100e6);
        vm.prank(alice);
        grai.vote(100e6);

        vm.warp(block.timestamp + uint256(grinders.grindPeriod()) + 1);
        vm.prank(admin);
        grai.liquidate();

        IGRAI.Config memory cfg = _readConfig();
        vm.warp(block.timestamp + uint256(cfg.liquidationPeriod) + uint256(cfg.redeemPeriod));
        grai.revive();
        assertEq(uint8(grai.regime()), uint8(IGRAI.Regime.GRINDING));
    }

    function test_Liquidation_OpenWhenGraiHasNoCode() public {
        address eoa = makeAddr("notGrai");
        vm.prank(admin);
        grinders.setGrai(eoa);
        assertTrue(grinders.liquidation());
    }

    function test_MintCoWCustodian() public {
        vm.prank(admin);
        CoWCustodian custodyWallet =
            CoWCustodian(payable(grinders.mint(cowKind, grinder, address(usdc), address(weth))));

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grinders()), address(grinders));
        assertEq(custodyWallet.baseAsset(), address(usdc));
        assertEq(custodyWallet.quoteAsset(), address(weth));
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
            LiFiCustodian(payable(grinders.mint(lifiKind, grinder, address(usdc), address(weth))));

        assertEq(custodyWallet.owner(), grinder);
        assertEq(address(custodyWallet.grinders()), address(grinders));
        assertEq(custodyWallet.baseAsset(), address(usdc));
        assertEq(custodyWallet.quoteAsset(), address(weth));
        assertEq(custodyWallet.custodianId(), 0);
        assertEq(custodyWallet.custodianKind(), lifiKind);
        assertTrue(grinders.custodianImplementations(lifiKind) != address(0));
    }

    function test_Mint_reusesImplementationPerType() public {
        vm.startPrank(admin);
        grinders.mint(cowKind, grinder, address(usdc), address(weth));
        address cowImpl = grinders.custodianImplementations(cowKind);
        grinders.mint(cowKind, bob, address(usdc), address(weth));

        grinders.mint(lifiKind, grinder, address(usdc), address(weth));
        address lifiImpl = grinders.custodianImplementations(lifiKind);
        grinders.mint(lifiKind, bob, address(usdc), address(weth));
        vm.stopPrank();

        assertEq(grinders.custodianImplementations(cowKind), cowImpl);
        assertEq(grinders.custodianImplementations(lifiKind), lifiImpl);
        assertTrue(cowImpl != lifiImpl);
        assertEq(grinders.totalSupply(), 4);
    }

    function test_Mint_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        grinders.mint(cowKind, grinder, address(usdc), address(weth));
    }

    function test_Mint_revertsUnknownKind() public {
        bytes32 unknownKind = keccak256("grindurus.custodian.unknown");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGrinders.UnknownCustodianKind.selector, unknownKind));
        grinders.mint(unknownKind, grinder, address(usdc), address(weth));
    }

    function test_MintRegistersMultipleCustodians() public {
        vm.startPrank(admin);
        address cow0 = grinders.mint(cowKind, grinder, address(usdc), address(weth));
        address lifi1 = grinders.mint(lifiKind, grinder, address(usdc), address(weth));
        address cow2 = grinders.mint(cowKind, bob, address(usdc), address(weth));
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
        address custodyAddr = grinders.mint(cowKind, grinder, address(usdc), address(weth));
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
        grinders.mint(cowKind, grinder, address(usdc), address(weth));
        address cowImpl = grinders.custodianImplementations(cowKind);

        vm.prank(admin);
        grinders.mint(lifiKind, grinder, address(usdc), address(weth));
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
