// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {GRS} from "../src/GRS.sol";
import {IGRS} from "../src/interfaces/IGRS.sol";

uint32 constant DST_EID = 30168;
uint256 constant MOCK_LZ_FEE = 0.01 ether;

/// @dev Minimal EndpointV2 surface used by `OAppCore` construction and `bridge`.
contract MockLzEndpoint {
    mapping(address => address) public delegates;
    uint256 public constant quoteNative = MOCK_LZ_FEE;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(MOCK_LZ_FEE, 0);
    }

    function send(MessagingParams calldata, address refund)
        external
        payable
        returns (MessagingReceipt memory)
    {
        MessagingFee memory fee = MessagingFee(MOCK_LZ_FEE, 0);
        if (msg.value < fee.nativeFee) revert();
        uint256 extra = msg.value - fee.nativeFee;
        if (extra > 0) {
            (bool ok,) = payable(refund).call{value: extra}("");
            require(ok);
        }
        return MessagingReceipt({guid: bytes32(uint256(1)), nonce: 1, fee: fee});
    }
}

contract GRSTest is Test {
    MockLzEndpoint internal endpoint;
    address internal admin = address(0xA11CE);
    bytes32 internal solanaTo = bytes32(uint256(0x51));

    function setUp() public {
        endpoint = new MockLzEndpoint();
    }

    function _homeWired() internal returns (GRS grs) {
        grs = new GRS(address(endpoint), admin, true);
        vm.startPrank(admin);
        grs.setPeer(DST_EID, bytes32(uint256(2)));
        grs.grant(IGRS.Bucket.TokenSales, bytes32(uint256(uint160(admin))), 10e18, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_HomeMintsCapToSelf() public {
        GRS grs = new GRS(address(endpoint), admin, true);

        assertEq(grs.name(), "GrindURUS Token");
        assertEq(grs.symbol(), "GRS");
        assertEq(grs.decimals(), 18);
        assertEq(grs.sharedDecimals(), 6);
        assertTrue(grs.home());
        assertEq(grs.MAX_SUPPLY(), 1_000_000_000e18);
        assertEq(grs.totalSupply(), 1_000_000_000e18);
        assertEq(grs.balanceOf(address(grs)), 1_000_000_000e18);
        assertEq(grs.balanceOf(admin), 0);
        assertEq(grs.owner(), admin);
        assertEq(grs.pendingOwner(), address(0));
        assertEq(grs.tokenURI(), "https://grindurus.xyz/grs.json");
        assertEq(endpoint.delegates(address(grs)), admin);
        assertFalse(grs.approvalRequired());
        assertEq(grs.token(), address(grs));
    }

    function test_Ownable2Step() public {
        GRS grs = new GRS(address(endpoint), admin, false);
        address next = address(0xB0B);

        assertEq(endpoint.delegates(address(grs)), admin);

        vm.prank(admin);
        grs.transferOwnership(next);
        assertEq(grs.owner(), admin);
        assertEq(grs.pendingOwner(), next);
        // Propose-only: delegate stays with current owner until accept.
        assertEq(endpoint.delegates(address(grs)), admin);

        vm.prank(next);
        grs.acceptOwnership();
        assertEq(grs.owner(), next);
        assertEq(grs.pendingOwner(), address(0));
        assertEq(endpoint.delegates(address(grs)), next);
    }

    function test_SpokeStartsAtZero() public {
        GRS grs = new GRS(address(endpoint), admin, false);

        assertFalse(grs.home());
        assertEq(grs.totalSupply(), 0);
        assertEq(grs.balanceOf(admin), 0);
        assertEq(grs.MAX_SUPPLY(), 1_000_000_000e18);
    }

    function test_TransferWorks() public {
        GRS grs = new GRS(address(endpoint), admin, true);
        address bob = address(0xB0B);

        vm.startPrank(admin);
        grs.grant(IGRS.Bucket.TokenSales, bytes32(uint256(uint160(admin))), 1e18, 0, 0, 0, 0);
        assertTrue(grs.transfer(bob, 1e18));
        vm.stopPrank();
        assertEq(grs.balanceOf(bob), 1e18);
        assertEq(grs.totalSupply(), 1_000_000_000e18);
    }

    function test_CreditRespectsCap() public {
        GRS home = new GRS(address(endpoint), admin, true);
        GRSHarness spoke = new GRSHarness(address(endpoint), admin, false);

        vm.expectRevert(IGRS.CapExceeded.selector);
        spoke.credit(admin, 1_000_000_000e18 + 1, 1);

        spoke.credit(admin, 1e18, 1);
        assertEq(spoke.totalSupply(), 1e18);
        assertEq(home.totalSupply(), 1_000_000_000e18);
    }

    function test_QuoteBridge() public {
        GRS grs = _homeWired();
        assertEq(grs.quoteBridge(DST_EID, solanaTo, 1e18), MOCK_LZ_FEE);
        assertEq(grs.quoteBridge(DST_EID, bytes32(uint256(uint160(address(0xB0B)))), 1e18), MOCK_LZ_FEE);
    }

    function test_BridgeBurnsAndPaysFee() public {
        GRS grs = _homeWired();
        uint256 fee = grs.quoteBridge(DST_EID, solanaTo, 1e18);
        vm.deal(admin, fee);

        vm.prank(admin);
        grs.bridge{value: fee}(DST_EID, solanaTo, 1e18);

        assertEq(grs.totalSupply(), 1_000_000_000e18 - 1e18);
        assertEq(grs.balanceOf(admin), 9e18);
        assertEq(address(endpoint).balance, fee);
        assertEq(admin.balance, 0);
    }

    function test_BridgeEvmRecipient() public {
        GRS grs = _homeWired();
        bytes32 dest = bytes32(uint256(uint160(address(0xB0B))));
        uint256 fee = grs.quoteBridge(DST_EID, dest, 2e18);
        vm.deal(admin, fee);

        vm.prank(admin);
        grs.bridge{value: fee}(DST_EID, dest, 2e18);

        assertEq(grs.balanceOf(admin), 8e18);
    }

    function test_SendRejectsCompose() public {
        GRS grs = _homeWired();
        SendParam memory p = SendParam({
            dstEid: DST_EID,
            to: solanaTo,
            amountLD: 1e18,
            minAmountLD: 1e18,
            extraOptions: "",
            composeMsg: hex"01",
            oftCmd: ""
        });
        vm.deal(admin, MOCK_LZ_FEE);
        vm.prank(admin);
        vm.expectRevert(IGRS.ComposeDisabled.selector);
        grs.send{value: MOCK_LZ_FEE}(p, MessagingFee(MOCK_LZ_FEE, 0), admin);
    }

    function test_SendRejectsSaleOrGrantMsgAsTo() public {
        GRS grs = _homeWired();
        bytes32 saleMsg = keccak256("GRS.sale");
        bytes32 grantMsg = keccak256("GRS.grant");
        SendParam memory p = SendParam({
            dstEid: DST_EID,
            to: saleMsg,
            amountLD: 1e18,
            minAmountLD: 1e18,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.deal(admin, MOCK_LZ_FEE * 2);
        vm.startPrank(admin);
        vm.expectRevert(IGRS.InvalidRecipient.selector);
        grs.send{value: MOCK_LZ_FEE}(p, MessagingFee(MOCK_LZ_FEE, 0), admin);
        p.to = grantMsg;
        vm.expectRevert(IGRS.InvalidRecipient.selector);
        grs.send{value: MOCK_LZ_FEE}(p, MessagingFee(MOCK_LZ_FEE, 0), admin);
        vm.expectRevert(IGRS.InvalidRecipient.selector);
        grs.quoteBridge(DST_EID, saleMsg, 1e18);
        vm.stopPrank();
    }

    function test_BridgeStripsDust() public {
        GRS grs = _homeWired();
        uint256 fee = grs.quoteBridge(DST_EID, solanaTo, 1e18 + 1);
        vm.deal(admin, fee);

        vm.prank(admin);
        grs.bridge{value: fee}(DST_EID, solanaTo, 1e18 + 1);

        assertEq(grs.balanceOf(admin), 9e18);
    }

    function test_BridgeRejectsZeroRecipient() public {
        GRS grs = _homeWired();
        vm.expectRevert(IGRS.InvalidRecipient.selector);
        grs.quoteBridge(DST_EID, bytes32(0), 1e18);
    }

    function test_GetPeers() public {
        GRS grs = new GRS(address(endpoint), admin, true);
        IGRS.Peer[] memory empty = grs.getPeers();
        assertEq(empty.length, 0);

        vm.startPrank(admin);
        grs.setPeer(30168, bytes32(uint256(2)));
        grs.setPeer(30110, bytes32(uint256(3)));
        grs.setPeer(30110, bytes32(uint256(4)));
        vm.stopPrank();

        assertGt(grs.enforcedOptions(30168, 1).length, 0);
        assertGt(grs.enforcedOptions(30110, 1).length, 0);

        (uint128 solGas, uint128 solValue) = grs.peerLzReceiveBudget(30168);
        assertEq(solGas, grs.DEFAULT_LZ_RECEIVE_GAS());
        assertEq(solValue, grs.DEFAULT_SOLANA_LZ_RECEIVE_VALUE());

        vm.prank(admin);
        grs.setPeerLzReceiveBudget(40_124, 300_000, 1_000_000); // e.g. Aptos-style eid
        (uint128 aptGas, uint128 aptValue) = grs.peerLzReceiveBudget(40_124);
        assertEq(aptGas, 300_000);
        assertEq(aptValue, 1_000_000);

        IGRS.Peer[] memory listed = grs.getPeers();
        assertEq(listed.length, 2);
        assertEq(listed[0].eid, 30168);
        assertEq(listed[0].peer, bytes32(uint256(2)));
        assertEq(listed[1].eid, 30110);
        assertEq(listed[1].peer, bytes32(uint256(4)));

        vm.prank(admin);
        grs.setPeer(30168, bytes32(0));

        assertEq(grs.enforcedOptions(30168, 1).length, 0);

        listed = grs.getPeers();
        assertEq(listed.length, 1);
        assertEq(listed[0].eid, 30110);
        assertEq(listed[0].peer, bytes32(uint256(4)));
    }

    function test_BridgeRejectsDustOnly() public {
        GRS grs = _homeWired();
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, uint256(0), uint256(1)));
        grs.quoteBridge(DST_EID, solanaTo, 1);
    }
}

/// @dev Exposes OFT `_credit` for the local cap check without a live endpoint send.
contract GRSHarness is GRS {
    constructor(address lzEndpoint, address delegate, bool home_) GRS(lzEndpoint, delegate, home_) {}

    function credit(address to, uint256 amountLD, uint32 srcEid) external returns (uint256) {
        return _credit(to, amountLD, srcEid);
    }
}
