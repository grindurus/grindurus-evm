# GRS Tokenomics — Protocol Token & Cap Table

Target design for **GRS** (*Grindurus Share*), the fixed-supply protocol equity / governance token of Grindurus. On-chain product tokens today: **GRAI** (fund share), **GRINDERS** (custodian NFTs), **GRAI-TREASURY** (sticky affiliate NFTs).   

This document is the canonical allocation and utility spec. On-chain OFT: `[GRS.sol](../src/GRS.sol)` (EVM) and `[programs/grs](../../grindurus-solana/programs/grs)` (Solana).

Related: fund-share mechanics `[GRAI.md](GRAI.md)`, custodian layer `[GRINDERS.md](GRINDERS.md)`, live fee sink `[Treasury.sol](../src/Treasury.sol)`.

---



## 1. Executive summary

**GRS** is the **protocol token**: fixed supply, governance over admin surfaces, and the economic claim on **protocol fee income** (the treasury slice of yield that does not go to GRAI lockers).

**GRAI** and **GRS** are deliberately separate:


| Token    | Role                                                                            | Supply               |
| -------- | ------------------------------------------------------------------------------- | -------------------- |
| **GRAI** | USD book-priced fund share; minted on `deposit`, burned on liquidation `redeem` | Elastic (NAV-linked) |
| **GRS**  | Protocol equity + governance; claim on treasury / `beneficiar` economics        | Fixed at genesis     |


```
yield on custodians
        │
        ▼
GRAI.distribute(yield)
   ├─ dividendCutBps  (50%) → unvoted lockers (claim); else → treasury
   └─ treasuryCutBps  (50%) → Treasury inventory
                                      │
                                      ├─ revenueShare (5% of yield) → affiliates (inventory on claim)
                                      └─ remainder → Treasury.beneficiar → admin income + GRS/ETH buy → GRS to affiliates
```

Today `Treasury.beneficiar` is a single address set by `GRAI.owner()`. At GRS launch, `**beneficiar` is intended to migrate to a GRS-governed vault** (or streaming contract) so fee flow accrues to token holders / stakers instead of a static multisig wallet.

`Treasury.beneficiar` splits ~30%: **admin income** + **GRS/ETH** market buy → GRS to **affiliates**. **revenueShare** (5%) is still inventory on locker claim.

---



## 2. Token specification (target)


| Field                  | Value                                                                                                     |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| Name                   | Grindurus Token                                                                                           |
| Symbol                 | **GRS**                                                                                                   |
| Decimals               | **18**                                                                                                    |
| Max supply             | **1,000,000,000 GRS** (1B)                                                                                |
| Mintable after genesis | **No** (fixed cap; no inflation)                                                                          |
| Networks               | **Solana**, **Ethereum**, **Arbitrum, etc.**                                                              |
| Standard               | LayerZero OFT — ERC-20 on Ethereum / Arbitrum; SPL + OFT program on Solana                                |
| Upgrade pattern        | Non-upgradeable token recommended; governance executes via timelocked admin on GRAI / Grinders / Treasury |


**GRS** is intended to exist on **Solana**, **Ethereum**, and **Arbitrum, etc.** under the same 1B cap. Canonical mint and bridge are fixed at TGE — listing a chain **must not** mint extra GRS (§2.1).

Metadata (ERC-1046 target): `https://grindurus.xyz/grs.json` (placeholder until deployment).

### 2.1 Canonical mint

One chain is the **canonical mint** (home). The **entire 1,000,000,000 GRS supply** is minted **only on home** once at genesis — there is no split genesis across chains and no spoke-side mint of allocation buckets. Mint authority is then **revoked / frozen**. Spoke deployments (Ethereum, Arbitrum, Solana, etc.) receive **bridged representations** of that same home inventory — not independent tokens or duplicate cap-table mints.

Home chain is chosen at TGE and does not change without a GRS governance migration (new lockboxes, no second genesis mint).


| Role                 | Networks                                        | Token                                                     |
| -------------------- | ----------------------------------------------- | --------------------------------------------------------- |
| **Home (canonical)** | One of Solana / Ethereum (fixed at TGE)         | Native GRS — only place the 1B exists as “real” inventory |
| **Spokes**           | The other listed chains, including **Arbitrum** | Bridged GRS (lock-and-mint / burn-and-unlock)             |


Decimals are **18** in the cap table. Every chain’s user-visible amount must match **1 GRS = 10¹⁸ base units**. If the Solana mint cannot use 18 decimals, the bridge **scales** 1:1 in GRS terms and **must not** round in a way that creates or destroys supply.

### 2.2 Bridge

Holders move GRS between listed chains through a **burn/lock ↔ mint/unlock** path. Global circulating GRS (home unlocked + all spoke balances) **never exceeds 1B**, and **never exceeds** what was unlocked from vesting / sale / gates on the home ledger.

