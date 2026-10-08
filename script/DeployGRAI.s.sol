// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI, IGRAI, IPriceOracleRouter} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {Grinders} from "../src/Grinders.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";

/// @title Deploy GRAI on an EVM chain
/// @notice Direct CREATE: GRAI + Treasury + Grinders (impl + ERC1967 proxy each), feeds.
///         Network from `block.chainid` (`--rpc-url`). Addresses are not precomputed.
///
/// Env:
///   PRIVATE_KEY       — deployer / initial owner
///   OWNER_MULTISIG    — optional Ownable2Step handoff (`acceptOwnership` required)
///   MAX_STALENESS     — optional seconds (default per-chain)
///   WETH              — optional override of network WETH
///   GRAI / GRINDERS   — required for post-deploy helpers
///
/// Simulate (no broadcast):
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI --rpc-url arbitrum
///
/// Deploy:
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --rpc-url arbitrum --broadcast --verify
///
/// Post-deploy helpers (owner = `PRIVATE_KEY`):
///   PRIVATE_KEY=0x... GRAI=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "setBribeable()" --rpc-url arbitrum --broadcast
///   PRIVATE_KEY=0x... GRINDERS=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployCoWCustodian()" --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployLiFiCustodianImpl(bool)" false --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployLiFiCustodianProxy()" --rpc-url arbitrum --broadcast --verify
contract DeployGRAI is Script {
    struct AssetData {
        address asset;
        IPriceOracleRouter.FeedType oracleType;
        address oracle; // feed source; address(0) = skip setFeed
        bool bribeable;
    }

    struct Network {
        string name;
        uint256 chainId;
        address weth;
        AssetData[] assets;
        uint256 defaultMaxStaleness;
    }

    function run() external {
        Network memory net = _network();
        address owner = vm.addr(vm.envUint("PRIVATE_KEY"));
        address weth = vm.envOr("WETH", net.weth);
        require(weth != address(0), "WETH required");

        _logNetwork(net, owner, weth);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        GRAI grai = deployGRAI(owner, weth);
        Treasury treasury = deployTreasury(address(grai));
        wireTreasury(grai, address(treasury));
        Grinders grinders = deployGrinders(owner, address(grai));
        wireGrinders(grai, address(grinders));

        initFeeds(grai);
        for (uint256 i; i < net.assets.length; ++i) {
            if (!net.assets[i].bribeable) continue;
            uint256 data = uint256(uint160(net.assets[i].asset)) | (uint256(1) << 160);
            grai.setConfig(IGRAI.ConfigId.BRIBEABLE, data);
            console2.log("setConfig BRIBEABLE:", net.assets[i].asset);
        }

        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (ownerMultisig != address(0)) {
            grai.transferOwnership(ownerMultisig);
            grinders.transferOwnership(ownerMultisig);
            console2.log("Pending GRAI/Grinders owner (call acceptOwnership):", ownerMultisig);
        }

        vm.stopBroadcast();

        require(address(grai.treasury()) == address(treasury), "treasury not wired");
        require(address(grai.grinders()) == address(grinders), "grinders not wired");
        require(address(grinders.grai()) == address(grai), "grinders.grai mismatch");
        require(address(grai.weth()) == weth, "weth mismatch");

        console2.log("Deploy complete.");
        console2.log("GRAI:", address(grai));
        console2.log("Treasury:", address(treasury));
        console2.log("Grinders:", address(grinders));
    }

    /// @notice List feeds for each `Network.assets` entry with a non-zero oracle / type.
    function initFeeds(GRAI grai) public {
        Network memory net = _network();
        uint256 maxStaleness = vm.envOr("MAX_STALENESS", net.defaultMaxStaleness);
        for (uint256 i; i < net.assets.length; ++i) {
            AssetData memory a = net.assets[i];
            if (a.oracleType == IPriceOracleRouter.FeedType.NONE || a.oracle == address(0)) continue;
            (IPriceOracleRouter.FeedType feedType,,,,,,,,) = grai.feeds(a.asset);
            if (feedType == IPriceOracleRouter.FeedType.NONE) {
                setFeed(grai, a, maxStaleness);
            } else {
                console2.log("skip setFeed (exists):", a.asset);
            }
        }
    }

    /// @notice GRAI impl + proxy (`initialize(owner, weth)`).
    // forge-lint: disable-next-line(mixed-case-function)
    function deployGRAI(address owner, address weth) public returns (GRAI grai) {
        GRAI impl = new GRAI();
        grai = GRAI(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(GRAI.initialize, (owner, weth))))
        );
        console2.log("GRAI impl:", address(impl));
        console2.log("GRAI proxy:", address(grai));
    }

    //////////////////// TREASURY ////////////////////

    /// @notice Treasury impl + proxy (`initialize(grai)`).
    function deployTreasury(address grai) public returns (Treasury treasury) {
        Treasury impl = new Treasury();
        treasury = Treasury(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(Treasury.initialize, (grai))))
        );
        console2.log("Treasury impl:", address(impl));
        console2.log("Treasury proxy:", address(treasury));
    }

    /// @notice Wire `GRAI.setTreasury(treasury)`.
    function wireTreasury(GRAI grai, address treasury) public {
        grai.setTreasury(treasury);
        console2.log("Wired GRAI.setTreasury:", treasury);
    }

    //////////////////// GRINDERS ////////////////////

    /// @notice Grinders impl + proxy (`initialize(owner, grai)`).
    function deployGrinders(address owner, address grai) public returns (Grinders grinders) {
        Grinders impl = new Grinders();
        grinders = Grinders(
            payable(
                new ERC1967Proxy(address(impl), abi.encodeCall(Grinders.initialize, (owner, grai)))
            )
        );
        console2.log("Grinders impl:", address(impl));
        console2.log("Grinders proxy:", address(grinders));
    }

    /// @notice Wire `GRAI.setGrinders(grinders)`.
    function wireGrinders(GRAI grai, address grinders) public {
        grai.setGrinders(grinders);
        console2.log("Wired GRAI.setGrinders:", grinders);
    }

    //////////////////// SETTERS ////////////////////

    /// @notice `GRAI.setFeed` for one `AssetData` oracle entry.
    function setFeed(GRAI grai, AssetData memory a, uint256 maxStaleness) public {
        IPriceOracleRouter.Feed memory feed = IPriceOracleRouter.Feed({
            feedType: a.oracleType,
            asset: a.asset,
            source: a.oracle,
            decimals: 0,
            data: bytes32(0),
            paused: false,
            storedPrice: 0,
            storedUpdatedAt: 0,
            maxStaleness: maxStaleness
        });
        grai.setFeed(a.asset, feed);
        console2.log("setFeed asset:", a.asset);
        console2.log("  oracleType:", uint8(a.oracleType));
        console2.log("  oracle:", a.oracle);
    }

    /// @notice Mark `assets[i].bribeable` via `setConfig(BRIBEABLE)` (each must be listed).
    function setBribeable() external {
        Network memory net = _network();
        address graiAddr = vm.envAddress("GRAI");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        GRAI grai = GRAI(payable(graiAddr));
        console2.log("GRAI:", graiAddr);
        console2.log("assets:", net.assets.length);
        console2.log("owner:", grai.owner());

        require(grai.owner() == vm.addr(pk), "PRIVATE_KEY is not GRAI owner");

        vm.startBroadcast(pk);
        for (uint256 i; i < net.assets.length; ++i) {
            if (!net.assets[i].bribeable) continue;
            uint256 data = uint256(uint160(net.assets[i].asset)) | (uint256(1) << 160);
            grai.setConfig(IGRAI.ConfigId.BRIBEABLE, data);
            console2.log("setConfig BRIBEABLE:", net.assets[i].asset);
        }
        vm.stopBroadcast();

        for (uint256 i; i < net.assets.length; ++i) {
            if (!net.assets[i].bribeable) continue;
            (,, bool bribeable,,) = grai.assets(net.assets[i].asset);
            require(bribeable, "asset not bribeable");
        }
    }

    //////////////////// COW CUSTODIAN ////////////////////

    function deployCoWCustodian() external returns (CoWCustodian) {
        return deployCoWCustodian(true);
    }

    /// @param setImpl If true, call `Grinders.set(cow, impl)` after deploy.
    function deployCoWCustodian(bool setImpl) public returns (CoWCustodian impl) {
        address grindersAddr = vm.envAddress("GRINDERS");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        Grinders grinders = Grinders(payable(grindersAddr));
        console2.log("Grinders:", grindersAddr);
        console2.log("owner:", grinders.owner());
        console2.log("setImpl:", setImpl);

        require(grindersAddr.code.length > 0, "GRINDERS not a contract");
        if (setImpl) require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        impl = new CoWCustodian();
        bytes32 cowKind = impl.label();
        if (setImpl) grinders.set(cowKind, address(impl));
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("CoWCustodian impl:", address(impl));
        console2.log("COW_SETTLEMENT:", address(impl.COW_SETTLEMENT()));
        console2.log("COW_VAULT_RELAYER:", impl.COW_VAULT_RELAYER());
    }

    //////////////////// LIFI CUSTODIAN ////////////////////

    function deployLiFiCustodianImpl() external returns (LiFiCustodian) {
        return deployLiFiCustodianImpl(true);
    }

    /// @param setImpl If true, call `Grinders.set(lifi, impl)` after deploy (`GRINDERS` required).
    function deployLiFiCustodianImpl(bool setImpl) public returns (LiFiCustodian impl) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address grindersAddr = vm.envOr("GRINDERS", address(0));

        console2.log("setImpl:", setImpl);
        if (setImpl) {
            require(grindersAddr != address(0), "GRINDERS required when setImpl=true");
            Grinders grinders = Grinders(payable(grindersAddr));
            console2.log("Grinders:", grindersAddr);
            console2.log("owner:", grinders.owner());
            require(grindersAddr.code.length > 0, "GRINDERS not a contract");
            require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");
        }

        vm.startBroadcast(pk);
        impl = new LiFiCustodian();
        bytes32 lifiKind = impl.label();
        if (setImpl) Grinders(payable(grindersAddr)).set(lifiKind, address(impl));
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("LiFiCustodian impl:", address(impl));
        console2.log("INPUT_SETTLER_ESCROW:", address(impl.INPUT_SETTLER_ESCROW()));
        console2.log("PERMIT2:", impl.PERMIT2());
    }

    /// @notice Deploy LiFiCustodian impl + ERC1967Proxy.
    /// @dev `initialize` target: `GRINDERS` if set, else deployer EOA (then EOA `register(GRINDERS)`
    ///      and `Grinders.register` completes the 2-step accept). Does not mint NFT / setAssets /
    ///      `Grinders.set` — use `deployLiFiCustodianImpl` for impl-only + set.
    function deployLiFiCustodianProxy() public returns (LiFiCustodian impl, LiFiCustodian proxy) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address grindersAddr = vm.envOr("GRINDERS", address(0));
        address initGrinders = grindersAddr != address(0) ? grindersAddr : deployer;

        if (grindersAddr != address(0)) require(grindersAddr.code.length > 0, "GRINDERS not a contract");

        console2.log("initialize grinders:", initGrinders);

        vm.startBroadcast(pk);
        impl = new LiFiCustodian();
        proxy = LiFiCustodian(
            payable(
                new ERC1967Proxy(address(impl), abi.encodeCall(LiFiCustodian.initialize, (initGrinders)))
            )
        );
        vm.stopBroadcast();

        require(address(proxy.grinders()) == initGrinders, "grinders mismatch");
        require(proxy.label() == impl.label(), "proxy kind mismatch");

        console2.log("Deploy complete.");
        console2.log("LiFiCustodian impl:", address(impl));
        console2.log("LiFiCustodian proxy:", address(proxy));
        console2.log("INPUT_SETTLER_ESCROW:", address(proxy.INPUT_SETTLER_ESCROW()));
        console2.log("PERMIT2:", proxy.PERMIT2());
    }

    function _network() internal view returns (Network memory) {
        return _byChainId(block.chainid);
    }

    function _byChainId(uint256 chainId) internal pure returns (Network memory net) {
        if (chainId == 1) {
            // https://data.chain.link/feeds/ethereum/mainnet/eth-usd
            // https://data.chain.link/feeds/ethereum/mainnet/usdc-usd
            address ethUsd = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
            net.name = "Ethereum";
            net.chainId = 1;
            net.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            net.assets = new AssetData[](3);
            net.assets[0] = AssetData({
                asset: net.weth,
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            });
            net.assets[1] = AssetData({
                asset: address(0),
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            }); // ETH
            net.assets[2] = AssetData({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
                bribeable: true
            });
            net.defaultMaxStaleness = 1 hours;
            return net;
        }
        if (chainId == 42_161) {
            // https://data.chain.link/feeds/arbitrum/mainnet/eth-usd
            // https://data.chain.link/feeds/arbitrum/mainnet/usdc-usd
            address ethUsd = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
            net.name = "Arbitrum";
            net.chainId = 42_161;
            net.weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            net.assets = new AssetData[](3);
            net.assets[0] = AssetData({
                asset: net.weth,
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            });
            net.assets[1] = AssetData({
                asset: address(0),
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            }); // ETH
            net.assets[2] = AssetData({
                asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3, // USDC/USD
                bribeable: true
            });
            net.defaultMaxStaleness = 1 hours;
            return net;
        }
        if (chainId == 8453) {
            // https://data.chain.link/feeds/base/mainnet/eth-usd
            // https://data.chain.link/feeds/base/mainnet/usdc-usd
            address ethUsd = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
            net.name = "Base";
            net.chainId = 8453;
            net.weth = 0x4200000000000000000000000000000000000006;
            net.assets = new AssetData[](3);
            net.assets[0] = AssetData({
                asset: net.weth,
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            });
            net.assets[1] = AssetData({
                asset: address(0),
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            }); // ETH
            net.assets[2] = AssetData({
                asset: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, // USDC/USD
                bribeable: true
            });
            net.defaultMaxStaleness = 1 hours;
            return net;
        }

        if (chainId == 4663) {
            // https://docs.robinhood.com/chain/protocol-contracts/ (L2 Weth)
            address ethUsd = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // ETH/USD proxy
            net.name = "Robinhood";
            net.chainId = 4663;
            net.weth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
            net.assets = new AssetData[](3);
            net.assets[0] = AssetData({
                asset: net.weth,
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            });
            net.assets[1] = AssetData({
                asset: address(0),
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            }); // ETH
            net.assets[2] = AssetData({
                asset: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, // USDG
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                // https://data.chain.link/feeds/robinhood-chain/robinhood-mainnet/usdg-usd-shared-svr
                oracle: 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, // USDG/USD proxy
                bribeable: true
            });
            // Chainlink Robinhood crypto feeds: heartbeat 86400s
            net.defaultMaxStaleness = 24 hours;
            return net;
        }
        if (chainId == 11_155_111) {
            address ethUsd = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
            net.name = "Sepolia";
            net.chainId = 11_155_111;
            net.weth = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
            net.assets = new AssetData[](2);
            net.assets[0] = AssetData({
                asset: net.weth,
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            });
            net.assets[1] = AssetData({
                asset: address(0),
                oracleType: IPriceOracleRouter.FeedType.CHAINLINK,
                oracle: ethUsd,
                bribeable: false
            }); // ETH
            net.defaultMaxStaleness = 1 hours;
            return net;
        }
        revert("unknown chainId");
    }

    function _logNetwork(Network memory net, address owner, address weth) internal pure {
        console2.log("chain:", net.name);
        console2.log("chainId:", net.chainId);
        console2.log("OWNER:", owner);
        console2.log("WETH:", weth);
        console2.log("assets:", net.assets.length);
        for (uint256 i; i < net.assets.length; ++i) {
            console2.log("  asset:", net.assets[i].asset);
            console2.log("  oracleType:", uint8(net.assets[i].oracleType));
            console2.log("  oracle:", net.assets[i].oracle);
            console2.log("  bribeable:", net.assets[i].bribeable);
        }
    }
}
