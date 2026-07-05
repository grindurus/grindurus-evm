// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkFixture} from "./ForkFixture.sol";
import {PriceOracleRouter} from "../../src/PriceOracleRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// Fork tests that read *live* Chainlink aggregators through the asset-keyed router.
contract ChainlinkForkTest is ForkFixture {
    address internal constant ETH_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant ETH_BTCUSD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    address internal constant ARB_ETHUSD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant ARB_BTCUSD = 0x6ce185860a4963106506C203335A2910413708e9;

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

    function _routeIfFresh(address asset, address aggregator) internal {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
        PriceOracleRouter router = _newRouter();
        if (block.timestamp - updatedAt > router.maxStaleness()) {
            emit log("skipping router leg: chainlink round is stale on this fork block");
            vm.skip(true);
        }
        router.addChainlinkFeed(asset, aggregator);
        (uint256 price, uint8 dec) = router.getPrice(asset);
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
        _routeIfFresh(makeAddr("eth-usd"), ETH_ETHUSD);
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
        _routeIfFresh(makeAddr("arb-eth-usd"), ARB_ETHUSD);
    }

    function test_Ethereum_StaleFeedRevertsViaRouter() public {
        _forkEthereum();
        PriceOracleRouter router = _newRouter();
        address asset = makeAddr("eth-usd-stale");
        router.addChainlinkFeed(asset, ETH_ETHUSD);

        vm.warp(block.timestamp + router.maxStaleness() + 1);
        vm.expectRevert(bytes("stale price"));
        router.getPrice(asset);
    }
}