```
source chain                          dest chain
─────────────                         ──────────
lock or burn GRS
        │
        ▼
  bridge message  ─────────────────►  mint or unlock GRS
  (attested; same amount)
```


| Direction     | Source                                                                           | Destination                                                                           |
| ------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Home → spoke  | Lock GRS in the home lockbox (or burn if the home token is burnable for transit) | Mint spoke GRS 1:1 to the recipient                                                   |
| Spoke → home  | Burn spoke GRS                                                                   | Unlock the same amount from the home lockbox                                          |
| Spoke → spoke | Burn on source spoke                                                             | Mint on dest spoke (home lockbox balance unchanged; inventory already locked on home) |


**Invariants the bridge must keep**

1. `Σ spoke.totalSupply + home.liquidOutsideLockbox + home.lockbox = 1B` (vested-but-unreleased escrow is part of the 1B; it is not bridgable until `release`).
2. Spoke mint authority is **only** the bridge adapter. No admin mint, no sale mint, no “Arbitrum genesis”.
3. Home mint authority stays **revoked**. The lockbox never mints; it only holds canonical GRS.
4. Amount in = amount out (same 18-decimal GRS). Failed messages do not mint; retries are idempotent.
5. Adding a future chain = new spoke + the same lockbox accounting — **zero** new genesis supply.

**Token sales (5% / 50M)** are inventory on **home** (or a pre-funded spoke allocation that is already locked on home). Selling the same 50M independently on EVM and Solana is out of spec. Buyers may **bridge after claim**.

**LP & MM (8%)** may seed pools on several chains; that GRS is bridged from home LP inventory, not minted per DEX.

**Governance.** `ERC20Votes` / governor live on the **home** (or a designated EVM hub). Spoke GRS does not vote until it is bridged to the hub (or a later x-chain vote module is added by GRS proposal). Bridging does not copy checkpoints.

**What the bridge is not**

- Not a second GRS with its own cap.
- Not GRAI (fund shares do not bridge as GRS).
- Not a way to unlock vesting early — only released GRS can enter the lockbox.
- Not required for GRAI / Grinders, which remain native per chain.

Vendor (Wormhole, LayerZero OFT, NTT, custom) is an implementation choice at TGE. The accounting above is the spec; the adapter is replaceable via governance only if the lockbox invariant is preserved.

---



## 3. Cap table

Genesis allocation — **1,000,000,000 GRS** at TGE. Percentages sum to 100%.

**All supply on home, bridged to spokes.** The full cap table below is minted and accounted for on the **home chain** only (§2.1). Vesting escrows, Foundation, LP & MM inventory, gated programs — every bucket — exist on that canonical ledger first. Other listed networks hold **bridged GRS** moved via lock/burn ↔ mint/unlock (§2.2); they do **not** get their own genesis mint or extra supply. What appears on a spoke was released (or pre-allocated and bridged) from home.

GRS genesis allocation — 1B supply treemap

Source: `[grs.svg](grs.svg)` · PNG: `[grs-genesis-alloc.png](grs-genesis-alloc.png)`

GRS vesting schedule

Source: `[grs-vesting.svg](grs-vesting.svg)` · PNG: `[grs-vesting.png](grs-vesting.png)`

### 3.1 Summary

Treemap column order (left → right): **Investments** → **Affiliates** → **Team** → **Ecosystem** → **Foundation**.


