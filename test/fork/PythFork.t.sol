// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkFixture} from "./ForkFixture.sol";
import {PriceOracleRouter} from "../../src/PriceOracleRouter.sol";
import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";

/// Fork tests that read *live* Pyth prices through the asset-keyed PriceOracleRouter.
contract PythForkTest is ForkFixture {
    address internal constant ETH_PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    address internal constant ARB_PYTH = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;

    bytes32 internal constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    function _assertPythFeed(address asset, address pyth, bytes32 id, string memory desc, uint256 minUsd, uint256 maxUsd)
        internal
    {
        PythStructs.Price memory raw = IPyth(pyth).getPriceUnsafe(id);
        assertGt(raw.price, 0, "price must be positive");
        assertGt(raw.publishTime, 0, "missing publish time");

        PriceOracleRouter router = _newRouter();
        router.addPythFeed(asset, pyth, id);

        if (block.timestamp - raw.publishTime > router.maxStaleness()) {
            emit log("skipping router leg: on-chain pyth price is stale on this fork block");
            vm.skip(true);
        }

        (uint256 price, uint8 dec) = router.getPrice(asset);
        assertEq(price, uint256(int256(raw.price)), "router must mirror raw pyth price");
        assertGt(dec, 0, "expo must map to decimals");
        assertLe(dec, 18, "decimals out of range");

        uint256 usd = price / (10 ** dec);
        assertGe(usd, minUsd, "price below sane floor");
        assertLe(usd, maxUsd, "price above sane ceiling");

        emit log_named_string("feed", desc);
        emit log_named_uint("usd", usd);
        emit log_named_uint("decimals", dec);
    }

    function _routeIfFresh(address asset, address pyth, bytes32 id) internal {
        PythStructs.Price memory raw = IPyth(pyth).getPriceUnsafe(id);
        PriceOracleRouter router = _newRouter();
        if (block.timestamp - raw.publishTime > router.maxStaleness()) {
            emit log("skipping router leg: on-chain pyth price is stale on this fork block");
            vm.skip(true);
        }
        router.addPythFeed(asset, pyth, id);
        (uint256 price, uint8 dec) = router.getPrice(asset);
        assertGt(price, 0);
        assertGt(dec, 0);
    }

    function test_Ethereum_PythEthUsd() public {
        _forkEthereum();
        _assertPythFeed(makeAddr("eth-pyth-eth"), ETH_PYTH, PYTH_ETH_USD, "ETH/USD", 100, 100_000);
    }

    function test_Ethereum_PythBtcUsd() public {
        _forkEthereum();
        _assertPythFeed(makeAddr("eth-pyth-btc"), ETH_PYTH, PYTH_BTC_USD, "BTC/USD", 1_000, 1_000_000);
    }

    function test_Ethereum_PythEthUsd_ThroughRouter() public {
        _forkEthereum();
        _routeIfFresh(makeAddr("eth-pyth-eth-route"), ETH_PYTH, PYTH_ETH_USD);
    }

    function test_Arbitrum_PythEthUsd() public {
        _forkArbitrum();
        _assertPythFeed(makeAddr("arb-pyth-eth"), ARB_PYTH, PYTH_ETH_USD, "ETH/USD", 100, 100_000);
    }

    function test_Arbitrum_PythBtcUsd() public {
        _forkArbitrum();
        _assertPythFeed(makeAddr("arb-pyth-btc"), ARB_PYTH, PYTH_BTC_USD, "BTC/USD", 1_000, 1_000_000);
    }

    function test_Arbitrum_PythEthUsd_ThroughRouter() public {
        _forkArbitrum();
        _routeIfFresh(makeAddr("arb-pyth-eth-route"), ARB_PYTH, PYTH_ETH_USD);
    }
}
