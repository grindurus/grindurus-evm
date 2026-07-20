# GRAI — Grinders Artificial Index

GRAI is a USD-denominated fund-share token. Users `deposit` a supported asset
into `Grinders` custody and receive GRAI at the current book value. Redemption
is disabled during normal operation and becomes available only after liquidation opens.

Protocol yield flows through `distribute`: a global `treasuryShare` cut goes to `treasury`; the
remainder is Dutch-auctioned (or kept when it is already `settlementAsset`).

Buyback inventory (`settlementAsset` retained from bribes and settlement-yield) is swapped for GRAI
via **`Grinders.buyback`**; acquired GRAI funds vote rewards for escrowed voters.

## Model

```
deposit(asset) →  asset to Grinders  →  GRAI issued at book value (totalValue ↑)
                      ↓
              Grinders / custodians earn yield
                      ↓
distribute(asset)          [custodian or any payer]
   ├─ treasuryShare → treasury
   └─ yieldShare
        ├─ asset == settlementAsset → stay on GRAI
        └─ otherwise → Dutch auction → buyers pay settlementAsset into GRAI
                      ↓
fill(asset)                [permissionless]
   buyer receives yield asset; settlementAsset payment accrues on GRAI
                      ↓
bribe(voter)               [permissionless; works even during liquidation]
   briber pays settlementAsset; voter gets book body; premium → treasury / buyback inventory
                      ↓
buyback(data)              [ADMIN_ROLE on GRAI]
   GRAI forwards settlement → Grinders → router swap → GRAI; vote rewards credited
```