| Bucket                                | Share       | GRS (18 dec)      | TGE liquid       | Vesting                        | Goal                                                                 |
| ------------------------------------- | ----------- | ----------------- | ---------------- | ------------------------------ | -------------------------------------------------------------------- |
| **Investments**                       | **20.00%**  | **200,000,000**   | **5% at TGE**    | per round ↓                    | Finance protocol growth; place GRS with aligned capital & community  |
| ↳ Token sales                         | 5.00%       | 50,000,000        | 5% at TGE        | none (unlocked at TGE)         | Public / strategic sale — TGE free float & price discovery           |
| ↳ Pre-seed                            | 5.00%       | 50,000,000        | 0%               | no cliff, 2y linear            | Earliest private backers; longest-horizon investor alignment           |
| ↳ Seed                                | 5.00%       | 50,000,000        | 0%               | 3m cliff, 2y linear            | Seed-round capital for product and go-to-market milestones             |
| ↳ Series                              | 5.00%       | 50,000,000        | 0%               | 6m cliff, 24m linear           | Growth-round capital for scale, listings, and multi-chain rollout      |
| **Affiliates & airdrops**             | **20.00%**  | **200,000,000**   | **0% at TGE**    | per bucket ↓                   | Grow distribution & early community around GRAI usage                  |
| ↳ Revenue Share Program               | 18.00%      | 180,000,000       | 18% TGE          | proprietary-gated · ∞          | **GRS layer on top of GRAI `revenueShare`** — referral & partner upside beyond yield |
| ↳ Airdrops                            | 2.00%       | 20,000,000        | 2% TGE           | proprietary-gated · 67 seasons | One-time recognition of early GRAI depositors, testnet users, launch claims |
| **Team**                              | **20.00%**  | **200,000,000**   | **0%**           | per bucket ↓                   | Retain builders and advisors; tie core contributors to long-term protocol success |
| ↳ Core team                           | 15.00%      | 150,000,000       | 0%               | 12m cliff, 60m linear          | Full-time team compensation; no TGE dump — multi-year build alignment  |
| ↳ Advisors                            | 5.00%       | 50,000,000        | 0%               | 6m cliff, 66m linear           | Strategic advisors (legal, BD, technical) with extended vest           |
| **Ecosystem**                         | **20.00%**  | **200,000,000**   | **per bucket ↓** | —                              | External growth — partnerships, liquidity, and go-to-market outside Team/Foundation |
| ↳ Growth Fund                         | 12.00%      | 120,000,000       | 12% TGE          | vote-gated · ∞                 | Partnerships, integrations (CoW / LiFi), incentives & marketing      |
| ↳ Liquidity Providing & Market Makers | 8.00%       | 80,000,000        | 8% TGE           | proprietary-gated · ∞          | **Ensure liquid GRS markets** — DEX seed liquidity & MM on home/spokes |
| **Foundation**                        | **20.00%**  | **200,000,000**   | **5% at TGE**    | remainder vote-gated · ∞       | Vote-gated protocol treasury — long-term reserve, security, compliance |
| ↳ Long-term reserve                   | 15.00%      | 150,000,000       | 0%               | GRS vote                       | **Strategic treasury & future ecosystem needs** — discretionary DAO reserve |
| ↳ Audits & Bug Bounty                 | 3.00%       | 30,000,000        | 0%               | GRS vote                       | Smart-contract audits, fuzz/invariant work, bug bounties               |
| ↳ Legal                               | 2.00%       | 20,000,000        | 0%               | GRS vote                       | Entity, token classification, listings compliance, counsel           |
| **Total**                             | **100.00%** | **1,000,000,000** | **100M (10%)**   | —                              | —                                                                    |




### 3.2 Fully diluted view

**1B GRS** at genesis — treemap overview and reference tables.

Scale markers: **0% · 20% · 40% · 60% · 80% · 100%** (boundaries between treemap columns).

#### By stakeholder (matches treemap groups)


| Group                     | Share | GRS  | Role                                                                |
| ------------------------- | ----- | ---- | ------------------------------------------------------------------- |
| **Investments**           | 20%   | 200M | Token sales → pre-seed → seed → series                              |
| **Affiliates & airdrops** | 20%   | 200M | Referral program + launch airdrop                                   |
| **Team**                  | 20%   | 200M | Core team (12m cliff, 60m linear) + advisors (6m cliff, 66m linear) |
| **Ecosystem**             | 20%   | 200M | Growth Fund + liquidity providing & MM                              |
| **Foundation**            | 20%   | 200M | 5% TGE; remainder vote-gated — see §3.6                             |




#### Full breakdown (same order as treemap)


| Bucket                                | Share     | GRS      |
| ------------------------------------- | --------- | -------- |
| **Investments**                       | **20.0%** | **200M** |
| ↳ Token sales                         | 5.0%      | 50M      |
| ↳ Pre-seed                            | 5.0%      | 50M      |
| ↳ Seed                                | 5.0%      | 50M      |
| ↳ Series                              | 5.0%      | 50M      |
| **Affiliates & airdrops**             | **20.0%** | **200M** |
| ↳ Revenue Share Program               | 18.0%     | 180M     |
| ↳ Airdrops                            | 2.0%      | 20M      |
| **Team**                              | 20.0%     | 200M     |
| ↳ Core team                           | 15.0%     | 150M     |
| ↳ Advisors                            | 5.0%      | 50M      |
| **Ecosystem**                         | **20.0%** | **200M** |
| ↳ Growth Fund                         | 12.0%     | 120M     |
| ↳ Liquidity Providing & Market Makers | 8.0%      | 80M      |
| **Foundation**                        | **20.0%** | **200M** |
| ↳ Long-term reserve                   | 15.0%     | 150M     |
| ↳ Audits & Bug Bounty                 | 3.0%      | 30M      |
| ↳ Legal                               | 2.0%      | 20M      |


**Circulation on TGE:** **100M GRS (10%)** — Token sales **50M** + Foundation **50M** (free float).

**Gated on TGE:** **400M GRS (40%)** — Revenue Share 18% + Airdrops 2% + Growth 12% + LP & MM 8% (allocated at TGE, not free float until released).

