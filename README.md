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

## Architecture

```
                     ┌──────────────────────────────┐
                     │  GRAI (Upgradeable ERC20) │  name: Grinders Artificial Index
                     │  symbol: GRAI, decimals: 18    │  mint/burn only via GRAIVault
                     └───────────────┬────────────────┘
                                     │ mint / burn
                                     ▼
┌────────────────┐  addAsset  ┌──────────────────────────────────┐  reads   ┌───────────────────┐
│ PriceOracle     │◄──────────►│  GRAIVault (core, Upgradeable)    │◄────────►│  Chainlink Feeds  │
│ Router          │  getPrice  │  - asset registry & NAV           │          │  (AggregatorV3)   │
└────────────────┘            │  - mint / burn / allocate / distr │          └───────────────────┘
                              │  - deploys Senior/Junior vaults   │
                              └───────┬───────────────────┬───────┘
                            deploys   │                   │   deploys
                                      ▼                   ▼
                          ┌────────────────────┐ ┌────────────────────┐
                          │  SeniorVault[asset] │ │  JuniorVault[asset] │
                          │  (holds tokens)     │ │  (holds tokens)     │
                          └────────────────────┘ └────────────────────┘
```

| Contract | Role |
|----------|------|
| `GRAI` | Upgradeable ERC20 share token (name `Grinders Artificial Index`, symbol `GRAI`, 18 decimals). Minting is restricted to the vault via `MINTER_ROLE`. |
| `GRAIVault` | Protocol core (UUPS upgradeable). Holds the asset registry and NAV; implements `mint`/`burn`/`allocate`/`distribute`; deploys the per-asset tranche stores in `addAsset`. |
| `SeniorVault` / `JuniorVault` | Per-asset token stores deployed as EIP-1167 clones inside `addAsset`. They are intentionally minimal — they only hold tokens and release them on the core's command. Senior holds the idle reserve (source of burns); junior holds active capital routed to custody. |
| `PriceOracleRouter` | Reads Chainlink `AggregatorV3Interface` feeds with positivity and staleness checks; isolates price logic so sources can be swapped without upgrading the core. |
| `CustomPriceFeed` | Optional fallback oracle (for assets without a Chainlink feed) implementing `AggregatorV3Interface` with an access-controlled price pusher and on-chain freshness. |

## Lifecycle

```
initialize → addAsset(asset, chainlinkFeed)   // deploys Senior + Junior stores
   ↓
mint(asset, amount)   → deposit split by mintSplit (senior/junior), GRAI minted at NAV
   ↓
allocate(asset, custody, amount)   → junior capital sent to an external strategy wallet
   ↓ (strategy earns yield)
distribute(asset, yieldAmount)     → yield split by yieldSplit: senior (NAV ↑) + treasury
   ↓
burn(graiAmount)   → redeem a proportional share of senior idle per asset
```

## Tokenomics (USD scaled to 18 decimals)

- `depositValue = amount * price * 10^18 / (10^assetDecimals * 10^priceDecimals)`
- mint: bootstrap `grai = depositValue`; otherwise `grai = depositValue * supply / totalValue`
- burn: `burnValue = graiAmount * totalValue / supply`; redeem per asset `= graiAmount * seniorIdle / supply`
- splits (bps, 10000 = 100%): default `mintSplit = 5000`, `yieldSplit = 8000`
- price staleness window: 1 hour

> Because burns are paid only from the senior reserve, instant exit liquidity is bounded by
> the senior idle balance — this is the intended tranche design, not a bug.

## Usage

```shell
forge build
forge test
forge fmt
```

### Deploy

```shell
ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol \
  --rpc-url <your_rpc_url> --broadcast
```

After deployment, register each asset with its Chainlink feed:

```solidity
vault.addAsset(USDC, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // Ethereum USDC/USD
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

### Common USDC token addresses (for `addAsset`)

| Network | USDC address |
|---------|--------------|
| Ethereum | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Arbitrum | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Base     | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Optimism | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |

## Production notes

- Replace `onlyOwner` with a multisig + timelock for admin actions.
- On L2s (Arbitrum, Base, Optimism), additionally check the Chainlink **L2 Sequencer Uptime
  Feed** before trusting a price, and apply a grace period after sequencer recovery:
  - Arbitrum: `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
  - Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
  - Optimism: `0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389`
- For assets without a Chainlink feed, deploy a `CustomPriceFeed` and keep its price fresh
  via an off-chain keeper.
