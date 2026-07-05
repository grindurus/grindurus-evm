# GRAI — Grinders Artificial Index

GRAI is a synthetic, USD-denominated index/share token backed by a two-tranche
(senior/junior) NAV vault. Users deposit a supported asset and receive GRAI minted at the
current NAV (Net Asset Value); on burn they redeem a proportional share of the senior
(idle) reserve.

The price of one GRAI equals `NAV / totalSupply`. As the protocol's assets earn yield, NAV
grows and each GRAI becomes worth more — even without new tokens being minted. It is, in
effect, a tokenized fund share.

## Tranche model

Each supported asset is split across two on-chain stores:

- **Senior vault (idle reserve)** — the calm, liquid portion. Burns (`burn`) are paid out
  exclusively from here, so it backs instant redemptions.
- **Junior vault (active capital)** — routed out to external strategies (custody wallets)
  via `allocate`, where it earns yield that flows back through `distribute`.

On every `mint` the deposit is divided between the two stores according to `mintSplit`
(default 50% / 50%). Returned yield is divided by `yieldSplit` (default 80% to senior, which
raises NAV for all holders, and 20% to the treasury).

Both vaults are **multi-asset**: a single `SeniorVault` and a single `JuniorVault` hold all
registered assets (ERC-20 and native ETH). Native ETH is represented by `address(0)`.

## Architecture

```
                     ┌─────────────────────────────────────────────┐
                     │  GRAI (UUPS upgradeable ERC20 + core)       │
                     │  name: Grinders Artificial Index, symbol GRAI│
                     │  mint / burn / allocate / distribute / NAV    │
                     │  ERC-1046 tokenURI                            │
                     └───────────────┬─────────────────────────────┘
                                     │ proprietor
                     ┌───────────────┴───────────────┐
                     ▼                               ▼
          ┌────────────────────┐         ┌────────────────────┐
          │  SeniorVault        │         │  JuniorVault        │
          │  (multi-asset idle) │         │  (multi-asset active)│
          └────────────────────┘         └────────────────────┘
                     ▲
                     │ getPrice(asset)
          ┌──────────┴──────────────────┐
          │  PriceOracleRouter (UUPS)   │
          │  Chainlink / Pyth / Custom  │
          └─────────────────────────────┘
```