**Remaining:** **500M GRS (50%)** — calendar vesting **35%** (Pre-seed, Seed, Series, Core team, Advisors) + Foundation remainder **15%** (vote-gated). Pre-seed linear starts **after** TGE.

### 3.3 Bucket intent

Order follows `[grs.svg](grs.svg)` (left → right).


| Bucket                                    | Purpose                                                                                                                    |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Investments**                           | Token sales, pre-seed, seed, and Series — **20%** total (200M GRS)                                                         |
| ↳ **Token sales**                         | Public / community sale; **5% TGE · no vesting** (**5%** / 50M GRS)                                                        |
| ↳ **Pre-seed**                            | Earliest backers; no cliff, 2y linear (**5%** / 50M GRS)                                                                   |
| ↳ **Seed**                                | Seed-round capital; 3m cliff, 2y linear (**5%** / 50M GRS)                                                                 |
| ↳ **Series**                              | Growth-round capital; 6m cliff, 24m linear (**5%** / 50M GRS)                                                              |
| **Affiliates & airdrops**                 | **20%** total — referral program + one-time airdrop                                                                        |
| ↳ **Revenue Share Program**               | GRAI revenue-share incentives — **18% TGE · proprietary-gated · ∞** (**18%** / 180M GRS)                                   |
| ↳ **Airdrops**                            | Early GRAI depositors, testnet users, launch merkle claim — **2% TGE · proprietary-gated · 67 seasons** (**2%** / 20M GRS) |
| **Team**                                  | Core builders + protocol advisors (**20%** / 200M GRS)                                                                     |
| ↳ **Core team**                           | Full-time builders; **12m cliff, 60m linear** (**15%** / 150M GRS)                                                         |
| ↳ **Advisors**                            | Advisor grants; **6m cliff, 66m linear** (**5%** / 50M GRS)                                                                |
| **Ecosystem**                             | **20%** total — Growth Fund + liquidity providing & market makers                                                          |
| ↳ **Growth Fund**                         | Partnerships, incentives & marketing — **12% TGE · vote-gated · ∞** (**12%** / 120M GRS)                                   |
| ↳ **Liquidity Providing & Market Makers** | GRS market liquidity — **8% TGE · proprietary-gated · ∞** (**8%** / 80M GRS)                                               |
| **Foundation**                            | Protocol reserve — **5% TGE**, remainder vote-gated (**200M GRS**); sub-buckets + §3.6                                     |
| ↳ **Long-term reserve**                   | Strategic treasury & future ecosystem needs (**15%** / 150M GRS)                                                           |
| ↳ **Audits & Bug Bounty**                 | Security audits & bug bounties (**3%** / 30M GRS)                                                                          |
| ↳ **Legal**                               | Compliance & counsel (**2%** / 20M GRS)                                                                                    |




### 3.4 Vesting schedule

GRS vesting schedule

Source: `[grs-vesting.svg](grs-vesting.svg)` · PNG: `[grs-vesting.png](grs-vesting.png)`. Horizon on the chart is **TGE → 72m**, then **∞**. One **season ≈ 1 month** on that axis.

**Key**


| Term                  | Meaning                                       |
| --------------------- | --------------------------------------------- |
| **Cliff**             | Locked until the cliff ends                   |
| **Linear vesting**    | Time-based unlock after (or instead of) cliff |
| **Vote-gated**        | Release only after GRS governance approval    |
| **Proprietary-gated** | Revenue-based release (not GRS vote)          |
| **∞ / open-ended**    | No predetermined unlock date                  |


**At TGE**


| Bucket      | Amount | Of supply | What it is                                                                            |
| ----------- | ------ | --------- | ------------------------------------------------------------------------------------- |
| Circulation | 100M   | 10%       | Token sales 5% + Foundation 5% — free float                                           |
| Gated       | 400M   | 40%       | Revenue Share 18% + Airdrops 2% + Growth 12% + LP & MM 8% — allocated, not free float |
| Remaining   | 500M   | 50%       | Vesting 35% (Pre-seed, Seed, Series, Team) + Foundation remainder 15% (vote-gated)    |
| **Total**   | **1B** | **100%**  |                                                                                       |


**Per-bucket schedule** (same row order as the chart)


| Bucket                             | Cliff | Unlock path                                 | Fully vested (calendar)  |
| ---------------------------------- | ----- | ------------------------------------------- | ------------------------ |
| Token sales (5% / 50M)             | none  | **5% TGE · no vesting**                     | TGE → ∞                  |
| Pre-seed (5% / 50M)                | none  | 24m linear **after TGE**                    | M24                      |
| Seed (5% / 50M)                    | 3m    | 24m linear                                  | M27                      |
| Series (5% / 50M)                  | 6m    | 24m linear                                  | M30                      |
| Revenue Share Program (18% / 180M) | —     | **18% TGE · proprietary-gated · ∞**         | no fixed date            |
| Airdrops (2% / 20M)                | —     | **2% TGE · proprietary-gated · 67 seasons** | M67                      |
| Core team (15% / 150M)             | 12m   | 60m linear                                  | M72                      |
| Advisors (5% / 50M)                | 6m    | 66m linear                                  | M72                      |
| Growth Fund (12% / 120M)           | —     | **12% TGE · vote-gated · ∞**                | no fixed date            |
| LP & MM (8% / 80M)                 | —     | **8% TGE · proprietary-gated · ∞**          | no fixed date            |
| Foundation (20% / 200M)            | —     | **5% TGE**; remainder vote-gated · ∞        | remainder: no fixed date |


