# GRAI — Grinders Artificial Index

GRAI is a USD-denominated fund-share token. Users `deposit` a supported asset
into `Grinders` custody and receive GRAI at the current book value. Redemption
is disabled during normal operation and becomes available only after liquidation opens.

Holders may `lock` GRAI for **asset dividends** on the **unvoted** escrow
(`amount − voted`), and/or `vote` toward liquidation quorum (`vote` auto-locks any
wallet shortfall). Protocol yield flows through `distribute` and splits per `Config`
cuts (initialize defaults **≈33.33% / 33.34% / 33.33%**): auction → Dutch lot sold for
GRAI via **`buyback`** (payment is `lock`+`vote`d on the buyer — **not** a GRAI vote-reward
index); dividend → unvoted lockers via `claim` / `claimAll`; treasury → `treasury`.

Full mechanics: [`docs/TOKENOMICS.md`](docs/TOKENOMICS.md). Grinders / custodians / yield path: [`docs/GRINDERS.md`](docs/GRINDERS.md).

## Model

```
deposit(asset, amount, lock?) →  asset to Grinders  →  GRAI at book value (totalValue ↑)
                      ↓
              optional lock / later lock(grai)  →  unvoted escrow earns dividends
              optional vote(grai)               →  quorum (voted share leaves dividend base)
                      ↓
              Grinders / custodians earn yield
                      ↓
distribute(asset)          [custodian or any payer]
   ├─ buybackCutBps  → Dutch auction (sold for GRAI via buyback)
   ├─ dividendCutBps → unvoted lockers (claim / claimAll); else → auction
   └─ treasuryCutBps → treasury
                      ↓
buyback(asset)                [permissionless]
   scavenges dead GRAI (balanceOf(this) − totalLocked) onto buyer;
   buyer pays GRAI ask; receives listed asset; graiIn+dead → lock+vote on buyer
                      ↓
unlock(amount)                [locker]
   decaying unlock fee stays on GRAI as orphan/dead; net GRAI to wallet
                      ↓
bribe(voter)               [permissionless]
   dynamic ask vs half-quorum (premium / par / discount) in bribeAsset (non-FoT);
   exact pay → full graiAmount to briber; premium/discount carve-outs → same three cuts
```

