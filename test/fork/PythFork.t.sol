// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkFixture} from "./ForkFixture.sol";
import {PythPriceFeed} from "../../src/PythPriceFeed.sol";
import {PriceOracleRouter} from "../../src/PriceOracleRouter.sol";
import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";

/// Fork tests that read *live* Pyth price feeds through our PythPriceFeed adapter.
///
/// Pyth uses the same bytes32 feed id on every chain; only the Pyth contract
/// address differs per network. Pyth prices are pull-based, so the on-chain
/// stored value can occasionally be older than the router's staleness window —
/// the router integration test skips itself in that (rare) case instead of
/// producing a flaky failure.
contract PythForkTest is ForkFixture {
    // Pyth contract addresses (per network).
    address internal constant ETH_PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    address internal constant ARB_PYTH = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;

    // Feed ids (identical across all chains).
    bytes32 internal constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    /// Reads the live Pyth price via the adapter's AggregatorV3 surface and
    /// validates it against a generous USD range.
    function _assertAdapter(address pyth, bytes32 id, string memory desc, uint256 minUsd, uint256 maxUsd)
        internal
        returns (PythPriceFeed feed)
    {
        feed = new PythPriceFeed(pyth, id, desc);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertGt(answer, 0, "price must be positive");
        assertGt(updatedAt, 0, "missing publish time");
        assertEq(startedAt, updatedAt, "startedAt tracks publishTime");
        assertEq(uint256(roundId), updatedAt, "roundId tracks publishTime");
        assertEq(answeredInRound, roundId, "answeredInRound tracks roundId");

        uint8 dec = feed.decimals();
        assertGt(dec, 0, "expo must map to decimals");
        assertLe(dec, 18, "decimals out of range");
        assertEq(feed.description(), desc, "description mismatch");

        uint256 usd = uint256(answer) / (10 ** dec);
        assertGe(usd, minUsd, "price below sane floor");
        assertLe(usd, maxUsd, "price above sane ceiling");

        emit log_named_string("feed", desc);
        emit log_named_uint("usd", usd);
        emit log_named_uint("decimals", dec);
    }

    /// Confirms the raw Pyth contract is reachable on the fork and returns the
    /// same value the adapter surfaces.
    function _assertRawMatchesAdapter(address pyth, bytes32 id, PythPriceFeed feed) internal view {
        PythStructs.Price memory p = IPyth(pyth).getPriceUnsafe(id);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, int256(p.price), "adapter must mirror raw pyth price");
    }

    /// Routes the live Pyth price through the PriceOracleRouter. Skips when the
    /// on-chain price is older than the router's staleness window on this block.
    function _routeIfFresh(PythPriceFeed feed) internal {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        PriceOracleRouter router = new PriceOracleRouter();
        if (block.timestamp - updatedAt > router.MAX_STALENESS()) {
            emit log("skipping router leg: on-chain pyth price is stale on this fork block");
            vm.skip(true);
        }
        (uint256 price, uint8 dec) = router.getPrice(address(feed));
        assertGt(price, 0);
        assertGt(dec, 0);
    }

    function test_Ethereum_PythEthUsd_Adapter() public {
        _forkEthereum();
        PythPriceFeed feed = _assertAdapter(ETH_PYTH, PYTH_ETH_USD, "ETH/USD", 100, 100_000);
        _assertRawMatchesAdapter(ETH_PYTH, PYTH_ETH_USD, feed);
    }

    function test_Ethereum_PythBtcUsd_Adapter() public {
        _forkEthereum();
        PythPriceFeed feed = _assertAdapter(ETH_PYTH, PYTH_BTC_USD, "BTC/USD", 1_000, 1_000_000);
        _assertRawMatchesAdapter(ETH_PYTH, PYTH_BTC_USD, feed);
    }

    function test_Ethereum_PythEthUsd_ThroughRouter() public {
        _forkEthereum();
        PythPriceFeed feed = new PythPriceFeed(ETH_PYTH, PYTH_ETH_USD, "ETH/USD");
        _routeIfFresh(feed);
    }

    function test_Arbitrum_PythEthUsd_Adapter() public {
        _forkArbitrum();
        PythPriceFeed feed = _assertAdapter(ARB_PYTH, PYTH_ETH_USD, "ETH/USD", 100, 100_000);
        _assertRawMatchesAdapter(ARB_PYTH, PYTH_ETH_USD, feed);
    }

    function test_Arbitrum_PythBtcUsd_Adapter() public {
        _forkArbitrum();
        PythPriceFeed feed = _assertAdapter(ARB_PYTH, PYTH_BTC_USD, "BTC/USD", 1_000, 1_000_000);
        _assertRawMatchesAdapter(ARB_PYTH, PYTH_BTC_USD, feed);
    }

    function test_Arbitrum_PythEthUsd_ThroughRouter() public {
        _forkArbitrum();
        PythPriceFeed feed = new PythPriceFeed(ARB_PYTH, PYTH_ETH_USD, "ETH/USD");
        _routeIfFresh(feed);
    }
}