Linear buckets use **in-token vesting** on home `GRS` (`grant` + public `release`; no `revoke`) — mechanics in §3.5. Any GRS holder on **home or spoke** (EVM `vest` / Solana `vest`, no cap table on Solana) may also lock their own tokens into the same on-token escrow. Instant (cliff = duration = 0) is rejected; use `transfer`. Holder vests are capped: **cliff ≤ 1 year** (365 days), **linear unlock ≤ 4 years**. Vote-gated remainder (Growth Fund, Foundation 15%) requires a **GRS proposal → vote → timelock** (≥ 48h). **Revenue Share (18%)**, **LP & MM (8%)**, and **Airdrops (2%)** are **proprietary-gated**: team / ops may deploy them from TGE with no GRS vote. Revenue Share and LP have no calendar end; airdrops run **67 seasons**.

### 3.5 Home-chain `grant`

Cap-table inventory lives only on **home** `GRS`. The constructor mints the full **1B** to `address(this)` — not to the delegate. `grant` does not mint; it spends that inventory and either transfers GRS out or records an in-token vest. Spokes revert `NotHome`. Solana has no `grant` / buckets other than the 50M TokenSales spend in `buy`.

```
grant(bucket, to, amount, start, cliffSeconds, durationSeconds) → vestingId
```

**Who may call** depends on `gateOf(bucket)`, not on the cliff/duration args:


| Gate            | Buckets                                              | Caller                          |
| --------------- | ---------------------------------------------------- | ------------------------------- |
| Instant         | Token sales                                          | `owner` (TGE delegate)          |
| Linear          | Pre-seed, Seed, Series, Core team, Advisors          | `owner`                         |
| Proprietary     | Revenue Share, Airdrops, LP & MM                     | `owner`                         |
| VoteGated       | Growth Fund, Long-term reserve, Audits, Legal        | `proprietor`                    |


Constructor sets `proprietor = delegate` (same address as `owner`). Later `setProprietor(timelock)` (owner-only, home-only) so vote-gated spends go through the Governor/timelock path in §4.1. Clearing `proprietor` to `address(0)` would fall back to `owner`; that is not the intended post-handoff state.

`Bucket.Holder` is not a cap-table row (`capOf = 0`); `grant` from it reverts `BucketExceeded`. Holders lock their own GRS with `vest`, not `grant`.

**Accounting.** `spent[bucket] += amount`. If that exceeds `capOf(bucket)`, revert `BucketExceeded`. `remaining = cap − spent`. Assigning from a bucket **commits the cap immediately**, including still-locked vests. There is no `revoke`; unused schedule does not return GRS to the bucket.

**Payout.**

1. **Instant** — `cliffSeconds == 0` and `durationSeconds == 0`: transfer `amount` from the contract to `to`. Returns `vestingId = 0`. Gate type does not force this: Token Sales may be granted as a vest, Core Team may be granted instant.
2. **Vest** — otherwise tokens stay on `GRS`. Id ≥ 1, `funder = address(this)`. `start = 0` means `block.timestamp`. Cliff ends at `start + cliffSeconds`; linear runs until `cliffEnd + durationSeconds`. After cliff, vested amount is linear in elapsed time; if `durationSeconds = 0`, the full allocation unlocks at cliff. Overflow on the timestamps reverts `InvalidSchedule`. Protocol `grant` is **not** bound by holder `MAX_CLIFF` / `MAX_DURATION` (those apply only to `vest`) so Core Team 60m / Advisors 66m linears still fit.

`scheduleOf(bucket)` is the svg default in **months** (hint for UIs). The call itself takes **seconds**; the delegate/proprietor may pick other timestamps. Vote-gated / proprietary rows report `0/0` in `scheduleOf` because unlock is gated, not calendar.

**`release(id)`** is permissionless. It pulls `releasable` GRS from the contract to `beneficiary`. Unreleased GRS is still in the 1B lockbox invariant (§2.2) and cannot be bridged until released.

`getAllocations()` is home-only (13 rows). `getVestings(offset, limit)` pages vestings (`offset` 0-based; `vestingCount()` is the total). On Solana, vest PDAs use the same 1-based sequential ids (`vest` requires `id == vesting_count + 1`); `get_vestings` remaining accounts must be those PDAs for the page.