| Contract | Role |
|----------|------|
| `GRAI` | UUPS ERC20 fund share + oracle router + yield auctions + vote/liquidation/buyback entry. Implements [ERC-1046](https://eips.ethereum.org/EIPS/eip-1046). |
| `Grinders` | ERC-721 **Grinders Custodians** collection, custodian proxy wallets, `allocate` / `deallocate`, **buyback swap routing** (upgrade surface for DEX calls). |
| `Custodian` | Per-NFT wallet base class: `distribute`, `deallocate`, `liquidate`. |
| `*Custodian` | Kind-specific swap modules (`SwapCustodian`, `CoWCustodian`, `LiFiCustodian`, …). |
| `PriceOracleRouter` | Base of `GRAI`. Chainlink / Pyth / custom feeds per asset. |

Native ETH is `address(0)`.

## Grinders & custodians

Each `Grinders.mint(custodianKind, base, quote, owner)` deploys an ERC-1967 proxy custodian wallet
(NFT `#id`) and registers it in the custodian index. The NFT owner controls swaps; Grinders owner
(`allocate`) moves working capital from the Grinders reserve into custodian wallets.

| Kind constant | Implementation | Swap path |
|---------------|----------------|-----------|
| `keccak256("grindurus.custodian.explicit_swap")` | `SwapCustodian` | Arbitrary router `call` + on-chain price limit |
| `keccak256("grindurus.custodian.cow")` | `CoWCustodian` | CoW Protocol EIP-1271 orders |
| `keccak256("grindurus.custodian.lifi")` | `LiFiCustodian` | LiFi routing |

`allocated[custodian][asset]` is an issuance ledger only — not a deallocate cap (custodians may
return a different token/size after swaps).

## Lifecycle

```
initialize(admin, weth)
   ↓
setFeed(asset, feed) + setAssetConfig(paused)   // list asset
setProtocolConfig({ treasuryShare, bribePremiumBps, … })
setSettlementAsset(usdc)
setGrinders(grinders)
   ↓
deposit(asset, amount)                         // capital → Grinders; GRAI at book value
   ↓
distribute(asset, yieldAmount)                 // treasury skim + auction or retain settlement
   ↓
fill(asset, amount, paymentMax)                // buy yield lot; pay settlementAsset
   ↓
vote(graiAmount) / bribe(voter, graiAmount)    // liquidation quorum + buyouts
   ↓
resolve()                                      // open/close liquidation (ADMIN_ROLE)
   ↓
Grinders.liquidate(…) + GRAI.liquidate(…)     // sweep custodians; pro-rata redeem basket
   ↓
buyback(data)                                  // swap settlement inventory → GRAI → vote rewards
```

For native ETH call `deposit` / `distribute` / `fill` / `bribe` with `{value: …}` when required.

## Tokenomics (USD scaled to 6 decimals)

- `depositValue = usdValue(asset, amount)` (oracle; `USD_DECIMALS = 6`)
- **deposit:** `graiOut = depositValue * totalSupply / totalValue`; initial deposit is 1 GRAI per $1
- **liquidate during open liquidation only** — burns GRAI for a pro-rata share of every asset
  held by GRAI; Grinders returns liquidated custodian assets by transferring them to GRAI;
  after the claim window closes via `resolve`, leftover balances return to Grinders and unclaimed GRAI
  retains its proportionally reduced book value
- **distribute:** `treasuryShare = received * config.treasuryShare / 10000`, rest auctioned as yield
- **auction:** one open lot per sold asset; `maxPayment` = oracle fair value of the lot in
  `settlementAsset` units; price decays linearly to **0** over `config.auctionDuration` (default
  **365 days**); repeated distributes merge inventory and restart the clock at the new fair value
- **fill:** buyer receives the yield asset; `settlementAsset` payment accrues on GRAI
  (partial fills supported; zero price after duration expiry is valid)
- **bribe:** `previewBribe` prices book value + premium in `settlementAsset`; body goes to voter,
  premium split like yield (`treasuryShare` to treasury, remainder stays on GRAI as buyback inventory)
- **buyback:** admin forwards all GRAI-held `settlementAsset` to Grinders, Grinders executes
  `target.call(swapCalldata)`, forwards received GRAI back; GRAI credits `rewardPerVote` /
  `pendingVoteRewards` from the GRAI balance delta

> GRAI holders do not claim distributed yield directly. Yield is sold for `settlementAsset`, which
> accrues on GRAI and is used by bribes / buybacks / vote rewards.

### Buyback calldata

GRAI is a thin entry point; router selection lives on upgradeable Grinders:

```solidity
// GRAI.buyback — ADMIN_ROLE
bytes memory data = abi.encode(router, swapCalldata);
(uint256 payment, uint256 graiOut) = grai.buyback(data);

// Grinders.buyback — GRAI-only caller (called internally via CPI from GRAI)
// Uses full settlement balance already forwarded by GRAI.
```

`payment` is the settlement spent; `graiOut` must be > 0 or GRAI reverts `InvalidBuyback`.
Reverts while `liquidation` is open (same as `deposit`, `fill`, `distribute`, `buyback`).

## Access control

`GRAI` uses OpenZeppelin `AccessControlEnumerable` with three roles. The oracle router is a
base class of `GRAI` (not a separate contract), so feed management is a `GRAI` role — there is
no separate oracle `owner`.

| Role | ID | Permissions |
|------|----|-------------|
| `DEFAULT_ADMIN_ROLE` | `0x00…00` (OZ default) | UUPS upgrades; protocol wiring (`setProtocolConfig`, `setGrinders`, `setTreasury`, `setSettlementAsset`); grant/revoke all roles |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Day-to-day asset ops: list/delist feeds, asset pause, liquidation resolve, **buyback** |
| `GRINDERS_ROLE` | `keccak256("GRINDERS_ROLE")` | Granted to the wired Grinders proxy (internal; not for EOAs) |

`Grinders` is `OwnableUpgradeable`: owner registers custodian implementations, mints NFTs, `allocate`s
capital. **`buyback` on Grinders is callable only by the wired GRAI contract** (`NotGrai` otherwise).

### `DEFAULT_ADMIN_ROLE` functions

- `setProtocolConfig` — `treasuryShare`, `bribePremiumBps`, `liquidationQuorumBps`, auction/liquidation/redeem timing
- `setGrinders` — wire the Grinders yield pool (validates `grinders.grai() == this`; grants `GRINDERS_ROLE`)
- `setTreasury` — protocol profit recipient
- `setSettlementAsset` — auction/bribe/buyback settlement asset (must have a feed; reverts with open auctions/votes)
- `_authorizeUpgrade` — UUPS implementation swap

### `ADMIN_ROLE` functions

- `setFeed` — set a price feed (**lists** the asset); clearing it (`feedType = FEED_NONE`) **delists** it
- `setAssetConfig` — per-asset `paused` flag only
- `resolve` — flip the liquidation flag (opening requires vote quorum, `hasQuorum()`)
- `buyback` — swap settlement inventory via Grinders and credit vote rewards

### Permissionless (any caller)

- `deposit`, `distribute`, `fill`, `liquidate` (`liquidate` requires open liquidation)
- `vote` (irreversible escrow toward liquidation quorum)
- `bribe` (third-party or self buyout; **not** blocked during liquidation)
- `Grinders.liquidate` / `Grinders.liquidate(fromId, toId)` while GRAI liquidation is open
- views: `previewDeposit`, `previewFill`, `previewBribe`, `previewLiquidate`, `getAssets`, `getAuctions`, `getVoters`, `balance`, `tokenURI`

On deploy, `initialize(admin, weth)` grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to `admin`, sets
`treasury = admin`, and points `grinders` at the contract itself until wired. For
production, split roles across separate multisigs:

```solidity
// Ops multisig — asset/liquidation/buyback ops, no upgrade or wiring rights
grai.grantRole(grai.ADMIN_ROLE(), opsMultisig);
grai.revokeRole(grai.ADMIN_ROLE(), deployer);

// Upgrade/wiring multisig — upgrades + set{ProtocolConfig,Grinders,Treasury,SettlementAsset}
grai.grantRole(grai.DEFAULT_ADMIN_ROLE(), upgradeMultisig);
grai.revokeRole(grai.DEFAULT_ADMIN_ROLE(), deployer);
```

`DEFAULT_ADMIN_ROLE` is the role admin for every role and can grant or revoke it.

## Usage

```shell
forge build
forge test
forge test --no-match-path "test/fork/*"   # unit tests only
forge fmt
```

### Deploy

`script/Deploy.s.sol` uses the CREATE2 factory (Nick's deterministic deployer) to create
**four** contracts at deterministic addresses — the `GRAI` implementation + ERC-1967 proxy and
the `Grinders` implementation + ERC-1967 proxy — then wires `GRAI.setGrinders(grinders)`.

```shell
# Predict addresses (no broadcast)
PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy --sig "predict()"

# Deploy
PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy \
  --rpc-url <your_rpc_url> --broadcast
```

The deployer (`vm.addr(PRIVATE_KEY)`) becomes `admin`. Optional env vars split roles at deploy
time: `OPS_MULTISIG` (receives `ADMIN_ROLE`), `UPGRADE_MULTISIG` (receives
`DEFAULT_ADMIN_ROLE` and the `Grinders` ownership). `CREATE2_SALT_TAG` changes the salt
namespace; `DRY_RUN=1` predicts without broadcasting.

After deployment, list each asset by setting its feed (this also registers it in `GRAI`), then
wire protocol config. All calls require `ADMIN_ROLE` unless noted:

```solidity
// Chainlink (Ethereum mainnet USDC/USD)
grai.setFeed(USDC, IPriceOracleRouter.Feed({
    feedType: 2, // FEED_CHAINLINK
    asset: USDC,
    source: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD aggregator
    data: bytes32(0),
    decimals: 0,          // read from the aggregator
    storedPrice: 0,
    storedUpdatedAt: 0,
    maxStaleness: 1 hours
}));
grai.setAssetConfig(USDC, IGRAI.AssetConfig({ asset: USDC, id: 0, paused: false }));

// Global treasury cut (20%) and bribe premium (2%) — DEFAULT_ADMIN_ROLE
grai.setProtocolConfig(IGRAI.ProtocolConfig({
    treasuryShare: 2_000,
    bribePremiumBps: 200,
    liquidationQuorumBps: 6_667,
    auctionDuration: uint32(365 days),
    liquidationPeriod: uint32(24 hours),
    redeemPeriod: uint32(7 days)
}));

// Pyth (source = per-network Pyth contract, data = shared price id)
grai.setFeed(WETH, IPriceOracleRouter.Feed({
    feedType: 3, // FEED_PYTH
    asset: WETH,
    source: 0x4305FB66699C3B2702D4d05CF36551390A4c69C6, // Ethereum Pyth
    data: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, // ETH/USD price id
    decimals: 0,          // derived from Pyth expo
    storedPrice: 0,
    storedUpdatedAt: 0,
    maxStaleness: 1 hours
}));

// Native ETH — use address(0) with an ETH/USD feed
grai.setFeed(address(0), IPriceOracleRouter.Feed({
    feedType: 2,
    asset: address(0),
    source: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH/USD aggregator
    data: bytes32(0),
    decimals: 0,
    storedPrice: 0,
    storedUpdatedAt: 0,
    maxStaleness: 1 hours
}));
// deposit ETH: grai.deposit{value: 1 ether}(address(0), 1 ether);
```

`cfg.asset` and `cfg.id` in `setAssetConfig` are ignored (the `asset` param and internal index
are authoritative). To **delist** an asset, pause it, drain its balance, then
`setFeed(asset, feed)` with `feedType = FEED_NONE` (0).

Register custodian kinds on Grinders (owner), then mint custodian NFTs:

```solidity
grinders.set(keccak256("grindurus.custodian.explicit_swap"), swapCustodianImpl);
address custodian = grinders.mint(
    keccak256("grindurus.custodian.explicit_swap"),
    USDC,
    WETH,
    grinder
);
grinders.allocate(custodian, USDC, amount);
```

## Chainlink price feed addresses (mainnets)

Chainlink Data Feeds are proxies implementing `AggregatorV3Interface`. Always verify against
the [official Chainlink address list](https://docs.chain.link/data-feeds/price-feeds/addresses)
before deploying.

### Ethereum Mainnet

| Pair | Proxy address | Decimals |
|------|---------------|----------|
| ETH/USD  | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 8 |
| BTC/USD  | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` | 8 |
| USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | 8 |
| LINK/USD | `0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c` | 8 |

### Arbitrum One

| Pair | Proxy address | Decimals |
|------|---------------|----------|
| ETH/USD  | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | 8 |
| WBTC/USD | `0xd0C7101eACbB49F3deCcCc166d238410D6D46d57` | 8 |
| USDC/USD | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` | 8 |
| USDT/USD | `0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7` | 8 |
| ARB/USD  | `0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6` | 8 |
| LINK/USD | `0x86E53CF1B870786351Da77A57575e79CB55812CB` | 8 |

### Base Mainnet

| Pair | Proxy address | Decimals |
|------|---------------|----------|
| ETH/USD  | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | 8 |
| USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | 8 |
| LINK/USD | `0x17CAb8FE31cA45e4684E33E3D258F20E88B8fD8B` | 8 |

### Optimism Mainnet

| Pair | Proxy address | Decimals |
|------|---------------|----------|
| ETH/USD  | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` | 8 |
| BTC/USD  | `0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593` | 8 |
| USDC/USD | `0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3` | 8 |
| LINK/USD | `0xCc232dcFAAE6354cE191Bd574108c1aD03f86229` | 8 |

## Pyth price feeds (any network)

[Pyth](https://pyth.network) is a *pull* oracle: one contract per network, assets identified
by a network-agnostic `bytes32` **price id**. `GRAI` reads Pyth directly through `setFeed`
(`feedType = FEED_PYTH`, `source = pyth`, `data = priceId`) — no separate adapter contract is
needed.

```solidity
grai.setFeed(WETH, IPriceOracleRouter.Feed({
    feedType: 3, // FEED_PYTH
    asset: WETH,
    source: 0x4305FB66699C3B2702D4d05CF36551390A4c69C6, // Ethereum Pyth contract
    data: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, // ETH/USD price id
    decimals: 0,
    storedPrice: 0,
    storedUpdatedAt: 0,
    maxStaleness: 1 hours
}));
```

A Pyth price is a fixed-point number `price * 10^expo`; the router maps the mantissa onto
the returned price and `-expo` onto `priceDecimals`. Freshness is enforced by
`maxStaleness` (default 1 hour), same as Chainlink feeds.

### Pyth contract addresses (mainnets)

Verify against the [official Pyth EVM address list](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)
before deploying.

| Network | Pyth contract |
|---------|---------------|
| Ethereum  | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| Arbitrum  | `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` |
| Optimism  | `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` |
| Polygon   | `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` |
| Base      | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` |
| Avalanche | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| BNB Chain | `0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594` |

### Pyth price feed IDs (identical on every network)

The full list lives on the [Pyth price feed ids page](https://docs.pyth.network/price-feeds/price-feed-ids).

| Pair | Price id |
|------|----------|
| BTC/USD  | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| ETH/USD  | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| USDC/USD | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` |
| USDT/USD | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` |
| ARB/USD  | `0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5` |

### Common USDC token addresses (for `setFeed` / `setAssetConfig`)

| Network | USDC address |
|---------|--------------|
| Ethereum | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Arbitrum | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Base     | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Optimism | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |

## Production notes

- Split GRAI roles across separate multisigs + timelocks:
  - **`ADMIN_ROLE`** — asset ops (`setFeed`, `setAssetConfig`, `resolve`, `buyback`)
  - **`DEFAULT_ADMIN_ROLE`** — upgrades + wiring (`setProtocolConfig` / `setGrinders` / `setTreasury` / `setSettlementAsset`)
- **`buyback` router calldata is privileged** — treat Grinders upgrade authority and buyback callers as high-trust (arbitrary `target.call` on settlement inventory).
- On L2s (Arbitrum, Base, Optimism), additionally check the Chainlink **L2 Sequencer Uptime
  Feed** before trusting a price, and apply a grace period after sequencer recovery:
  - Arbitrum: `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
  - Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
  - Optimism: `0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389`
- For assets without a Chainlink or Pyth feed, register a `FEED_CUSTOM` feed (`source` = a view
  oracle returning `(price, priceDecimals, updatedAt)`, `data` = `bytes32(selector)`) and keep
  the price fresh via an off-chain keeper.
- Pyth is a **pull** oracle: the on-chain price only updates when someone submits an update.
  For Pyth-priced assets, run a keeper that periodically calls
  `IPyth.updatePriceFeeds{value: fee}(updateData)` (with `fee = getUpdateFee(updateData)`,
  using update blobs from Hermes) so the price stays within `maxStaleness`; otherwise any path
  that touches oracle pricing (`deposit`, `distribute` auctions, `fill` previews) will
  revert with `StalePrice`.
- ERC-1046 metadata is served at `tokenURI()` on GRAI and Grinders (`https://grindurus.xyz/metadata.json`).

## Related

- Solana port: [`../grindurus-solana/`](../grindurus-solana/)