| Contract | Role |
|----------|------|
| `GRAI` | UUPS ERC20 fund share + oracle router + auctions + lock/vote/dividends + liquidation. Implements [ERC-1046](https://eips.ethereum.org/EIPS/eip-1046). |
| `Grinders` | UUPS ERC-721 **Grinders Custodians** collection, custodian proxy wallets, `allocate` / `deallocate`. On-chain NFT art via inlined `GrinderArt`. |
| `GrinderArt` | Internal Solidity library (pixel SVG/JSON). Compiled into `Grinders` — **no separate deploy / DELEGATECALL**. |
| `Custodian` | Per-NFT wallet base class: `distribute`, `deallocate`, `liquidate`. |
| `*Custodian` | Kind-specific swap modules (`SwapCustodian`, `CoWCustodian`, `LiFiCustodian`, …). |
| `PriceOracleRouter` | Base of `GRAI`. Chainlink / Pyth / custom feeds per asset. |

Native ETH is `address(0)`. WETH is the fallback when a native ETH push is rejected.

Invariant: `totalVoted ≤ totalLocked ≤ totalSupply`.

## Grinders & custodians

Each `Grinders.mint(custodianKind, base, quote, owner)` deploys an ERC-1967 proxy custodian wallet
(NFT `#id`) and registers it in the custodian index. The NFT owner controls swaps; Grinders owner
(`allocate`) moves working capital from the Grinders reserve into custodian wallets.

`tokenURI(custodianId)` returns on-chain metadata (`data:application/json;base64,…`) from
`GrinderArt` (seeded by `chainId`, token id, and custodian kind). Collection-level ERC-1046
`tokenURI()` still points at `https://grindurus.xyz/metadata.json`.

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
setConfig({ buybackCutBps, dividendCutBps, treasuryCutBps, … })
setBribeAsset(usdc)
setGrinders(grinders)
   ↓
deposit(asset, amount, lock?)                  // capital → Grinders; GRAI at book; optional escrow
lock / unlock / claim                         // unvoted dividends; unlock fee → dead on GRAI
   ↓
distribute(asset, yieldAmount)                 // auction + dividend + treasury cuts
   ↓
buyback(asset, amount)                         // scavenge dead; buy lot for GRAI; lock+vote
   ↓
vote(graiAmount) / bribe(voter, graiAmount)    // liquidation quorum + dynamic bribe buyouts
   ↓
liquidate()                                    // 2-of-2: quorum + owner confirmation
   ↓
Grinders.liquidate(…) + GRAI.redeem(…)         // sweep custodians; pro-rata redeem basket
   ↓
resettle()                                     // anyone: close after redeem window; fund restarts
```

For native ETH call `deposit` / `distribute` / `bribe` with `{value: …}` when required.

## Tokenomics (USD scaled to 6 decimals)

- `depositValue = usdValue(asset, amount)` (oracle; `USD_DECIMALS = 6`)
- **deposit:** `graiOut = depositValue * totalSupply / totalValue` when book is live; bootstrap mint
  when `totalValue == 0` is `graiOut = depositValue` (1 GRAI per $1). Optional `lock` escrows minted
  GRAI in the same tx. `paused` blocks deposits only (not buyback / distribute / claim)
- **lock / claim:** only **unvoted** locked GRAI (`escrow.amount − voted`) earns listed-asset dividends
  from `dividendCutBps`; `claim` / `claimAll` (and `previewClaim` / `previewClaimAll`) pay accrued
  dividends to the holder — **allowed while liquidation is open** (pays only the `totalClaimable`
  reserve, excluded from redeem / resettle). If `totalLocked == totalVoted` (no eligible base), the
  dividend cut is merged into the auction instead. Every `lock` (including buyback / vote shortfall)
  resets `lockedAt` on the whole escrow
- **redeem during open liquidation only** — after `liquidationPeriod`, burns wallet and/or locked
  GRAI for a pro-rata share of `_redeemable` balances on GRAI (excludes dividend reserves). Grinders
  sweeps return custodian assets to GRAI. After `liquidationPeriod + redeemPeriod`, `resettle`
  sends leftover redeemable balances to Grinders; with remaining supply, marks `totalValue = totalNAV`
  only when that **raises** mint price (`totalNAV >= totalValue`), otherwise keeps book TV
  (underwater reopen allowed). Unclaimed dividend reserve stays on GRAI
- **distribute:** splits `received` by `buybackCutBps` / `dividendCutBps` / `treasuryCutBps`
  (must sum to 100%; initialize defaults **3333 / 3334 / 3333**)
- **auction:** one open lot per sold asset; `remaining` = asset qty; `maxPayment` = mint-price GRAI
  for the lot (`previewDeposit`); ask decays to `(BPS - bribePremiumBps)` of mint (default **98%**,
  −2% max discount) over `config.buybackPeriod` (default **7 days**, `setConfig` enforces
  `>= 7 days`); each `_place` merges inventory and restarts the clock at the new mint ask
- **buyback:** scavenges orphan/dead GRAI (`balanceOf(this) − totalLocked`) to the buyer first, then
  pays Dutch GRAI ask for the listed asset; `lock(graiIn + dead)` + `vote(graiIn + dead)`. Reverts
  unless both `graiIn > 0` and `amountOut > 0` (no free / zero fills). Exit payment later via `bribe`
  or `unlock`
- **unlock:** `unlock(graiAmount)` — decaying fee (`unlockFeeBps` → 0 over `unlockPenaltyPeriod` from
  `lockedAt`, defaults 10% / 24h) **stays on GRAI as dead** (not sent to treasury); net returns to
  the wallet (`previewUnlock` → `(unlockAmount, penalty)`). While live fee > 0, partial unlocks below
  `ceil(BPS / penaltyBps)` revert; full-escrow exit is always allowed. Yield claims are separate
- **bribe:** `previewBribe` prices a dynamic ask in `bribeAsset` vs half-quorum
  (`quorumBps / 2`) with slope `bribePremiumBps`: `|adj| = bribePremiumBps` at 0 votes and at
  quorum, par at half; above quorum discount `adj` may exceed `bribePremiumBps`. Premium regime:
  voter gets book + ½ premium, other ½ → cuts. Discount regime: ask uses half the book−fullAsk gap,
  other half → cuts. Par: full ask to voter. `bribeAsset` must **not** be fee-on-transfer: `_pay`
  must credit exactly `bribeAmount`; briber receives the **full** escrowed `graiAmount`
- **liquidation open:** 2-of-2 — `hasQuorum()` **and** owner consent. Owner `liquidate` without quorum
  toggles `confirmed`; with quorum, that call opens. Non-owner opens only if
  `confirmed && hasQuorum()`. `setConfig` is blocked while liquidation is open

> Liquid wallet GRAI does not earn yield dividends — only **unvoted** lockers do. Auctioned yield is
> sold for GRAI via `buyback`; that GRAI becomes the buyer’s locked vote, not a redistributed reward.

## Access control

Both `GRAI` and `Grinders` use OpenZeppelin `Ownable2StepUpgradeable`: a single `owner` gates admin
ops and UUPS upgrades. Ownership transfer is two-step (`transferOwnership` → pending owner
`acceptOwnership`). The oracle router is a base class of `GRAI` (not a separate contract), so feed
management is `onlyOwner` — there is no separate oracle owner.

### Owner functions (`onlyOwner`)

**GRAI**

- `setConfig` — cuts, quorum, auction/liquidation/redeem/unlock timing (blocked while liquidation open)
- `setGrinders` — wire the Grinders yield pool (validates `grinders.grai() == this`)
- `setTreasury` — protocol profit recipient
- `setBribeAsset` — bribe payment asset (must have a feed; non-FoT)
- `setFeed` — set a price feed (**lists** the asset); clearing it (`feedType = FEED_NONE`) **delists** it
- `setAssetConfig` — per-asset `paused` flag only
- `liquidate` — 2-of-2 limb (toggle `confirmed` or open with quorum)
- `_authorizeUpgrade` — UUPS implementation swap

**Grinders**

- `set` — register custodian implementation by kind
- `mint` — deploy custodian proxy NFT
- `allocate` — move reserve capital into a custodian
- `_authorizeUpgrade` — UUPS implementation swap

Permissionless (after windows):

- `resettle` — close liquidation after `liquidationPeriod + redeemPeriod`; leftovers → Grinders;
  `totalValue` raised to leftover NAV only when solvent; fund accepts deposits again

### Permissionless (any caller)

- `deposit`, `distribute`, `buyback`, `redeem` (`redeem` requires open liquidation + delay)
- `lock`, `unlock`, `claim`, `claimAll` (`claim` / `claimAll` stay open in liquidation)
- `vote` (auto-locks wallet shortfall)
- `bribe` (third-party or self buyout; blocked while liquidation is open)
- `liquidate` — non-owner opens only when `confirmed && hasQuorum()`
- `Grinders.liquidate` / `Grinders.liquidate(fromId, toId)` while GRAI liquidation is open
- `Grinders.deallocate` — from the custodian
- views: `previewDeposit`, `previewBuyback`, `previewUnlock`, `previewClaim`, `previewClaimAll`,
  `previewBribe`, `previewRedeem`, `hasQuorum`, `confirmed`, `getAssets`, `getLockers`, `getVoters`,
  `tokenURI`

On deploy, `initialize(admin, weth)` sets `owner = admin`, `treasury = admin`, and points
`grinders` at the contract itself until wired. For production, hand off ownership to a multisig:

```solidity
// Deployer proposes; multisig must accept (Ownable2Step) — both contracts
grai.transferOwnership(ownerMultisig);
grinders.transferOwnership(ownerMultisig);
// as ownerMultisig:
grai.acceptOwnership();
grinders.acceptOwnership();
```

## Usage

```shell
forge build
forge test
forge test --no-match-path "test/fork/*"   # unit tests only
forge fmt
```

### Deploy

CREATE3 (Nick's CREATE2 factory + fixed Solmate proxy) places **four** contracts at deterministic
addresses — `GRAI` impl + ERC-1967 proxy and `Grinders` impl + ERC-1967 proxy — then wires
`GRAI.setGrinders(grinders)`. Addresses depend only on the salt tag, not on admin / WETH / bytecode.
`GrinderArt` is inlined into `Grinders` (no fifth deploy).

| Script | Purpose |
|--------|---------|
| `script/Deploy.s.sol` | Combined GRAI + Grinders CREATE3 deploy |
| `script/DeployArbitrum.s.sol` | Same on Arbitrum One + list WETH / USDT / native ETH + `setBribeAsset(USDT)` |
| `script/1_DeployGRAI.s.sol` | GRAI only |
| `script/2_DeployGrinders.s.sol` | Grinders only (optionally `WIRE_GRAI=1`) |
| `script/3_setGrinders.s.sol` | Wire / retarget `GRAI.setGrinders` |
| `script/4_DeployCoWCustodian.s.sol` | Deploy + register CoW custodian kind |

```shell
# Predict addresses (no broadcast)
PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy --sig "predict()"

# Deploy (any chain with CREATE2 factory)
PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy \
  --rpc-url <your_rpc_url> --broadcast

# Arbitrum One (lists WETH, USDT, native ETH; bribeAsset = USDT)
PRIVATE_KEY=0x... forge script script/DeployArbitrum.s.sol:DeployArbitrum \
  --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
```

The deployer (`vm.addr(PRIVATE_KEY)`) becomes initial `owner`. Optional env `OWNER_MULTISIG`
starts Ownable2Step handoff on both GRAI and Grinders — the multisig must still call
`acceptOwnership()` on each. `CREATE3_SALT_TAG` (fallback: `CREATE2_SALT_TAG`) changes the salt
namespace; `DRY_RUN=1` predicts without broadcasting. `DeployArbitrum` also accepts
`MAX_STALENESS` (default 25 hours for Arbitrum ETH/USD heartbeat).

After a bare `Deploy.s.sol` run, list each asset by setting its feed (this also registers it in
`GRAI`), then wire protocol config. All admin calls require `owner` unless noted:

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

// Optional retarget: cuts, Dutch floor (−bribePremium max), unlock fee — owner
// (initialize already sets ≈33.33/33.34/33.33; buybackPeriod must be >= 7 days)
grai.setConfig(IGRAI.Config({
    buybackCutBps: 5_000,
    dividendCutBps: 3_000,
    treasuryCutBps: 2_000,
    bribePremiumBps: 200,
    quorumBps: 6_667,
    unlockFeeBps: 1_000,
    buybackPeriod: uint32(7 days),
    liquidationPeriod: uint32(24 hours),
    redeemPeriod: uint32(7 days),
    unlockPenaltyPeriod: uint32(24 hours)
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
// deposit ETH: grai.deposit{value: 1 ether}(address(0), 1 ether, false);
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

Canonical tokens used by `DeployArbitrum.s.sol`:

| Asset | Address |
|-------|---------|
| WETH  | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| USDT  | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |

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

- Hold GRAI + Grinders ownership behind a multisig / timelock (`Ownable2Step` on both):
  - **owner** — asset ops, wiring, upgrades (`setFeed`, `setAssetConfig`, `liquidate` /
    `confirmed`, `setConfig` / `setGrinders` / `setTreasury` / `setBribeAsset`, UUPS)
  - **`resettle`** — permissionless after redeem window (restarts the fund)
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
  that touches oracle pricing (`deposit`, `distribute` auctions, `buyback` previews) will
  revert with `StalePrice`.
- ERC-1046 collection metadata: `tokenURI()` on GRAI and Grinders → `https://grindurus.xyz/metadata.json`.
  Per-custodian NFT metadata is on-chain via `Grinders.tokenURI(id)` (`GrinderArt`).

## Related

- Tokenomics: [`docs/TOKENOMICS.md`](docs/TOKENOMICS.md)
- Grinders / custodians: [`docs/GRINDERS.md`](docs/GRINDERS.md)
- Bribe ask chart: [`docs/bribe-amount-vs-voted.svg`](docs/bribe-amount-vs-voted.svg)
- Solana port: [`../grindurus-solana/`](../grindurus-solana/)

## License

- Core protocol (`GRAI.sol`, `Grinders.sol`, `GrinderArt.sol`, `Custodian.sol`): [GPL-3.0](LICENSE)
- Other files under [`src/`](src/): MIT (see SPDX headers)