Public **token sales** also spend `TokenSales` (same `spent` / cap as `grant`). Each sale is a `{quote, price, recipient}` row; several may run at once (ETH + USDC, different recipients):

```
setSale(0, quote, price, recipient) → id   // create; `id > 0` updates
quoteSale(id, amount) → cost
buy(id, amount, to)                    // anyone; instant GRS, no vest
getSales(offset, limit)
```

`price` is quote units per **1 GRS**; `price = 0` closes **that** id. EVM: divide by `1e18` (18 local decimals); `quote = address(0)` is native ETH (`msg.value` must equal `quoteSale`). Otherwise ERC-20 `transferFrom` to `recipient` (`address(0)` → `owner()`). Solana home: divide by `10^9`; `quote = Pubkey::default()` is native SOL (system transfer of the exact cost); otherwise SPL `transfer_checked`. `recipient = default` → `admin`. Cost rounds **up**. Inventory is `sale_escrow` (admin funds it after genesis). Home only; spokes have no inventory. All sales and EVM `grant` share the 50M cap. Solana has no `grant`, so `buy` is the only spender of `token_sales_spent`.

### 3.6 Foundation — use of funds

**200M GRS (20%)** is the protocol’s long-term **Foundation-controlled reserve**. It is **not** the same contract as on-chain `[Treasury.sol](../src/Treasury.sol)` (the GRAI fee sink) — Foundation *allocation* is genesis GRS held in a governance vault; *fee flow* is stablecoin / WETH routed via `Treasury.beneficiar` (§4.2).

At TGE **5% of supply (50M GRS)** from this bucket enters circulation. Remaining Foundation GRS requires a **GRS proposal → vote → timelock execution** (≥ 48h delay on spends; upgrades may use a longer delay).

#### Foundation sub-allocation (200M GRS)


| Sub-bucket             | Share of supply | GRS             |
| ---------------------- | --------------- | --------------- |
| **Long-term reserve**  | 15.00%          | 150,000,000     |
| **Audits & Bug Bounty** | 3.00%           | 30,000,000      |
| **Legal**              | 2.00%           | 20,000,000      |
| **Total (Foundation)** | **20.00%**      | **200,000,000** |




#### Spend categories (illustrative)


| Category                     | Examples                                                                                                                                             | Typical cadence                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| **Security & audits**        | Smart-contract audits (pre-mainnet and post-upgrade), formal verification, fuzz/invariant campaigns, **bug bounties**, monitoring / alerting         | Recurring as code ships                   |
| **Legal & compliance**       | Entity setup, token / securities classification memos, Terms of Service & privacy policy, regulatory counsel, trademark                              | Milestone-driven (TGE, new jurisdictions) |
| **Listings & market access** | CEX / aggregator listing fees, market-data subscriptions, secondary liquidity programs beyond the **Liquidity Providing & Market Makers** TGE bucket | As needed                                 |
| **Insurance & risk**         | Protocol cover (e.g. Nexus Mutual–style), incident-response retainer, user-protection fund                                                           | Optional; high bar for large allocations  |
| **GRS buybacks**             | Open-market repurchase or on-chain buyback programs for **GRS**                                                                                      | Discretionary                             |
| **Operations & infra**       | Indexers, RPC, subgraphs, security tooling, analytics — **not** a substitute for the **Team** vesting schedule                                       | Ongoing                                   |
| **Strategic reserve**        | Chain expansion collateral, partnership investments, treasury diversification (stables / ETH)                                                        | Exceptional votes only                    |




#### What Foundation is **not** for


| Need                                                | Funded from                                                                              |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Affiliate / referral programs                       | **Revenue Share Program** bucket (18%) + claim-time `revenueShare` in `Treasury.sol`     |
| Integration grants, CoW / LiFi, operator incentives | **Growth Fund** (12%) bucket                                                             |
| TGE DEX seed liquidity & MM inventory               | **Liquidity Providing & Market Makers** bucket (8%) — **8% TGE · proprietary-gated · ∞** |
| GRAI locker dividends                               | GRAI yield path (`dividendCutBps`) — not Foundation bucket                               |
| Day-to-day core team compensation                   | **Team** vesting (20%)                                                                   |




#### Governance process (target)

1. **Proposal** — public rationale, budget (GRS amount or fiat equivalent), recipient multisig / contract, KPI or deliverable where applicable (e.g. audit scope, legal memo topic).
2. **Vote** — GRS holders via governor; quorum / threshold per §4.1.
3. **Timelock** — queued execution after delay; community can review before transfer.
4. **Reporting** — post-spend summary (audit report link, legal opinion date, listing confirmation) published alongside on-chain tx.

