// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GRAI, IGRAI, IPriceOracleRouter} from "../src/GRAI.sol";
import {Treasury} from "../src/Treasury.sol";
import {Grinders} from "../src/Grinders.sol";
import {CoWCustodian} from "../src/custodians/CoWCustodian.sol";
import {LiFiCustodian} from "../src/custodians/LiFiCustodian.sol";
import {SwapCustodian} from "../src/custodians/SwapCustodian.sol";
import {CreateXDeploy} from "./CreateXDeploy.sol";

/// @title Deploy GRAI on an EVM chain
/// @notice GRAI + Treasury + Grinders (impl + ERC1967 proxy each), feeds.
///         Network from `block.chainid` (`--rpc-url`).
///         If CreateX is on-chain → CREATE3 (vanity salts); else plain `new` CREATE.
///
/// CREATE3 frontrun / initcode protection (CreateX `_guard`, when CreateX present):
///   - salt[0:20] = deployer (`PRIVATE_KEY` addr) → only that EOA can use the salt
///   - salt[20]   = `0x00` → same address across chains (no chainId in guarded salt)
///   - salt[21:32]= per-contract id (`keccak256(label)` truncated to u88)
///   - Proxy `initialize(...)` is baked into ERC1967Proxy creation bytecode → atomic with deploy
///     (no uninitialized-proxy window).
///
/// Env:
///   PRIVATE_KEY       — deployer; GRAI initial owner + Grinders toreador; salt guardian
///   OWNER_MULTISIG    — optional GRAI Ownable2Step handoff (`acceptOwnership` required);
///                       Grinders.owner() follows GRAI (no separate Grinders handoff)
///   MAX_STALENESS     — optional seconds (default per-chain)
///   WETH              — optional override of network WETH
///   CREATEX           — optional CreateX override (default canonical)
///   GRAI_PROXY_SALT_ID — optional uint88 CreateX salt id for GRAI proxy (vanity; from mine_create3.py)
///   TREASURY_PROXY_SALT_ID — optional uint88 for Treasury proxy vanity
///   GRINDERS_PROXY_SALT_ID — optional uint88 for Grinders proxy vanity
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
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "setBribeable(address)" 0xGRAI --rpc-url arbitrum --broadcast
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployCoWCustodian(address,address,bool)" 0xGrinders 0x0 true \
///     --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deploySwapCustodian(address,address,bool)" 0xGrinders 0x0 true \
///     --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "deployLiFiCustodian(address,address,bool)" 0xGrinders 0x0 true \
///     --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "upgradeGraiImpl(address,address)" 0xGraiProxy 0x0 \
///     --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "upgradeTreasuryImpl(address,address)" 0xTreasuryProxy 0x0 \
///     --rpc-url arbitrum --broadcast --verify
///   PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
///     --sig "upgradeGrindersImpl(address,address)" 0xGrindersProxy 0x0 \
///     --rpc-url arbitrum --broadcast --verify
contract DeployGRAI is CreateXDeploy {
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
        if (_hasCreateX()) {
            console2.log("Deploy mode: CreateX CREATE3", address(_createX()));
        } else {
            console2.log("Deploy mode: CREATE (CreateX missing on chain)");
        }

        _logNetwork(net, owner, weth);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        GRAI grai = deployGRAI(owner, weth);
        
        Treasury treasury = deployTreasury(address(grai), owner);
        setTreasury(grai, address(treasury));
        
        Grinders grinders = deployGrinders(address(grai), owner);
        setGrinders(grai, address(grinders));

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
            console2.log("Pending GRAI owner (call acceptOwnership); Grinders.owner() follows GRAI:", ownerMultisig);
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

    //////////////////// GRAI ////////////////////

    /// @notice GRAI impl + proxy (`initialize` in proxy initcode). CreateX CREATE3 if available, else `new`.
    // forge-lint: disable-next-line(mixed-case-function)
    function deployGRAI(address owner, address weth) public returns (GRAI grai) {
        address impl;
        if (_hasCreateX()) {
            impl = _deployCreate3("grindurus.grai.impl.v1", type(GRAI).creationCode);
            bytes memory proxyInitCode = abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(GRAI.initialize, (owner, weth)))
            );
            uint88 proxySaltId = uint88(
                vm.envOr("GRAI_PROXY_SALT_ID", uint256(_saltId("grindurus.grai.proxy")))
            );
            grai = GRAI(payable(_deployCreate3("grindurus.grai.proxy", proxySaltId, proxyInitCode)));
        } else {
            impl = address(new GRAI());
            grai = GRAI(
                payable(new ERC1967Proxy(impl, abi.encodeCall(GRAI.initialize, (owner, weth))))
            );
        }
        console2.log("GRAI impl:", impl);
        console2.log("GRAI proxy:", address(grai));
    }

    /// @notice UUPS-upgrade GRAI proxy to `impl`. If `impl == address(0)`, deploy a new `GRAI` impl first.
    /// @dev Caller must be protocol owner (`grai.owner()`). Storage layout is preserved.
    ///      Safe without a dividend-debt migrate when `totalVoted == 0` (debts already on full `locked`).
    /// @param graiProxy Existing GRAI ERC1967 proxy.
    /// @param impl Existing GRAI impl, or `address(0)` to deploy a new one.
    function upgradeGraiImpl(address graiProxy, address impl) public returns (address implementation) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        GRAI grai = GRAI(payable(graiProxy));

        console2.log("GRAI proxy:", graiProxy);
        console2.log("owner:", grai.owner());
        console2.log("treasury:", address(grai.treasury()));
        console2.log("grinders:", address(grai.grinders()));
        console2.log("totalLocked:", grai.totalLocked());
        console2.log("totalVoted:", grai.totalVoted());
        console2.log("impl:", impl);

        require(graiProxy.code.length > 0, "GRAI not a contract");
        require(grai.owner() == vm.addr(pk), "PRIVATE_KEY is not GRAI owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = address(new GRAI());
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = impl;
        }
        grai.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        console2.log("GRAI impl (upgraded):", implementation);
        console2.log("GRAI proxy:", graiProxy);
        console2.log("totalSupply:", grai.totalSupply());
        console2.log("totalLocked:", grai.totalLocked());
        console2.log("totalVoted:", grai.totalVoted());
    }

    //////////////////// TREASURY ////////////////////

    /// @notice Treasury impl + proxy (`initialize` in proxy initcode). CreateX CREATE3 if available, else `new`.
    function deployTreasury(address grai, address beneficiar) public returns (Treasury treasury) {
        address impl;
        if (_hasCreateX()) {
            impl = _deployCreate3("grindurus.treasury.impl.v1", type(Treasury).creationCode);
            bytes memory proxyInitCode = abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(Treasury.initialize, (grai, beneficiar)))
            );
            uint88 proxySaltId = uint88(
                vm.envOr("TREASURY_PROXY_SALT_ID", uint256(_saltId("grindurus.treasury.proxy")))
            );
            treasury = Treasury(payable(_deployCreate3("grindurus.treasury.proxy", proxySaltId, proxyInitCode)));
        } else {
            impl = address(new Treasury());
            treasury = Treasury(
                payable(new ERC1967Proxy(impl, abi.encodeCall(Treasury.initialize, (grai, beneficiar))))
            );
        }
        console2.log("Treasury impl:", impl);
        console2.log("Treasury proxy:", address(treasury));
    }

    /// @notice Wire `GRAI.setTreasury(treasury)`.
    function setTreasury(GRAI grai, address treasury) public {
        grai.setTreasury(treasury);
        console2.log("Wired GRAI.setTreasury:", treasury);
    }

    /// @notice UUPS-upgrade Treasury proxy to `impl`. If `impl == address(0)`, deploy a new `Treasury` impl first.
    /// @param treasuryProxy Existing Treasury ERC1967 proxy.
    /// @param impl Existing Treasury impl, or `address(0)` to deploy a new one.
    function upgradeTreasuryImpl(address treasuryProxy, address impl) public returns (address implementation) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Treasury treasury = Treasury(payable(treasuryProxy));

        console2.log("Treasury proxy:", treasuryProxy);
        console2.log("owner:", treasury.owner());
        console2.log("impl:", impl);

        require(treasuryProxy.code.length > 0, "TREASURY not a contract");
        require(treasury.owner() == vm.addr(pk), "PRIVATE_KEY is not Treasury owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = address(new Treasury());
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = impl;
        }
        treasury.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        console2.log("Treasury impl (upgraded):", implementation);
        console2.log("Treasury proxy:", treasuryProxy);
    }

    //////////////////// GRINDERS ////////////////////

    /// @notice Grinders impl + proxy (`initialize` in proxy initcode). CreateX CREATE3 if available, else `new`.
    function deployGrinders(address grai, address toreador) public returns (Grinders grinders) {
        address impl;
        if (_hasCreateX()) {
            impl = _deployCreate3("grindurus.grinders.impl.v1", type(Grinders).creationCode);
            bytes memory proxyInitCode = abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(Grinders.initialize, (grai, toreador)))
            );
            uint88 proxySaltId = uint88(
                vm.envOr("GRINDERS_PROXY_SALT_ID", uint256(_saltId("grindurus.grinders.proxy")))
            );
            grinders = Grinders(payable(_deployCreate3("grindurus.grinders.proxy", proxySaltId, proxyInitCode)));
        } else {
            impl = address(new Grinders());
            grinders = Grinders(
                payable(new ERC1967Proxy(impl, abi.encodeCall(Grinders.initialize, (grai, toreador))))
            );
        }
        console2.log("Grinders impl:", impl);
        console2.log("Grinders proxy:", address(grinders));
        console2.log("Grinders toreador:", toreador);
    }

    /// @notice Wire `GRAI.setGrinders(grinders)`.
    function setGrinders(GRAI grai, address grinders) public {
        grai.setGrinders(grinders);
        console2.log("Wired GRAI.setGrinders:", grinders);
    }

    /// @notice UUPS-upgrade Grinders proxy to `impl`. If `impl == address(0)`, deploy a new `Grinders` impl first.
    /// @dev Caller must be protocol owner (`Grinders.owner()` == `grai.owner()`). Storage layout is preserved.
    /// @param grindersProxy Existing Grinders ERC1967 proxy.
    /// @param impl Existing Grinders impl, or `address(0)` to deploy a new one.
    function upgradeGrindersImpl(address grindersProxy, address impl) public returns (address implementation) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Grinders grinders = Grinders(payable(grindersProxy));

        console2.log("Grinders proxy:", grindersProxy);
        console2.log("owner:", grinders.owner());
        console2.log("toreador:", grinders.toreador());
        console2.log("impl:", impl);

        require(grindersProxy.code.length > 0, "GRINDERS not a contract");
        require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = address(new Grinders());
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = impl;
        }
        grinders.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        console2.log("Grinders impl (upgraded):", implementation);
        console2.log("Grinders proxy:", grindersProxy);
        console2.log("totalSupply:", grinders.totalSupply());
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
    /// @param grai GRAI proxy.
    function setBribeable(GRAI grai) external {
        Network memory net = _network();
        uint256 pk = vm.envUint("PRIVATE_KEY");

        console2.log("GRAI:", address(grai));
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
            (,, bool bribeable,,,) = grai.assets(net.assets[i].asset);
            require(bribeable, "asset not bribeable");
        }
    }

    //////////////////// COW CUSTODIAN ////////////////////

    /// @param grindersAddr Grinders proxy — registers impl via `Grinders.set` and used for proxy `initialize`.
    /// @param impl Existing CoW impl, or `address(0)` to deploy a new one.
    /// @param deployProxy If true, also deploy an ERC1967 proxy (`initialize(grindersAddr)`).
    function deployCoWCustodian(address grindersAddr, address impl, bool deployProxy)
        public
        returns (CoWCustodian implementation, CoWCustodian proxy)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        Grinders grinders = Grinders(payable(grindersAddr));
        console2.log("Grinders:", grindersAddr);
        console2.log("owner:", grinders.owner());
        console2.log("impl:", impl);
        console2.log("deployProxy:", deployProxy);

        require(grindersAddr.code.length > 0, "GRINDERS not a contract");
        require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = new CoWCustodian();
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = CoWCustodian(payable(impl));
        }
        grinders.set(implementation.label(), address(implementation));

        if (deployProxy) {
            proxy = CoWCustodian(
                payable(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(CoWCustodian.initialize, (grindersAddr))
                    )
                )
            );
        }
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("CoWCustodian impl:", address(implementation));
        if (deployProxy) console2.log("CoWCustodian proxy:", address(proxy));
        console2.log("COW_SETTLEMENT:", address(implementation.COW_SETTLEMENT()));
        console2.log("COW_VAULT_RELAYER:", implementation.COW_VAULT_RELAYER());
    }

    //////////////////// SWAP CUSTODIAN ////////////////////

    /// @param grindersAddr Grinders proxy — registers impl via `Grinders.set` and used for proxy `initialize`.
    /// @param impl Existing Swap impl, or `address(0)` to deploy a new one.
    /// @param deployProxy If true, also deploy an ERC1967 proxy (`initialize(grindersAddr)`).
    function deploySwapCustodian(address grindersAddr, address impl, bool deployProxy)
        public
        returns (SwapCustodian implementation, SwapCustodian proxy)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        Grinders grinders = Grinders(payable(grindersAddr));
        console2.log("Grinders:", grindersAddr);
        console2.log("owner:", grinders.owner());
        console2.log("impl:", impl);
        console2.log("deployProxy:", deployProxy);

        require(grindersAddr.code.length > 0, "GRINDERS not a contract");
        require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = new SwapCustodian();
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = SwapCustodian(payable(impl));
        }
        grinders.set(implementation.label(), address(implementation));

        if (deployProxy) {
            proxy = SwapCustodian(
                payable(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(SwapCustodian.initialize, (grindersAddr))
                    )
                )
            );
        }
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("SwapCustodian impl:", address(implementation));
        if (deployProxy) console2.log("SwapCustodian proxy:", address(proxy));
        console2.log("COW_SETTLEMENT:", address(implementation.COW_SETTLEMENT()));
        console2.log("COW_VAULT_RELAYER:", implementation.COW_VAULT_RELAYER());
    }

    //////////////////// LIFI CUSTODIAN ////////////////////

    /// @param grindersAddr Grinders proxy — registers impl via `Grinders.set` and used for proxy `initialize`.
    /// @param impl Existing LiFi impl, or `address(0)` to deploy a new one.
    /// @param deployProxy If true, also deploy an ERC1967 proxy (`initialize(grindersAddr)`).
    function deployLiFiCustodian(address grindersAddr, address impl, bool deployProxy)
        public
        returns (LiFiCustodian implementation, LiFiCustodian proxy)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        Grinders grinders = Grinders(payable(grindersAddr));
        console2.log("Grinders:", grindersAddr);
        console2.log("owner:", grinders.owner());
        console2.log("impl:", impl);
        console2.log("deployProxy:", deployProxy);

        require(grindersAddr.code.length > 0, "GRINDERS not a contract");
        require(grinders.owner() == vm.addr(pk), "PRIVATE_KEY is not Grinders owner");

        vm.startBroadcast(pk);
        if (impl == address(0)) {
            implementation = new LiFiCustodian();
        } else {
            require(impl.code.length > 0, "impl not a contract");
            implementation = LiFiCustodian(payable(impl));
        }
        grinders.set(implementation.label(), address(implementation));

        if (deployProxy) {
            proxy = LiFiCustodian(
                payable(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(LiFiCustodian.initialize, (grindersAddr))
                    )
                )
            );
        }
        vm.stopBroadcast();

        console2.log("Deploy complete.");
        console2.log("LiFiCustodian impl:", address(implementation));
        if (deployProxy) console2.log("LiFiCustodian proxy:", address(proxy));
        console2.log("INPUT_SETTLER_ESCROW:", address(implementation.INPUT_SETTLER_ESCROW()));
        console2.log("PERMIT2:", implementation.PERMIT2());
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