| Contract | Role |
|----------|------|
| `GRAI` | UUPS upgradeable ERC20 + protocol core. Asset registry, NAV accounting, `mint`/`burn`/`allocate`/`distribute`. Deploys one `SeniorVault` and one `JuniorVault` in `initialize`. Implements [ERC-1046](https://eips.ethereum.org/EIPS/eip-1046) via `tokenURI()`. |
| `SeniorVault` / `JuniorVault` | Thin wrappers over `VaultBase`. Senior holds idle reserve (source of burns); junior holds active capital routed to custody. Both accept ERC-20 and native ETH (`address(0)`). |
| `VaultBase` | Multi-asset custody: `balance(asset)`, `deposit(asset, amount)`, `withdraw(asset, to, amount)`. Only the proprietor (`GRAI`) may move funds. |
| `PriceOracleRouter` | UUPS upgradeable oracle router. Maps each asset address to a Chainlink, Pyth, or custom on-chain price feed. Enforces positivity and `maxStaleness` (default 1 hour). |

There is no separate `GRAIVault` contract and no per-asset vault clones. Oracle adapters
(`PythPriceFeed`, `CustomPriceFeed`) are not deployed separately — feed logic lives inside
`PriceOracleRouter`.

## Lifecycle

```
initialize(admin, oracle, treasury)   // deploys Senior + Junior vaults, sets tokenURI
   ↓
oracle.addChainlinkFeed / addPythFeed / addCustomFeed   // register price per asset
grai.addAsset(asset)                                     // register asset in GRAI
   ↓
mint(asset, amount)   → deposit split by mintSplit (senior/junior), GRAI minted at NAV
   ↓
allocate(asset, custody, amount)   → junior capital sent to an external strategy wallet
   ↓ (strategy earns yield)
distribute(asset, yieldAmount)     → yield split by yieldSplit: senior (NAV ↑) + treasury
   ↓
burn(graiAmount)   → redeem a proportional share of senior idle per asset
```

For native ETH use `address(0)` as the asset and call `mint` / `distribute` with `{value: amount}`.

## Tokenomics (USD scaled to 18 decimals)

- `depositValue = amount * price * 10^18 / (10^assetDecimals * 10^priceDecimals)`
- mint: bootstrap `grai = depositValue`; otherwise `grai = depositValue * supply / totalValue`
- burn: `burnValue = graiAmount * totalValue / supply`; redeem per asset `= graiAmount * seniorIdle / supply`
- splits (bps, 10000 = 100%): default `mintSplit = 5000`, `yieldSplit = 8000`
- price staleness window: 1 hour (`PriceOracleRouter.maxStaleness`, configurable)

> Because burns are paid only from the senior reserve, instant exit liquidity is bounded by
> the senior idle balance — this is the intended tranche design, not a bug.

## Access control

`GRAI` uses OpenZeppelin `AccessControl` with two roles. `PriceOracleRouter` uses a separate
`owner` (see [Production notes](#production-notes)).

| Role | ID | Permissions |
|------|----|-------------|
| `DEFAULT_ADMIN_ROLE` | `0x00…00` (OZ default) | UUPS contract upgrades (`upgradeTo` / `upgradeToAndCall`); grant and revoke all roles |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Day-to-day protocol operations (see below) |

### `ADMIN_ROLE` functions

- `addAsset` / `removeAsset`
- `setPaused`
- `setMintSplit` / `setYieldSplit`
- `allocate`
- `setTreasury`
- `setTokenURI`

### `DEFAULT_ADMIN_ROLE` functions

- `_authorizeUpgrade` (UUPS implementation swap)

### Permissionless (any caller)

- `mint`, `burn`, `distribute`
- `nav`, `getAssets`, `getVaults`, `assetCount`, `tokenURI`

On deploy, `initialize(admin, …)` grants **both** roles to the same `admin` address. For
production, split them across separate multisigs:

```solidity
// Ops multisig — protocol management, no upgrade rights
grai.grantRole(grai.ADMIN_ROLE(), opsMultisig);
grai.revokeRole(grai.ADMIN_ROLE(), deployer);

// Upgrade multisig — implementation upgrades only
grai.grantRole(grai.DEFAULT_ADMIN_ROLE(), upgradeMultisig);
grai.revokeRole(grai.DEFAULT_ADMIN_ROLE(), deployer);
```

`DEFAULT_ADMIN_ROLE` is the role admin for `ADMIN_ROLE` and can grant or revoke it.

## Usage

```shell
forge build
forge test
forge test --no-match-path "test/fork/*"   # unit tests only
forge fmt
```

### Deploy

The deploy script creates **six** on-chain contracts: two implementation contracts, two
ERC-1967 proxies (`GRAI`, `PriceOracleRouter`), and two vaults (`SeniorVault`, `JuniorVault`
— deployed inside `GRAI.initialize`).

```shell
ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol \
  --rpc-url <your_rpc_url> --broadcast
```

After deployment, register each asset on the oracle, then add it to GRAI:

```solidity
// Chainlink (Ethereum mainnet USDC/USD)
oracle.addChainlinkFeed(USDC, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
grai.addAsset(USDC);

// Pyth (any network — pyth contract is per-network, priceId is shared)
oracle.addPythFeed(WETH, PYTH, 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace);
grai.addAsset(WETH);

// Custom on-chain price (oracle signer pushes via setCustomPrice)
oracle.addCustomFeed(TOKEN, 8, oracleSigner);
grai.addAsset(TOKEN);

// Native ETH (use ETH/USD feed on address(0))
oracle.addChainlinkFeed(address(0), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
grai.addAsset(address(0));
// mint: grai.mint{value: 1 ether}(address(0), 1 ether);
```

Post-deploy admin calls require `ADMIN_ROLE` on `GRAI` and `owner` on `PriceOracleRouter`.
See [Access control](#access-control).

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
by a network-agnostic `bytes32` **price id**. The router reads Pyth directly via
`addPythFeed(asset, pyth, priceId)` — no separate adapter contract is needed.

```solidity
oracle.addPythFeed(
    WETH,
    0x4305FB66699C3B2702D4d05CF36551390A4c69C6, // Ethereum Pyth contract
    0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace  // ETH/USD price id
);
grai.addAsset(WETH);
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

### Common USDC token addresses (for `addAsset`)

| Network | USDC address |
|---------|--------------|
| Ethereum | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Arbitrum | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Base     | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Optimism | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |

## Production notes

- Split GRAI roles across separate multisigs + timelocks:
  - **`ADMIN_ROLE`** — ops (assets, splits, allocate, treasury, tokenURI)
  - **`DEFAULT_ADMIN_ROLE`** — upgrades only
- Use a separate multisig + timelock for `owner` on `PriceOracleRouter`.
- On L2s (Arbitrum, Base, Optimism), additionally check the Chainlink **L2 Sequencer Uptime
  Feed** before trusting a price, and apply a grace period after sequencer recovery:
  - Arbitrum: `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
  - Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
  - Optimism: `0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389`
- For assets without a Chainlink or Pyth feed, use `addCustomFeed` and keep the price fresh
  via an off-chain keeper calling `setCustomPrice`.
- Pyth is a **pull** oracle: the on-chain price only updates when someone submits an update.
  For Pyth-priced assets, run a keeper that periodically calls
  `IPyth.updatePriceFeeds{value: fee}(updateData)` (with `fee = getUpdateFee(updateData)`,
  using update blobs from Hermes) so the price stays within `maxStaleness`; otherwise
  `mint`/`burn` will revert with `stale price`.
- Serve ERC-1046 metadata at `tokenURI()` (default `https://grindurus.xyz/metadata.json` set
  in `initialize`; updatable via `setTokenURI`).