**Security audits** are expected before major deployments and after material upgrades to GRAI / Grinders / Custodian. Internal review reports and external audit outputs live under `[audits/`](../audits/) (e.g. Pashov AI reports, August 2026). Foundation may fund **follow-up audits** and public **bug-bounty** pools as the codebase evolves — separate from the one-time Ecosystem integration budget.

**Legal** spend covers structural questions (who operates the protocol, where), token-holder communications, and compliance for listings / affiliate programs. Legal opinions do **not** replace GRS votes on parameter changes.

---



## 4. Utility



### 4.1 Governance (primary)

GRS holders vote (via `ERC20Votes` + timelock executor) on:


| Surface                           | Examples                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **GRAI** (`owner`)                | `setConfig` knobs, oracle feeds, `setGrinders` / `setTreasury`, liquidation consent limb, UUPS upgrades |
| **Grinders** (`owner`)            | custodian kind registry, `allocate` policy, UUPS upgrades                                               |
| **Treasury** (via `GRAI.owner()`) | `setBeneficiar`, affiliate tier weights, royalty bps                                                    |


Votes do **not** directly move custodian trading keys — NFT owners keep execution control; GRS governs **protocol parameters and fee routing**.

**Vote-gated GRS releases (Growth Fund, Foundation remainder).** On-chain: `GRS.gateOf` marks those buckets `VoteGated`. After `setProprietor(timelock)`, only that address may `grant` from them. Recommended stack (OpenZeppelin v5, home chain only):

1. Add `ERC20Votes` to home GRS (or a hub wrapper) so checkpoints follow `_update` — including OFT burn/mint. Spoke GRS does not vote; bridge home first.
2. `GovernorVotes` + `GovernorTimelockControl` + `TimelockController`.
3. Targets from §4.1 table: proposal **1M GRS (0.1%)**, quorum **4%** of `pastTotalSupply`, delay **48h** for `GRS.grant` / GRAI params, **7d** for upgrades.
4. Timelock is `GRS.proprietor` (and later `GRAI.owner()` / `Grinders.owner()`). A vote-gated spend is a proposal whose calldata is `GRS.grant(bucket, recipient, amount, start, cliff, duration)`.
5. Constructor sets `proprietor = delegate`. After `setProprietor(timelock)`, the TGE delegate can no longer `grant` vote-gated inventory.

Proprietary-gated buckets (Revenue Share, Airdrops, LP & MM) stay on the delegate — no GRS vote.

Quorum / proposal thresholds (targets, tunable at launch):


| Parameter          | Target                                 |
| ------------------ | -------------------------------------- |
| Proposal threshold | 1,000,000 GRS (0.1% supply)            |
| Quorum             | 4% of past votes supply                |
| Timelock delay     | 48h (parameter changes), 7d (upgrades) |




### 4.2 Fee accrual (economic)

Protocol fee path under default GRAI config:

```text
treasuryCutBps  = 33.33% of gross yield
revenueShareBps =  5% of gross yield → affiliates (paid on claim from Treasury inventory)
beneficiar net  ≈ 30.00% of gross yield   → intended GRS stakers / vault
```

**Target staking model:**

1. Stake GRS → receive `xGRS` (non-transferable receipt).
2. `Treasury.beneficiar` points to **FeeVault**; vault streams stablecoins / WETH to `xGRS` holders pro-rata.
3. Optional: vote-escrow (`veGRS`) boosts governance weight without transferring principal.

GRS does **not** entitle holders to GRAI book NAV or locker dividends — only to **protocol fee surplus** after affiliate carve-outs.

### 4.3 What GRS is not

- Not a deposit receipt (use **GRAI**).
- Not a custodian operator license (use **Grinders** NFT + allocation).
- Not an affiliate referral right (use **GRAI-TREASURY** NFT bound at first deposit).
- Not minted by yield events (fixed supply).

---



## 5. Launch & migration plan


| Phase            | Action                                                                                                                              |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **Pre-TGE**      | `beneficiar` = team multisig; GRAI + Grinders `owner` = same multisig                                                               |
| **TGE**          | Canonical GRS mint (1B into home buckets) + spoke OFTs + bridge; `grant` vestings / TGE float; seed LP; open sale claim / airdrop |
| **Migration**    | Transfer GRAI + Grinders ownership to **Timelock** (`GRS.proprietor`)                                                                |
| **Fee hook**     | `Treasury.setBeneficiar(FeeVault)`; FeeVault distributes to GRS stakers                                                             |
| **Steady state** | Upgrades and parameter changes only via GRS proposals                                                                               |


Until migration completes, **GRAI.owner()** remains the live admin surface documented in `[GRAI.md](GRAI.md)` §13.

---



## 6. Relationship to live contracts

Current on-chain defaults (August 2026) that GRS governance inherits:


