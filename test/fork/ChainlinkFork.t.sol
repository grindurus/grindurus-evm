// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkFixture} from "./ForkFixture.sol";
import {PriceOracleRouter} from "../../src/PriceOracleRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// Fork tests that read *live* Chainlink aggregators.
///
/// Chainlink USD feeds already implement AggregatorV3Interface, so the router can
/// consume them directly with no adapter. Every test validates the live feed via
/// latestRoundData; the "ThroughRouter" tests additionally exercise the
/// PriceOracleRouter, skipping when the on-chain round is older than the router's
/// staleness window on the forked block (Chainlink feeds with a ~1h heartbeat can
/// legitimately sit right at that boundary).
///
/// Addresses are the canonical EACAggregatorProxy feeds on each network.
contract ChainlinkForkTest is ForkFixture {
    // --- Ethereum mainnet ---
    address internal constant ETH_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant ETH_BTCUSD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    // --- Arbitrum One ---
    address internal constant ARB_ETHUSD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant ARB_BTCUSD = 0x6ce185860a4963106506C203335A2910413708e9;

    /// Reads a live feed directly and sanity-checks the value against a (generous)
    /// USD range so the test asserts on real data without being brittle.
    function _assertFeed(address feed, uint256 minUsd, uint256 maxUsd) internal {
        AggregatorV3Interface agg = AggregatorV3Interface(feed);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = agg.latestRoundData();
        assertGt(answer, 0, "price must be positive");
        assertGt(updatedAt, 0, "round incomplete");
        assertGe(answeredInRound, roundId, "answer from stale round");

        uint8 dec = agg.decimals();
        assertEq(dec, 8, "chainlink usd feeds report 8 decimals");

        uint256 usd = uint256(answer) / (10 ** dec);
        assertGe(usd, minUsd, "price below sane floor");
        assertLe(usd, maxUsd, "price above sane ceiling");

        string memory desc = agg.description();
        assertGt(bytes(desc).length, 0, "feed missing description");
        emit log_named_string("feed", desc);
        emit log_named_uint("usd", usd);
    }

    /// Routes the live feed through the PriceOracleRouter. Skips when the on-chain
    /// round is older than MAX_STALENESS on this fork block.
    function _routeIfFresh(address feed) internal {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        PriceOracleRouter router = new PriceOracleRouter();
        if (block.timestamp - updatedAt > router.MAX_STALENESS()) {
            emit log("skipping router leg: chainlink round is stale on this fork block");
            vm.skip(true);
        }
        (uint256 price, uint8 dec) = router.getPrice(feed);
        assertEq(dec, 8);
        assertGt(price, 0);
    }

    function test_Ethereum_EthUsd() public {
        _forkEthereum();
        _assertFeed(ETH_ETHUSD, 100, 100_000);
    }

    function test_Ethereum_BtcUsd() public {
        _forkEthereum();
        _assertFeed(ETH_BTCUSD, 1_000, 1_000_000);
    }

    function test_Ethereum_EthUsd_ThroughRouter() public {
        _forkEthereum();
        _routeIfFresh(ETH_ETHUSD);
    }

    function test_Arbitrum_EthUsd() public {
        _forkArbitrum();
        _assertFeed(ARB_ETHUSD, 100, 100_000);
    }

    function test_Arbitrum_BtcUsd() public {
        _forkArbitrum();
        _assertFeed(ARB_BTCUSD, 1_000, 1_000_000);
    }

    function test_Arbitrum_EthUsd_ThroughRouter() public {
        _forkArbitrum();
        _routeIfFresh(ARB_ETHUSD);
    }

    /// The router must reject a stale round. We simulate staleness by jumping the
    /// fork clock past MAX_STALENESS while the on-chain feed's updatedAt stays put.
    function test_Ethereum_StaleFeedRevertsViaRouter() public {
        _forkEthereum();
        PriceOracleRouter router = new PriceOracleRouter();

        vm.warp(block.timestamp + router.MAX_STALENESS() + 1);
        vm.expectRevert(bytes("stale price"));
        router.getPrice(ETH_ETHUSD);
    }
}
