// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {GRS} from "../src/GRS.sol";
import {IGRS} from "../src/interfaces/IGRS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

uint32 constant HOME_EID = 30101;
uint32 constant SPOKE_EID = 30110;
uint256 constant MOCK_LZ_FEE = 0.01 ether;

contract MockLzEndpoint {
    mapping(address => address) public delegates;
    uint256 public constant quoteNative = MOCK_LZ_FEE;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: MOCK_LZ_FEE, lzTokenFee: 0});
    }

    function send(MessagingParams calldata, address refund) external payable returns (MessagingReceipt memory) {
        MessagingFee memory fee = MessagingFee({nativeFee: MOCK_LZ_FEE, lzTokenFee: 0});
        if (msg.value < fee.nativeFee) revert();
        uint256 extra = msg.value - fee.nativeFee;
        if (extra > 0) {
            (bool ok,) = payable(refund).call{value: extra}("");
            require(ok);
        }
        return MessagingReceipt({guid: bytes32(uint256(1)), nonce: 1, fee: fee});
    }
}

contract GRSAllocTest is Test {
    MockLzEndpoint internal endpoint;
    address internal admin = address(0xA11CE);
    GRS internal grs;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        grs = new GRS(address(endpoint), admin, true);
    }

    function _q(address token) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function test_AllocationsSumToCap() public view {
        IGRS.Allocation[] memory rows = grs.getAllocations();
        assertEq(rows.length, 11);
        uint256 cap;
        uint256 left;
        for (uint256 i; i < rows.length; ++i) {
            cap += rows[i].cap;
            left += rows[i].remaining;
            assertEq(rows[i].spent, 0);
            assertEq(rows[i].remaining, rows[i].cap);
        }
        assertEq(cap, 1_000_000_000e18);
        assertEq(left, 1_000_000_000e18);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18);
    }

    function test_GrantInstantDebitsBucket() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 150_000_000e18, 0, 0, 0, 0);

        assertEq(grs.spent(IGRS.Bucket.TokenSales), 150_000_000e18);
        assertEq(grs.remaining(IGRS.Bucket.TokenSales), 0);
        assertEq(grs.balanceOf(admin), 150_000_000e18);
        assertEq(grs.balanceOf(address(grs)), 850_000_000e18);

        vm.prank(admin);
        vm.expectRevert(IGRS.BucketExceeded.selector);
        grs.grant(IGRS.Bucket.TokenSales, admin, 1, 0, 0, 0, 0);
    }

    function test_GrantVestingCliffThenLinear() public {
        address alice = address(0xB0B);
        uint64 month = 30 days;
        uint64 start = uint64(block.timestamp);
        vm.prank(admin);
        uint256 id = grs.grant(IGRS.Bucket.CoreTeam, alice, 12e18, start, 12 * month, 60 * month, 0);

        assertEq(id, 1);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18);
        assertEq(grs.releasable(id), 0);

        vm.warp(start + 12 * month);
        assertEq(grs.releasable(id), 0);

        vm.warp(start + 12 * month + 1);
        assertGt(grs.releasable(id), 0);

        vm.warp(start + 72 * month);
        assertEq(grs.releasable(id), 12e18);
        grs.release(id);
        assertEq(grs.balanceOf(alice), 12e18);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18 - 12e18);

        IGRS.Vesting[] memory recs = grs.getVestings(0, 10);
        assertEq(recs.length, 1);
        assertEq(recs[0].id, id);
        assertEq(recs[0].beneficiary, alice);
        assertEq(recs[0].funder, address(grs));
        assertEq(recs[0].released, 12e18);
        assertEq(uint8(recs[0].bucket), uint8(IGRS.Bucket.CoreTeam));
    }

    function test_GetVestingsPaginates() public {
        vm.startPrank(admin);
        grs.grant(IGRS.Bucket.CoreTeam, admin, 1e18, uint64(block.timestamp), 0, 30 days, 0);
        grs.grant(IGRS.Bucket.CoreTeam, admin, 2e18, uint64(block.timestamp), 0, 30 days, 0);
        grs.grant(IGRS.Bucket.CoreTeam, admin, 3e18, uint64(block.timestamp), 0, 30 days, 0);
        vm.stopPrank();

        IGRS.Vesting[] memory page = grs.getVestings(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].id, 2);
        assertEq(page[0].allocation, 2e18);

        page = grs.getVestings(2, 10);
        assertEq(page.length, 1);
        assertEq(page[0].id, 3);

        assertEq(grs.getVestings(3, 1).length, 0);
        assertEq(grs.getVestings(0, 0).length, 0);
        assertEq(grs.vestingCount(), 3);
    }

    function test_VoteGatedNeedsProprietorOnceSet() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.GrowthFund, admin, 1e18, 0, 0, 0, 0);

        address prop = address(0x60);
        vm.prank(admin);
        grs.setProprietor(prop);

        vm.prank(admin);
        vm.expectRevert(IGRS.ProprietorGated.selector);
        grs.grant(IGRS.Bucket.GrowthFund, admin, 1e18, 0, 0, 0, 0);

        vm.prank(prop);
        grs.grant(IGRS.Bucket.Audits, admin, 2e18, 0, 0, 0, 0);
        assertEq(grs.spent(IGRS.Bucket.Audits), 2e18);
    }

    function test_SpokeCannotGrant() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        vm.prank(admin);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.grant(IGRS.Bucket.TokenSales, admin, 1e18, 0, 0, 0, 0);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.getAllocations();
    }

    function test_HolderCanVestOwnTokens() public {
        address bob = address(0xB0B);
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, bob, 10e18, 0, 0, 0, 0);

        uint64 start = uint64(block.timestamp);
        vm.prank(bob);
        uint256 id = grs.vest(bob, 10e18, start, 0, 30 days);

        assertEq(grs.balanceOf(bob), 0);
        assertEq(uint8(grs.getVestings(0, 1)[0].bucket), uint8(IGRS.Bucket.Holder));
        assertEq(grs.getVestings(0, 1)[0].funder, bob);
        assertEq(grs.spent(IGRS.Bucket.TokenSales), 10e18);

        vm.warp(start + 30 days);
        grs.release(id);
        assertEq(grs.balanceOf(bob), 10e18);
    }

    function test_VestRejectsInstant() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 1e18, 0, 0, 0, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InstantNotVest.selector);
        grs.vest(admin, 1e18, 0, 0, 0);
    }

    function test_VestRejectsTooLongCliffOrUnlock() public {
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 2e18, 0, 0, 0, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidSchedule.selector);
        grs.vest(admin, 1e18, 0, 365 days + 1, 0);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidSchedule.selector);
        grs.vest(admin, 1e18, 0, 0, 4 * 365 days + 1);
        vm.prank(admin);
        grs.vest(admin, 1e18, 0, 365 days, 4 * 365 days);
    }

    function test_SpokeHolderCanVest() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        deal(address(spoke), admin, 5e18);
        vm.prank(admin);
        uint256 id = spoke.vest(admin, 5e18, uint64(block.timestamp), 0, 7 days);
        assertEq(id, 1);
        assertEq(spoke.balanceOf(admin), 0);
        assertEq(spoke.balanceOf(address(spoke)), 5e18);
        assertEq(spoke.getVestings(0, 1)[0].funder, admin);
    }

    function test_GrantCannotUseHolderBucket() public {
        vm.prank(admin);
        vm.expectRevert(IGRS.BucketExceeded.selector);
        grs.grant(IGRS.Bucket.Holder, admin, 1e18, 0, 0, 0, 0);
    }

    function test_SetVeGRS() public {
        address vault = address(0x7E);
        vm.prank(admin);
        grs.setVeGRS(vault);
        assertEq(grs.veGRS(), vault);

        GRS spoke = new GRS(address(endpoint), admin, false);
        vm.prank(admin);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.setVeGRS(vault);
    }

    function test_SchedulesMatchSvg() public view {
        (uint32 c, uint32 d) = grs.scheduleOf(IGRS.Bucket.PreSeed);
        assertEq(c, 0);
        assertEq(d, 24);
        (c, d) = grs.scheduleOf(IGRS.Bucket.Advisors);
        assertEq(c, 6);
        assertEq(d, 66);
        assertEq(uint8(grs.gateOf(IGRS.Bucket.LpMm)), uint8(IGRS.Gate.Proprietary));
        assertEq(uint8(grs.gateOf(IGRS.Bucket.Legal)), uint8(IGRS.Gate.VoteGated));
    }

    function test_BuyEthFromTokenSales() public {
        uint256 assetAmount = 0.1 ether;
        vm.prank(admin);
        uint256 id = grs.sale(bytes32(0), assetAmount, address(0), 10e18, 0);

        address buyer = address(0xB1E);
        uint256 amount = 10e18;
        uint256 cost = grs.quoteSale(id, amount);
        assertEq(cost, assetAmount);
        deal(buyer, cost);

        uint256 adminBefore = admin.balance;
        vm.prank(buyer);
        grs.buy{value: cost}(id, amount, buyer);

        assertEq(grs.balanceOf(buyer), amount);
        assertEq(grs.spent(IGRS.Bucket.TokenSales), amount);
        assertEq(admin.balance, adminBefore + cost);
        assertEq(grs.getSales(0, 10).length, 1);
        assertEq(grs.getSales(0, 1)[0].assetAmount, 0);
        assertEq(grs.getSales(0, 1)[0].grsAmount, 0);
    }

    function test_BuyErc20FromTokenSales() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 assetAmount = 10e6; // $10 for 100 GRS
        vm.prank(admin);
        uint256 id = grs.sale(_q(address(usdc)), assetAmount, admin, 100e18, 0);

        address buyer = address(0xB1E);
        uint256 amount = 100e18;
        assertEq(grs.quoteSale(id, amount), assetAmount);
        usdc.mint(buyer, assetAmount);
        vm.prank(buyer);
        usdc.approve(address(grs), assetAmount);
        vm.prank(buyer);
        grs.buy(id, amount, buyer);

        assertEq(grs.balanceOf(buyer), amount);
        assertEq(usdc.balanceOf(admin), assetAmount);
        assertEq(grs.getSales(0, 1)[0].grsAmount, 0);
        assertEq(grs.getSales(0, 1)[0].assetAmount, 0);
        assertEq(grs.remaining(IGRS.Bucket.TokenSales), 150_000_000e18 - amount);
    }

    function test_BuyClosedUntilAssetAmountSet() public {
        vm.expectRevert(IGRS.UnknownSale.selector);
        grs.buy(1, 1e18, admin);
        vm.prank(admin);
        uint256 id = grs.sale(bytes32(0), 0, address(0), 1e18, 0);
        vm.expectRevert(IGRS.SaleClosed.selector);
        grs.buy(id, 1e18, admin);
    }

    function test_BuyAndGrantShareTokenSalesCap() public {
        vm.prank(admin);
        uint256 id = grs.sale(bytes32(0), 2 ether, address(0), 2e18, 0);
        vm.prank(admin);
        grs.grant(IGRS.Bucket.TokenSales, admin, 150_000_000e18 - 1e18, 0, 0, 0, 0);

        deal(address(this), 2 ether);
        grs.buy{value: 1 ether}(id, 1e18, address(this));
        vm.expectRevert(IGRS.BucketExceeded.selector);
        grs.buy{value: 1 ether}(id, 1e18, address(this));
    }

    function test_TwoSalesDifferentQuotes() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.startPrank(admin);
        uint256 ethId = grs.sale(bytes32(0), 1 ether, address(0), 1e18, 0);
        uint256 usdId = grs.sale(_q(address(usdc)), 2e6, admin, 1e18, 0);
        vm.stopPrank();

        address alice = address(0xA1);
        deal(alice, 1 ether);
        vm.prank(alice);
        grs.buy{value: 1 ether}(ethId, 1e18, alice);

        usdc.mint(alice, 2e6);
        vm.prank(alice);
        usdc.approve(address(grs), 2e6);
        vm.prank(alice);
        grs.buy(usdId, 1e18, alice);

        assertEq(grs.balanceOf(alice), 2e18);
        assertEq(grs.spent(IGRS.Bucket.TokenSales), 2e18);
        assertEq(grs.saleCount(), 2);
        assertEq(grs.getSales(0, 1).length, 1);
        assertEq(grs.getSales(1, 1)[0].asset, _q(address(usdc)));
        assertEq(grs.getSales(2, 1).length, 0);
    }

    function test_SpokeCannotSale() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        vm.prank(admin);
        vm.expectRevert(IGRS.NotHome.selector);
        spoke.sale(bytes32(0), 1 ether, address(0), 1e18, 0);
    }

    function _salePayload(uint256 id, bytes32 asset, uint256 assetAmount, address recipient, uint256 grsAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            keccak256("GRS.sale"),
            id,
            asset,
            assetAmount,
            bytes32(uint256(uint160(recipient))),
            grsAmount
        );
    }

    function test_HomePublishSaleSpokeLzReceiveAccepts() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        bytes32 homePeer = bytes32(uint256(uint160(address(grs))));
        bytes32 spokePeer = bytes32(uint256(uint160(address(spoke))));

        vm.startPrank(admin);
        grs.setPeer(SPOKE_EID, spokePeer);
        spoke.setPeer(HOME_EID, homePeer);
        deal(admin, MOCK_LZ_FEE);
        assertEq(grs.quoteSale(bytes32(0), 0.03 ether, admin, 3e18, SPOKE_EID), MOCK_LZ_FEE);
        uint256 id = grs.sale{value: MOCK_LZ_FEE}(bytes32(0), 0.03 ether, admin, 3e18, SPOKE_EID);
        vm.stopPrank();

        assertEq(id, 1);

        vm.prank(address(endpoint));
        spoke.lzReceive(
            Origin({srcEid: HOME_EID, sender: homePeer, nonce: 1}),
            bytes32(uint256(1)),
            _salePayload(id, bytes32(0), 0.03 ether, admin, 3e18),
            address(0),
            ""
        );

        assertEq(spoke.saleCount(), 1);
        IGRS.Sale memory row = spoke.getSales(0, 1)[0];
        assertEq(row.asset, bytes32(0));
        assertEq(row.assetAmount, 0.03 ether);
        assertEq(row.recipient, admin);
        assertEq(row.grsAmount, 3e18);

        uint256 amount = 3e18;
        deal(address(spoke), address(spoke), amount);
        address buyer = address(0xB1E);
        uint256 cost = spoke.quoteSale(id, amount);
        assertEq(cost, 0.03 ether);
        deal(buyer, cost);
        vm.prank(buyer);
        spoke.buy{value: cost}(id, amount, buyer);
        assertEq(spoke.balanceOf(buyer), amount);
    }

    function test_HomeLzReceiveSaleRevertsNotSpoke() public {
        vm.prank(admin);
        grs.setPeer(SPOKE_EID, bytes32(uint256(2)));

        vm.prank(address(endpoint));
        vm.expectRevert(IGRS.NotSpoke.selector);
        grs.lzReceive(
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(2)), nonce: 1}),
            bytes32(uint256(1)),
            _salePayload(1, bytes32(0), 1, address(0), 0),
            address(0),
            ""
        );
    }

    function test_SaleLocalDstEidZeroRejectsValue() public {
        deal(admin, 1);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidPayment.selector);
        grs.sale{value: 1}(bytes32(0), 1 ether, address(0), 1e18, 0);
        assertEq(grs.quoteSale(bytes32(0), 1 ether, address(0), 1e18, 0), 0);
    }

    function test_SaleAmountCapsBuy() public {
        vm.prank(admin);
        uint256 id = grs.sale(bytes32(0), 1 ether, address(0), 1e18, 0);
        deal(address(this), 3 ether);
        vm.expectRevert(IGRS.SaleExceeded.selector);
        grs.buy{value: 2 ether}(id, 2e18, address(this));
        grs.buy{value: 1 ether}(id, 1e18, address(this));
        vm.expectRevert(IGRS.SaleClosed.selector);
        grs.buy{value: 1 ether}(id, 1e18, address(this));
    }

    function test_SaleAssetAmountSplitAcrossBuys() public {
        vm.prank(admin);
        uint256 id = grs.sale(bytes32(0), 10, address(0), 3e18, 0);
        deal(address(this), 10);
        uint256 first = grs.buy{value: 3}(id, 1e18, address(this));
        assertEq(first, 3);
        IGRS.Sale memory mid = grs.getSales(0, 1)[0];
        assertEq(mid.grsAmount, 2e18);
        assertEq(mid.assetAmount, 7);
        uint256 second = grs.buy{value: 3}(id, 1e18, address(this));
        assertEq(second, 3);
        uint256 last = grs.buy{value: 4}(id, 1e18, address(this));
        assertEq(last, 4);
        assertEq(grs.getSales(0, 1)[0].grsAmount, 0);
        assertEq(grs.getSales(0, 1)[0].assetAmount, 0);
        assertEq(grs.balanceOf(address(this)), 3e18);
    }
    function test_GrantInstantToSpokeBurnsAndCredits() public {
        GRS spoke = new GRS(address(endpoint), admin, false);
        bytes32 homePeer = bytes32(uint256(uint160(address(grs))));
        bytes32 spokePeer = bytes32(uint256(uint160(address(spoke))));
        address bob = address(0xB0B);
        uint256 amount = 5e18;

        vm.startPrank(admin);
        grs.setPeer(SPOKE_EID, spokePeer);
        spoke.setPeer(HOME_EID, homePeer);
        deal(admin, MOCK_LZ_FEE);
        assertEq(grs.quoteGrant(bob, amount, SPOKE_EID), MOCK_LZ_FEE);
        uint256 vestingId = grs.grant{value: MOCK_LZ_FEE}(IGRS.Bucket.CoreTeam, bob, amount, 0, 0, 0, SPOKE_EID);
        vm.stopPrank();

        assertEq(vestingId, 0);
        assertEq(grs.spent(IGRS.Bucket.CoreTeam), amount);
        assertEq(grs.balanceOf(bob), 0);
        assertEq(grs.totalSupply(), 1_000_000_000e18 - amount);
        assertEq(grs.quoteGrant(bob, amount, 0), 0);

        vm.prank(address(endpoint));
        spoke.lzReceive(
            Origin({srcEid: HOME_EID, sender: homePeer, nonce: 1}),
            bytes32(uint256(1)),
            abi.encodePacked(bytes32(uint256(uint160(bob))), uint64(amount / 1e12)),
            address(0),
            ""
        );
        assertEq(spoke.balanceOf(bob), amount);
        assertEq(spoke.totalSupply(), amount);
    }

    function test_GrantVestToSpokeReverts() public {
        vm.prank(admin);
        grs.setPeer(SPOKE_EID, bytes32(uint256(2)));
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidSchedule.selector);
        grs.grant(IGRS.Bucket.CoreTeam, admin, 1e18, 0, 30 days, 0, SPOKE_EID);
    }

    function test_GrantLocalRejectsValue() public {
        deal(admin, 1);
        vm.prank(admin);
        vm.expectRevert(IGRS.InvalidPayment.selector);
        grs.grant{value: 1}(IGRS.Bucket.TokenSales, admin, 1e18, 0, 0, 0, 0);
    }
}