| Parameter         | Default                     | GRS relevance                       |
| ----------------- | --------------------------- | ----------------------------------- |
| `treasuryCutBps`  | 33_33                       | Size of fee pool routed to Treasury |
| `revenueShareBps` | 5_00                        | Affiliate budget (≤ treasury cut)   |
| Treasury L1/L2    | 80% / 20%                   | Split inside affiliate pool         |
| `beneficiar`      | unset → `address(treasury)` | Fee sink until GRS FeeVault wired   |


Yield cuts (`dividend` / `treasury`) are **fixed at GRAI** `initialize` — changing them requires a GRAI implementation upgrade, itself subject to GRS governance after migration.

---



## 7. Distribution timeline (illustrative)

Assumes TGE = **M0**. Cumulative figures below are **linear-schedule maxima** only — vote-gated remainder (Growth / Foundation 15%) and **proprietary-gated** Revenue Share 18% + LP & MM 8% + Airdrops 2% are **not** treated as free float until released.


| Month    | Cumulative unlocked (max, calendar vests) | Notes                                                                                         |
| -------- | ----------------------------------------- | --------------------------------------------------------------------------------------------- |
| M0 (TGE) | 100M (10%)                                | Token sales 50M + Foundation 50M                                                              |
| M1       | —                                         | Pre-seed linear starts (not TGE)                                                              |
| M3       | —                                         | Seed cliff ends                                                                               |
| M6       | —                                         | Series & Advisors cliff ends                                                                  |
| M12      | —                                         | Core team cliff ends                                                                          |
| M24      | —                                         | Pre-seed fully vested                                                                         |
| M27      | —                                         | Seed fully vested                                                                             |
| M30      | —                                         | Series fully vested                                                                           |
| M67      | —                                         | Airdrops fully vested (67 seasons)                                                            |
| M72      | —                                         | Core team & Advisors fully vested                                                             |
| ∞        | 1B                                        | Growth Fund 12% vote-gated; Revenue Share 18% & LP 8% proprietary-gated; Foundation remainder |


Exact dates depend on TGE; vesting contracts are source of truth post-deploy.

---



## 8. Key invariants (design)

1. **Fixed supply** — 1B cap; no mint function after genesis. Bridged GRS is a representation, not extra issuance (§2.2).
2. **Separation from GRAI** — fund NAV and protocol equity do not share a token.
3. **Fee alignment** — `beneficiar` net ≈ `treasuryCut − affiliatePaid`; GRS value tracks protocol revenue, not locker dividends.
4. **Governance ⊃ admin** — GRS timelock holds `GRAI.owner()` and `Grinders.owner()` after migration.
5. **No custody rights** — GRS does not control Grinders NFT wallets or custodian swap keys.
6. **Affiliate layer unchanged** — Treasury NFT referrals remain independent of GRS holdings.

---



## 9. Instruction reference (planned)


| Contract     | Function                                     | Caller      | Purpose                                                                        |
| ------------ | -------------------------------------------- | ----------- | ------------------------------------------------------------------------------ |
| **GRS**      | `delegate` / `delegateBySig`                 | Holder      | Governance voting (hub)                                                        |
| **GRS**      | `getAllocations` / `grant` / `setProprietor` / `setVeGRS` | Owner / proprietor | Home cap-table inventory; `veGRS` registry                       |
| **GRS**      | `setSale` / `quoteSale` / `buy` / `getSales` | Owner / anyone | Fixed-price `TokenSales` rows (ETH/SOL or ERC-20/SPL), paged `getSales`        |
| **GRS**      | `vest`                                       | Any GRS holder | Lock own GRS (EVM home/spoke; Solana sequential PDA vest, no cap table)        |
| **GRS**      | `bridge` / `quoteBridge`                     | Holder      | Burn here, mint on dest — `dstEid` + recipient + amount (`msg.value` = LZ fee) |
| **GRS**      | `transfer`                                   | Holder      | Secondary liquidity                                                            |
| **GRS**      | `release`                                    | Anyone      | Pull vested tokens (protocol `grant` or holder `vest`)                         |
| **FeeVault** | `stake` / `withdraw` / `claim`               | Holder      | Accrue protocol fees                                                           |
| **Governor** | `propose` / `castVote` / `queue` / `execute` | GRS holders | Parameter & upgrade control                                                    |


---



## 10. Related documents


| Doc                            | Topic                                                |
| ------------------------------ | ---------------------------------------------------- |
| `[protocol.svg](protocol.svg)` | Actors: locker / voter / briber / referrer / poacher |
| `[GRAI.md](GRAI.md)`           | Fund share, yield splits, liquidation                |
| `[GRINDERS.md](GRINDERS.md)`   | Custodian registry, allocate / distribute            |
| `[README.md](../README.md)`    | Deploy, oracles, access control                      |


---

*Last updated: August 2026 — target tokenomics; subject to change before mainnet GRS deployment.*