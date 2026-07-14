// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Grinders} from "../src/Grinders.sol";
import {GRAI} from "../src/GRAI.sol";
import {IGRAI} from "../src/interfaces/IGRAI.sol";
import {IPriceOracleRouter} from "../src/interfaces/IPriceOracleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

abstract contract GRAIFixture is Test {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custodian = makeAddr("custodian");

    Grinders grai;
    GRAI graiToken;

    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockAggregator usdcFeed; // 8 decimals, $1
    MockAggregator wethFeed; // 8 decimals, $2000

    uint16 constant BPS = 10_000;
    uint16 constant DEFAULT_YIELD_SPLIT = 8_000;
    uint256 constant DEFAULT_MAX_STALENESS = 1 hours;

    function setUp() public virtual {
        vm.startPrank(admin);
        address tokenAddr = _deployGraiToken();
        graiToken = GRAI(payable(tokenAddr));

        Grinders impl = new Grinders();
        bytes memory init = abi.encodeCall(Grinders.initialize, (admin, tokenAddr));
        grai = Grinders(payable(address(new ERC1967Proxy(address(impl), init))));
        graiToken.toggleGrinders(address(grai));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8);
        wethFeed = new MockAggregator(8, 2000e8);

        _setChainlinkFeed(address(usdc), address(usdcFeed));
        _setChainlinkFeed(address(weth), address(wethFeed));
        graiToken.addAsset(address(usdc), DEFAULT_YIELD_SPLIT);
        graiToken.addAsset(address(weth), DEFAULT_YIELD_SPLIT);
        _registerTestCustodian();
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        usdc.mint(custodian, 1_000e6); // for distribute
        weth.mint(alice, 100e18);
    }

    function _deployGraiToken() internal returns (address) {
        return _deployGraiToken(admin);
    }

    function _deployGraiToken(address tokenAdmin) internal returns (address) {
        GRAI impl = new GRAI();
        return address(
            new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (tokenAdmin)))
        );
    }

    function _registerTestCustodian() internal virtual {
        grai.register(custodian, 0, admin);
    }

    function _allocate(address asset, address custodian_, uint256 amount) internal {
        vm.prank(admin);
        grai.allocate(custodian_, asset, amount);
    }

    function _setChainlinkFeed(address asset, address aggregator) internal {
        graiToken.setFeed(asset, _chainlinkFeed(asset, aggregator));
    }

    function _setPythFeed(address asset, address pyth, bytes32 priceId) internal {
        graiToken.setFeed(
            asset,
            IPriceOracleRouter.Feed({
                feedType: 3,
                asset: asset,
                source: pyth,
                data: priceId,
                decimals: 0,
                storedPrice: 0,
                storedUpdatedAt: 0,
                maxStaleness: DEFAULT_MAX_STALENESS
            })
        );
    }

    function _chainlinkFeed(address asset, address aggregator) internal pure returns (IPriceOracleRouter.Feed memory) {
        return IPriceOracleRouter.Feed({
            feedType: 2,
            asset: asset,
            source: aggregator,
            data: bytes32(0),
            decimals: 0,
            storedPrice: 0,
            storedUpdatedAt: 0,
            maxStaleness: DEFAULT_MAX_STALENESS
        });
    }

    function _auctionExit(address seller, address bidder, address asset, uint256 graiAmount, uint256 payment)
        internal
    {
        vm.prank(seller);
        uint256 auctionId = graiToken.ask(asset, payment, payment, 1 days, graiAmount);
        vm.startPrank(bidder);
        if (asset != address(0)) {
            IERC20(asset).approve(address(graiToken), payment);
            graiToken.bid(auctionId, graiAmount);
        } else {
            graiToken.bid{value: payment}(auctionId, graiAmount);
        }
        vm.stopPrank();
    }

    function _redeem(address user, uint256 amount) internal {
        vm.startPrank(user);
        graiToken.redeem(amount);
        vm.stopPrank();
    }

    function _mint(address user, MockERC20 token, uint256 amount) internal returns (uint256 graiOut) {
        vm.startPrank(user);
        token.approve(address(graiToken), amount);
        graiOut = graiToken.deposit(address(token), amount);
        vm.stopPrank();
    }

    function _fundGrinders(MockERC20 token, uint256 amount) internal {
        token.mint(address(grai), amount);
    }

    function _assertFirstVaultSnapshot(address expectedAsset, uint256 expectedSenior, uint256 expectedJunior)
        internal
        view
    {
        assertEq(graiToken.assetList(0), expectedAsset);
        assertEq(grai.grai().balance(expectedAsset), expectedSenior);
        assertEq(grai.balance(expectedAsset), expectedJunior);
    }
}
