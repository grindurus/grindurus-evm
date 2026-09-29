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

uint32 constant HOME_EID = 30101; // Ethereum mainnet (LayerZero V2)
uint32 constant SPOKE_EID = 30110; // Arbitrum One (LayerZero V2)
uint32 constant ETHEREUM_EID = HOME_EID;
uint32 constant ARBITRUM_EID = SPOKE_EID;
uint256 constant MOCK_LZ_FEE = 0.01 ether;

/// @dev Captures the last LZ payload so tests can deliver it to the peer OApp.
contract MockLzEndpoint {
    mapping(address => address) public delegates;
    bytes public lastMessage;
    uint32 public lastDstEid;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: MOCK_LZ_FEE, lzTokenFee: 0});
    }

    function send(MessagingParams calldata params, address refund) external payable returns (MessagingReceipt memory) {
        lastMessage = params.message;
        lastDstEid = params.dstEid;
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

/// @notice Home ↔ spoke flows: TokenSales publish, OFT bridge, instant + vesting grant.
contract GRSCrossChainTest is Test {
    MockLzEndpoint internal endpoint;
    GRS internal home;
    GRS internal spoke;
    address internal admin = address(0xA11CE);
    address internal alice = address(0xA11A);
    address internal bob = address(0xB0B);
    address internal buyer = address(0xB1E);

    bytes32 internal homePeer;
    bytes32 internal spokePeer;
    uint64 internal homeToSpokeNonce;
    uint64 internal spokeToHomeNonce;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        home = new GRS(address(endpoint), admin, 0, bytes32(0));
        spoke = new GRS(address(endpoint), admin, HOME_EID, bytes32(uint256(uint160(address(home)))));
        homePeer = bytes32(uint256(uint160(address(home))));
        spokePeer = bytes32(uint256(uint160(address(spoke))));

        vm.startPrank(admin);
        home.setPeer(SPOKE_EID, spokePeer);
        vm.stopPrank();
    }

    function _q(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Deliver `endpoint.lastMessage()` from home → spoke as if the LZ executor ran.
    function _relayHomeToSpoke() internal {
        bytes memory payload = endpoint.lastMessage();
        require(payload.length > 0, "empty LZ payload");
        homeToSpokeNonce += 1;
        vm.prank(address(endpoint));
        spoke.lzReceive(
            Origin({srcEid: HOME_EID, sender: homePeer, nonce: homeToSpokeNonce}),
            bytes32(uint256(homeToSpokeNonce)),
            payload,
            address(0),
            ""
        );
    }

    /// @dev Deliver `endpoint.lastMessage()` from spoke → home.
    function _relaySpokeToHome() internal {
        bytes memory payload = endpoint.lastMessage();
        require(payload.length > 0, "empty LZ payload");
        spokeToHomeNonce += 1;
        vm.prank(address(endpoint));
        home.lzReceive(
            Origin({srcEid: SPOKE_EID, sender: spokePeer, nonce: spokeToHomeNonce}),
            bytes32(uint256(spokeToHomeNonce)),
            payload,
            address(0),
            ""
        );
    }

    function _fundLz(address who) internal {
        deal(who, MOCK_LZ_FEE * 10);
    }

    // -------------------------------------------------------------------------
    // Sale
    // -------------------------------------------------------------------------

    /// @notice Deploy GRS home on Ethereum, spoke on Arbitrum; owner lists a native ETH lot on
    ///         Ethereum targeted at Arbitrum — inventory burns on home, lot opens in spoke escrow.
    function test_EthereumDeploy_CrossChainSaleToArbitrum() public {
        // Fresh deploy pair labeled by chain eid (same mock endpoint; peers wire ETH ↔ ARB).
        MockLzEndpoint lz = new MockLzEndpoint();
        GRS ethereum = new GRS(address(lz), admin, 0, bytes32(0));
        GRS arbitrum = new GRS(address(lz), admin, ETHEREUM_EID, bytes32(uint256(uint160(address(ethereum)))));
        bytes32 ethPeer = bytes32(uint256(uint160(address(ethereum))));
        bytes32 arbPeer = bytes32(uint256(uint160(address(arbitrum))));

        vm.startPrank(admin);
        ethereum.setPeer(ARBITRUM_EID, arbPeer);
        vm.stopPrank();

        assertEq(ethereum.homeAddress(), bytes32(0));
        assertTrue(arbitrum.homeAddress() != bytes32(0));
        assertEq(ethereum.totalSupply(), 1_000_000_000e18);
        assertEq(arbitrum.totalSupply(), 0);

        uint256 lot = 10e18;
        uint256 quote = 0.1 ether;
        uint256 fee = ethereum.quoteSale(bytes32(0), quote, lot, _q(admin), ARBITRUM_EID);
        assertEq(fee, MOCK_LZ_FEE);
        deal(admin, fee);

        uint256 ethSupplyBefore = ethereum.totalSupply();
        vm.prank(admin);
        uint256 id = ethereum.sale{value: fee}(bytes32(0), quote, lot, _q(admin), ARBITRUM_EID);

        assertEq(id, 1);
        assertEq(lz.lastDstEid(), ARBITRUM_EID);
        assertEq(ethereum.spent(IGRS.Bucket.TokenSales), lot);
        assertEq(ethereum.salesReserved(), 0); // cross-chain debit, not local earmark
        assertEq(ethereum.getSales(0, 1)[0].grsAmount, 0); // home row closed after publish
        assertEq(ethereum.getSales(0, 1)[0].assetAmount, 0);
        assertEq(ethereum.totalSupply(), ethSupplyBefore - lot);
        assertEq(ethereum.balanceOf(address(ethereum)), ethSupplyBefore - lot);

        // Simulate LZ executor delivering the packed GRS.sale message to Arbitrum.
        bytes memory payload = lz.lastMessage();
        vm.prank(address(lz));
        arbitrum.lzReceive(
            Origin({srcEid: ETHEREUM_EID, sender: ethPeer, nonce: 1}),
            bytes32(uint256(1)),
            payload,
            address(0),
            ""
        );

        assertEq(arbitrum.getSales(0, 1).length, 1);
        IGRS.Sale memory row = arbitrum.getSales(0, 1)[0];
        assertEq(row.asset, bytes32(0));
        assertEq(row.assetAmount, quote);
        assertEq(row.grsAmount, lot);
        assertEq(row.recipient, _q(admin));
        assertEq(arbitrum.salesReserved(), lot);
        assertEq(arbitrum.balanceOf(address(arbitrum)), lot);
        assertEq(arbitrum.totalSupply(), lot);
        assertEq(arbitrum.remaining(IGRS.Bucket.TokenSales), 0); // escrow fully earmarked to the lot

        deal(buyer, quote);
        uint256 adminBefore = admin.balance;
        vm.prank(buyer);
        uint256 cost = arbitrum.buy{value: quote}(id, lot, buyer);
        assertEq(cost, quote);
        assertEq(arbitrum.balanceOf(buyer), lot);
        assertEq(arbitrum.salesReserved(), 0);
        assertEq(arbitrum.getSales(0, 1)[0].grsAmount, 0);
        assertEq(admin.balance, adminBefore + quote);
    }

    function test_CrossChain_SalePublishThenBuyOnSpoke() public {
        uint256 lot = 5e18;
        uint256 quote = 0.05 ether;
        _fundLz(admin);

        vm.prank(admin);
        uint256 id = home.sale{value: MOCK_LZ_FEE}(bytes32(0), quote, lot, _q(admin), SPOKE_EID);

        assertEq(id, 1);
        assertEq(endpoint.lastDstEid(), SPOKE_EID);
        assertEq(home.spent(IGRS.Bucket.TokenSales), lot);
        assertEq(home.getSales(0, 1)[0].grsAmount, 0); // home row closed after publish
        assertEq(home.totalSupply(), 1_000_000_000e18 - lot);

        _relayHomeToSpoke();

        assertEq(spoke.getSales(0, 1).length, 1);
        IGRS.Sale memory row = spoke.getSales(0, 1)[0];
        assertEq(row.grsAmount, lot);
        assertEq(row.assetAmount, quote);
        assertEq(spoke.balanceOf(address(spoke)), lot);

        deal(buyer, quote);
        uint256 adminBefore = admin.balance;
        vm.prank(buyer);
        uint256 cost = spoke.buy{value: quote}(id, lot, buyer);
        assertEq(cost, quote);
        assertEq(spoke.balanceOf(buyer), lot);
        assertEq(spoke.getSales(0, 1)[0].grsAmount, 0);
        assertEq(admin.balance, adminBefore + quote);
    }

    // -------------------------------------------------------------------------
    // Bridge
    // -------------------------------------------------------------------------

    function test_CrossChain_BridgeCreditsRecipientOnSpoke() public {
        uint256 amount = 3e18;
        _fundLz(admin);
        _fundLz(alice);

        // Seed alice with liquid GRS on home via instant local grant.
        vm.prank(admin);
        home.grant(IGRS.Bucket.TokenSales, _q(alice), amount + 1e18, 0, 0, 0, 0);

        vm.prank(alice);
        home.bridge{value: MOCK_LZ_FEE}(SPOKE_EID, _q(bob), amount);

        assertEq(home.balanceOf(alice), 1e18);
        assertEq(home.totalSupply(), 1_000_000_000e18 - amount);

        _relayHomeToSpoke();

        assertEq(spoke.balanceOf(bob), amount);
        assertEq(spoke.totalSupply(), amount);
    }

    function test_CrossChain_BridgeSpokeToHome() public {
        uint256 amount = 3e18;
        _fundLz(admin);
        _fundLz(alice);
        _fundLz(bob);

        // Seed bob on spoke via home → spoke bridge.
        vm.prank(admin);
        home.grant(IGRS.Bucket.TokenSales, _q(alice), amount, 0, 0, 0, 0);
        vm.prank(alice);
        home.bridge{value: MOCK_LZ_FEE}(SPOKE_EID, _q(bob), amount);
        _relayHomeToSpoke();
        assertEq(spoke.balanceOf(bob), amount);
        assertEq(home.totalSupply(), 1_000_000_000e18 - amount);
        assertEq(spoke.totalSupply(), amount);

        // Bob bridges back to alice on home (Arbitrum → Ethereum).
        vm.prank(bob);
        spoke.bridge{value: MOCK_LZ_FEE}(HOME_EID, _q(alice), amount);

        assertEq(spoke.balanceOf(bob), 0);
        assertEq(spoke.totalSupply(), 0);
        assertEq(endpoint.lastDstEid(), HOME_EID);

        _relaySpokeToHome();

        assertEq(home.balanceOf(alice), amount);
        assertEq(home.totalSupply(), 1_000_000_000e18); // burned outbound, reminted inbound
    }

    // -------------------------------------------------------------------------
    // Grant
    // -------------------------------------------------------------------------

    function test_CrossChain_GrantInstantCreditsSpoke() public {
        uint256 amount = 7e18;
        _fundLz(admin);

        vm.prank(admin);
        uint256 vestingId =
            home.grant{value: MOCK_LZ_FEE}(IGRS.Bucket.CoreTeam, _q(bob), amount, 0, 0, 0, SPOKE_EID);

        assertEq(vestingId, 0);
        assertEq(home.spent(IGRS.Bucket.CoreTeam), amount);
        assertEq(home.balanceOf(bob), 0);
        assertEq(home.totalSupply(), 1_000_000_000e18 - amount);

        _relayHomeToSpoke();

        assertEq(spoke.balanceOf(bob), amount);
        vm.expectRevert(IGRS.UnknownVesting.selector);
        spoke.getVestings(0, 1);
    }

    function test_CrossChain_GrantVestThenReleaseOnSpoke() public {
        uint256 amount = 12e18;
        uint64 start = uint64(block.timestamp);
        uint64 cliff = 30 days;
        uint64 linear = 90 days;
        _fundLz(admin);

        vm.prank(admin);
        uint256 homeId = home.grant{value: MOCK_LZ_FEE}(
            IGRS.Bucket.Advisors, _q(bob), amount, start, cliff, linear, SPOKE_EID
        );

        assertEq(homeId, 0);
        vm.expectRevert(IGRS.UnknownVesting.selector);
        home.getVestings(0, 1);
        assertEq(home.spent(IGRS.Bucket.Advisors), amount);

        _relayHomeToSpoke();

        assertEq(spoke.getVestings(0, 1).length, 1);
        assertEq(spoke.balanceOf(address(spoke)), amount);
        assertEq(spoke.balanceOf(bob), 0);
        IGRS.Vesting memory v = spoke.getVestings(0, 1)[0];
        assertEq(uint8(v.bucket), uint8(IGRS.Bucket.Advisors));
        assertEq(v.beneficiary, bob);
        assertEq(v.allocation, amount);
        assertEq(v.cliffEnd, start + cliff);
        assertEq(v.end, start + cliff + linear);

        vm.warp(start + cliff + linear);
        spoke.release(1);
        assertEq(spoke.balanceOf(bob), amount);
        assertEq(spoke.releasable(1), 0);
    }

    // -------------------------------------------------------------------------
    // Combined narrative
    // -------------------------------------------------------------------------

    /// @notice Sale publish → buy on spoke → bridge home→spoke → bridge spoke→home → vesting grant.
    function test_CrossChain_SaleBridgeAndGrant() public {
        _fundLz(admin);

        // 1) Sale: home publishes TokenSales lot → spoke escrow → buyer fills.
        uint256 saleLot = 4e18;
        uint256 saleQuote = 0.04 ether;
        vm.prank(admin);
        uint256 saleId = home.sale{value: MOCK_LZ_FEE}(bytes32(0), saleQuote, saleLot, _q(admin), SPOKE_EID);
        _relayHomeToSpoke();
        deal(buyer, saleQuote);
        vm.prank(buyer);
        spoke.buy{value: saleQuote}(saleId, saleLot, buyer);
        assertEq(spoke.balanceOf(buyer), saleLot);

        // 2) Bridge home → spoke: liquid grant on home → OFT to bob.
        uint256 bridgeAmt = 2e18;
        _fundLz(alice);
        vm.prank(admin);
        home.grant(IGRS.Bucket.GrowthFund, _q(alice), bridgeAmt, 0, 0, 0, 0);
        vm.prank(alice);
        home.bridge{value: MOCK_LZ_FEE}(SPOKE_EID, _q(bob), bridgeAmt);
        _relayHomeToSpoke();
        assertEq(spoke.balanceOf(bob), bridgeAmt);

        // 3) Bridge spoke → home: bob sends half back to alice on Ethereum.
        uint256 backAmt = 1e18;
        _fundLz(bob);
        vm.prank(bob);
        spoke.bridge{value: MOCK_LZ_FEE}(HOME_EID, _q(alice), backAmt);
        _relaySpokeToHome();
        assertEq(spoke.balanceOf(bob), bridgeAmt - backAmt);
        assertEq(home.balanceOf(alice), backAmt);

        // 4) Grant vest: home schedules Advisors vest on spoke → release after unlock.
        uint256 vestAmt = 6e18;
        uint64 start = uint64(block.timestamp);
        vm.prank(admin);
        home.grant{value: MOCK_LZ_FEE}(IGRS.Bucket.Advisors, _q(bob), vestAmt, start, 7 days, 14 days, SPOKE_EID);
        _relayHomeToSpoke();
        assertEq(spoke.getVestings(0, 1).length, 1);
        assertEq(spoke.balanceOf(address(spoke)), vestAmt);

        vm.warp(start + 21 days);
        spoke.release(1);
        assertEq(spoke.balanceOf(bob), bridgeAmt - backAmt + vestAmt);

        // Home: sale + growth burned; advisors burned; reminted `backAmt` from spoke→home.
        assertEq(home.spent(IGRS.Bucket.TokenSales), saleLot);
        assertEq(home.spent(IGRS.Bucket.GrowthFund), bridgeAmt);
        assertEq(home.spent(IGRS.Bucket.Advisors), vestAmt);
        assertEq(home.totalSupply(), 1_000_000_000e18 - saleLot - bridgeAmt - vestAmt + backAmt);
        assertEq(spoke.totalSupply(), saleLot + bridgeAmt - backAmt + vestAmt);
    }
}
