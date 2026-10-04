// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {Create3Factory} from "./Create3Factory.sol";
import {GRAI, IGRAI, IPriceOracleRouter} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {Grinders} from "../src/Grinders.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";

/// @title Deploy GRAI (CREATE3) on an EVM chain
/// @notice GRAI impl + proxy, Treasury, Grinders, Chainlink feeds.
///         Network is selected from `block.chainid` (`--rpc-url`).
///
/// Env:
///   PRIVATE_KEY       — deployer / initial owner
///   CREATE3_SALT_TAG  — shared salt namespace fallback (default: "grindurus")
///   CREATE3_SALT_TAG_GRAI / _TREASURY / _GRINDERS — per-contract override (vanity)
///   OWNER_MULTISIG    — optional Ownable2Step handoff (`acceptOwnership` required)
///   MAX_STALENESS     — optional seconds (default per-chain)
///   WETH              — optional override of network WETH
///   GRINDERS          — optional override for `deployCoWCustodian()` (else CREATE3 predict)
///
/// Predict addresses only:
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI --sig "predict()" --rpc-url arbitrum
///
/// Simulate deploy (no broadcast — catches reverts, shows addresses):
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI --rpc-url arbitrum
///
/// Deploy (Arbitrum):
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI --rpc-url arbitrum --broadcast --verify
///
/// Post-deploy helpers (owner = `PRIVATE_KEY`):
///   PRIVATE_KEY=0x... GRAI=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "setBribeable()" --rpc-url arbitrum --broadcast
///   PRIVATE_KEY=0x... GRINDERS=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployCoWCustodian()" --rpc-url arbitrum --broadcast --verify
///   # deploy only (skip Grinders.set): --sig "deployCoWCustodian(bool)" false
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

    struct Plan {
        address owner;
        address weth;
        bytes32 saltImpl;
        bytes32 saltProxy;
        bytes implCode;
        bytes proxyCode;
        address impl;
        address proxy;
        bytes32 saltTreasuryImpl;
        bytes32 saltTreasuryProxy;
        bytes treasuryImplCode;
        bytes treasuryProxyCode;
        address treasuryImpl;
        address treasuryProxy;
        bytes32 saltGrindersImpl;
        bytes32 saltGrindersProxy;
        bytes grindersImplCode;
        bytes grindersProxyCode;
        address grindersImpl;
        address grindersProxy;
    }

    function predict() external view {
        Network memory net = _network();
        Plan memory plan = _plan(net);
        _log(net, plan, Create3Factory.isAvailable());
    }

    function run() external {
        Network memory net = _network();
        Plan memory plan = _plan(net);
        _log(net, plan, Create3Factory.isAvailable());

        require(Create3Factory.isAvailable(), "CREATE2 factory missing on this chain");
        require(plan.weth != address(0), "WETH required");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        GRAI grai = deployGRAI(plan);
        Treasury treasury = deployTreasury(plan);
        wireTreasury(grai, address(treasury));
        Grinders grinders = deployGrinders(plan);
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

        require(address(treasury) == plan.treasuryProxy, "treasury address mismatch");
        require(address(grai.treasury()) == address(treasury), "treasury not wired");
        require(address(grai.grinders()) == address(grinders), "grinders not wired");
        require(address(grinders.grai()) == address(grai), "grinders.grai mismatch");
        require(address(grai.weth()) == plan.weth, "weth mismatch");

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

    /// @notice CREATE3 GRAI impl + proxy (`initialize(owner, weth)`).
    // forge-lint: disable-next-line(mixed-case-function)
    function deployGRAI(Plan memory plan) public returns (GRAI grai) {
        address impl = Create3Factory.deploy(plan.saltImpl, plan.implCode);
        require(impl == plan.impl, "grai impl address mismatch");

        address proxy = Create3Factory.deploy(plan.saltProxy, plan.proxyCode);
        require(proxy == plan.proxy, "grai proxy address mismatch");
        grai = GRAI(payable(proxy));
    }

    //////////////////// TREASURY ////////////////////

    /// @notice CREATE3 Treasury impl + proxy (`initialize(grai)`).
    function deployTreasury(Plan memory plan) public returns (Treasury treasury) {
        address impl = Create3Factory.deploy(plan.saltTreasuryImpl, plan.treasuryImplCode);
        require(impl == plan.treasuryImpl, "treasury impl address mismatch");

        address proxy = Create3Factory.deploy(plan.saltTreasuryProxy, plan.treasuryProxyCode);
        require(proxy == plan.treasuryProxy, "treasury proxy address mismatch");
        treasury = Treasury(payable(proxy));
    }

    /// @notice Wire `GRAI.setTreasury(treasury)`.
    function wireTreasury(GRAI grai, address treasury) public {
        grai.setTreasury(treasury);
        console2.log("Wired GRAI.setTreasury:", treasury);
    }

    //////////////////// GRINDERS ////////////////////

    /// @notice CREATE3 Grinders impl + proxy (`initialize(owner, grai)`).
    function deployGrinders(Plan memory plan) public returns (Grinders grinders) {
        address impl = Create3Factory.deploy(plan.saltGrindersImpl, plan.grindersImplCode);
        require(impl == plan.grindersImpl, "grinders impl address mismatch");

        address proxy = Create3Factory.deploy(plan.saltGrindersProxy, plan.grindersProxyCode);
        require(proxy == plan.grindersProxy, "grinders proxy address mismatch");
        grinders = Grinders(payable(proxy));
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
        Plan memory plan = _plan(net);
        address graiAddr = vm.envOr("GRAI", plan.proxy);
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

    /// @param setImpl If true, call `Grinders.set(cow, impl)` after deploy.
    function deployCoWCustodian(bool setImpl) public returns (CoWCustodian impl) {
        Network memory net = _network();
        Plan memory plan = _plan(net);
        address grindersAddr = vm.envOr("GRINDERS", plan.grindersProxy);
        uint256 pk = vm.envUint("PRIVATE_KEY");

        Grinders grinders = Grinders(payable(grindersAddr));
        console2.log("Grinders:", grindersAddr);
        console2.log("owner:", grinders.owner());
        console2.log("setImpl:", setImpl);

        require(grindersAddr.code.length > 0, "GRINDERS not a contract");
        if (setImpl) require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        impl = new CoWCustodian();
        bytes32 cowKind = keccak256("grindurus.custodian.cow");
        require(impl.custodianKind() == cowKind, "unexpected custodianKind");
        if (setImpl) grinders.set(cowKind, address(impl));
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("CoWCustodian impl:", address(impl));
        console2.log("COW_SETTLEMENT:", address(impl.COW_SETTLEMENT()));
        console2.log("COW_VAULT_RELAYER:", impl.COW_VAULT_RELAYER());
    }

    function _plan(Network memory net) internal view returns (Plan memory plan) {
        plan.owner = vm.addr(vm.envUint("PRIVATE_KEY"));
        plan.weth = vm.envOr("WETH", net.weth);

        // Per-contract tags keep vanity independent; unset → CREATE3_SALT_TAG → "grindurus".
        string memory graiTag = _componentSaltTag("CREATE3_SALT_TAG_GRAI");
        string memory treasuryTag = _componentSaltTag("CREATE3_SALT_TAG_TREASURY");
        string memory grindersTag = _componentSaltTag("CREATE3_SALT_TAG_GRINDERS");

        plan.saltImpl = Create3Factory.makeSalt("GRAI/impl", graiTag);
        plan.saltProxy = Create3Factory.makeSalt("GRAI/proxy", graiTag);
        plan.implCode = type(GRAI).creationCode;
        plan.impl = Create3Factory.computeAddress(plan.saltImpl);
        plan.proxyCode = Create3Factory.proxyCreationCode(
            plan.impl, abi.encodeCall(GRAI.initialize, (plan.owner, plan.weth))
        );
        plan.proxy = Create3Factory.computeAddress(plan.saltProxy);

        plan.saltTreasuryImpl = Create3Factory.makeSalt("Treasury/impl", treasuryTag);
        plan.saltTreasuryProxy = Create3Factory.makeSalt("Treasury/proxy", treasuryTag);
        plan.treasuryImplCode = type(Treasury).creationCode;
        plan.treasuryImpl = Create3Factory.computeAddress(plan.saltTreasuryImpl);
        plan.treasuryProxyCode = Create3Factory.proxyCreationCode(
            plan.treasuryImpl, abi.encodeCall(Treasury.initialize, (plan.proxy))
        );
        plan.treasuryProxy = Create3Factory.computeAddress(plan.saltTreasuryProxy);

        plan.saltGrindersImpl = Create3Factory.makeSalt("Grinders/impl", grindersTag);
        plan.saltGrindersProxy = Create3Factory.makeSalt("Grinders/proxy", grindersTag);
        plan.grindersImplCode = type(Grinders).creationCode;
        plan.grindersImpl = Create3Factory.computeAddress(plan.saltGrindersImpl);
        plan.grindersProxyCode = Create3Factory.proxyCreationCode(
            plan.grindersImpl, abi.encodeCall(Grinders.initialize, (plan.owner, plan.proxy))
        );
        plan.grindersProxy = Create3Factory.computeAddress(plan.saltGrindersProxy);
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

    function _saltTag() internal view returns (string memory) {
        try vm.envString("CREATE3_SALT_TAG") returns (string memory tag) {
            if (bytes(tag).length != 0) return tag;
        } catch {}
        return vm.envOr("CREATE2_SALT_TAG", string("grindurus"));
    }

    /// @dev `CREATE3_SALT_TAG_<COMPONENT>` if set, else shared `_saltTag()`.
    function _componentSaltTag(string memory envKey) internal view returns (string memory) {
        try vm.envString(envKey) returns (string memory tag) {
            if (bytes(tag).length != 0) return tag;
        } catch {}
        return _saltTag();
    }

    function _log(Network memory net, Plan memory plan, bool factoryAvailable) internal view {
        console2.log("chain:", net.name);
        console2.log("chainId:", net.chainId);
        console2.log("CREATE3 factory available:", factoryAvailable);
        console2.log("CREATE3_SALT_TAG_GRAI:", _componentSaltTag("CREATE3_SALT_TAG_GRAI"));
        console2.log("CREATE3_SALT_TAG_TREASURY:", _componentSaltTag("CREATE3_SALT_TAG_TREASURY"));
        console2.log("CREATE3_SALT_TAG_GRINDERS:", _componentSaltTag("CREATE3_SALT_TAG_GRINDERS"));
        console2.log("OWNER:", plan.owner);
        console2.log("WETH:", plan.weth);
        console2.log("assets:", net.assets.length);
        for (uint256 i; i < net.assets.length; ++i) {
            console2.log("  asset:", net.assets[i].asset);
            console2.log("  oracleType:", uint8(net.assets[i].oracleType));
            console2.log("  oracle:", net.assets[i].oracle);
            console2.log("  bribeable:", net.assets[i].bribeable);
        }
        console2.log("GRAI impl:", plan.impl);
        console2.log("GRAI proxy:", plan.proxy);
        console2.log("Treasury impl:", plan.treasuryImpl);
        console2.log("Treasury proxy:", plan.treasuryProxy);
        console2.log("Grinders impl:", plan.grindersImpl);
        console2.log("Grinders proxy:", plan.grindersProxy);
    }

}
