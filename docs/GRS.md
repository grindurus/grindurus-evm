# GRS — protocol token

Fixed-supply protocol equity / governance for Grindurus. On-chain OFT: `[GRS.sol](../src/GRS.sol)` (EVM) and `[programs/grs](../../grindurus-solana/programs/grs)` (Solana). Related: `[GRAI.md](GRAI.md)`, `[GRINDERS.md](GRINDERS.md)`, `[Treasury.sol](../src/Treasury.sol)`.


|        | **GRAI**                   | **GRS**                                                 |
| ------ | -------------------------- | ------------------------------------------------------- |
| Role   | USD book-priced fund share | Protocol equity + gov; claim on treasury / `beneficiar` |
| Supply | Elastic (NAV)              | **1B**, fixed at genesis                                |


```
yield on custodians → GRAI.distribute
  ├─ dividendCut 50% → unvoted lockers (else treasury)
  └─ treasuryCut 50% → Treasury
        ├─ revenueShare 5% of yield → affiliates (on claim)
        └─ remainder → Treasury.beneficiar → admin + GRS/ETH buy → GRS to affiliates
```

At launch `beneficiar` is `GRAI.owner()`. Target: GRS-governed FeeVault so the ~30% net (treasury cut minus affiliates) accrues to stakers, not a static wallet.

Metadata: `https://grindurus.xyz/grs.json` (ERC-1046).

---

## 1. Token


|                    |                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Name / symbol      | Grindurus Token / **GRS**                                                                                                        |
| Cap                | **1,000,000,000** — no mint after genesis                                                                                        |
| Networks           | Solana, Ethereum, Arbitrum, … — LayerZero OFT                                                                                    |
| Cap-table decimals | **18** (`1 GRS = 10¹⁸`)                                                                                                          |
| EVM local          | 18                                                                                                                               |
| Solana local       | **9** (`1 GRS = 10⁹`, fits `u64`); shared decimals **6** on both. Bridge is 1:1 in GRS units, no dust mint/burn of whole tokens. |
| Upgrade            | Token non-upgradeable; gov via timelock on GRAI / Grinders / Treasury                                                            |


### Home vs spokes

One **home** (Solana or Ethereum, fixed at TGE) mints the **entire 1B once**. Mint authority is then frozen. Every other chain is a **spoke**: bridged representation, not a second genesis. Changing home is a GRS migration (new lockboxes), not a second mint.

### Bridge (burn/lock ↔ mint/unlock)

Circulating GRS (home unlocked + all spokes) never exceeds 1B, and never exceeds what home released from vesting / sale / gates.


| Direction     | Source                 | Dest                          |
| ------------- | ---------------------- | ----------------------------- |
| Home → spoke  | Lock (or burn) on home | Mint 1:1                      |
| Spoke → home  | Burn                   | Unlock from home lockbox      |
| Spoke → spoke | Burn                   | Mint (home lockbox unchanged) |


1. `Σ spoke.supply + home.liquid + home.lockbox = 1B`. Unreleased vest escrow is in the lockbox; it cannot bridge until `release`.
2. Spoke mint authority is **only** the OFT adapter. Home mint stays revoked. Lockbox never mints.
3. Amount in = amount out. Failed messages do not mint.
4. New chain = new spoke + same accounting — **zero** extra genesis.
5. Token sales: home **lists** with `sale` (`dstEid` LZ-publishes to a spoke, burns `grsAmount`); the spoke `lzReceive` writes the row **and mints into escrow**. Mechanics: [§3 Token sales](#token-sales). LP & MM may still seed on home, then bridge.
6. Votes live on home (or an EVM hub). Spoke GRS does not vote until bridged. Checkpoints do not copy across the bridge.

Vendor is an implementation choice. Accounting is the spec.

---

## 2. Cap table

1B on **home** only. Charts: `[grs.svg](grs.svg)`, `[grs-vesting.svg](grs-vesting.svg)`. Groups (left → right): Investments → Affiliates → Team → Ecosystem → Foundation.


| Bucket                    | Share    | GRS      | Gate        | Unlock                                               |
| ------------------------- | -------- | -------- | ----------- | ---------------------------------------------------- |
| **Investments**           | **20%**  | **200M** |             |                                                      |
| Token sales               | 15%      | 150M     | Instant     | TGE, no vest (`buy` / optional `grant`)              |
| Pre-seed                  | 5%       | 50M      | Linear      | no cliff, 24m after TGE (fully M24)                  |
| **Affiliates & airdrops** | **20%**  | **200M** |             |                                                      |
| Revenue Share             | 15%      | 150M     | Proprietary | TGE allocated · ∞ (ops, no GRS vote)                 |
| Airdrops                  | 5%       | 50M      | Proprietary | TGE · 67 seasons (M67)                               |
| **Team**                  | **20%**  | **200M** |             |                                                      |
| Core team                 | 15%      | 150M     | Linear      | 12m cliff, 60m (M72)                                 |
| Advisors                  | 5%       | 50M      | Linear      | 6m cliff, 66m (M72)                                  |
| **Ecosystem**             | **20%**  | **200M** |             |                                                      |
| Growth Fund               | 10%      | 100M     | Proprietary | TGE allocated · ∞ (ops, no GRS vote)                 |
| LP & MM                   | 10%      | 100M     | Proprietary | TGE · ∞ — DEX / MM inventory, then bridge            |
| **Foundation**            | **20%**  | **200M** |             | not `[Treasury.sol](../src/Treasury.sol)` (fee sink) |
| Long-term reserve         | 15%      | 150M     | Proprietary | TGE allocated · ∞ (ops, no GRS vote)                 |
| Audits & Bug Bounty       | 3%       | 30M      | Proprietary | TGE allocated · ∞ (ops, no GRS vote)                 |
| Legal                     | 2%       | 20M      | Proprietary | TGE allocated · ∞ (ops, no GRS vote)                 |
| **Total**                 | **100%** | **1B**   |             |                                                      |


**TGE (M0):** 200M (20%) free float = sales 150M + Foundation 50M. 400M (40%) gated at TGE (Revenue Share, Airdrops, Growth, LP). 400M (40%) still locked: 250M calendar vest (Pre-seed + Team) + 150M Foundation proprietary-gated.


| Term              | Meaning                                               |
| ----------------- | ----------------------------------------------------- |
| Cliff             | locked until cliff end                                |
| Linear            | time unlock after (or instead of) cliff               |
| Proprietary-gated | team / ops from TGE; no GRS vote                      |
| ∞                 | no calendar end                                       |


---

## 3. On-chain (home EVM `grant`; Solana has no cap table)

Constructor mints 1B to `address(this)`, not the delegate. `grant` spends inventory (does not mint). Spokes revert `NotHome` on cap table. Solana has no `grant`; TokenSales is `buy` only.

### Who may `grant`

Depends on `gateOf(bucket)`, not the cliff/duration args. Instant vs vest is `cliffSeconds = durationSeconds = 0`. Instant may set `dstEid` so the recipient is paid on a spoke.


| Gate        | Buckets                                       | Caller       |
| ----------- | --------------------------------------------- | ------------ |
| Instant     | Token sales                                                                          | `owner` |
| Linear      | Pre-seed, Core team, Advisors                                                        | `owner` |
| Proprietary | Revenue Share, Airdrops, LP & MM, Growth Fund, Long-term reserve, Audits, Legal     | `owner` |


`proprietor` starts as the delegate. `setProprietor(timelock)` (owner, home) retargets the recorded gov address; cap-table `grant` stays `owner`.

`Bucket.Holder` is not a cap-table row (`capOf = 0`). Holders use `vest`.

**Accounting.** `spent[bucket] += amount` immediately (including still-locked vests). Over cap → `BucketExceeded`. No `revoke`.

**Payout.** Instant, `dstEid = 0`: transfer from the contract, `vestingId = 0`. `to` must be an EVM address (high 12 bytes 0). Instant, `dstEid ≠ 0`: same spend, then OFT-send from inventory to `to` on that chain — `bytes32` (Solana pubkey as-is, EVM address left-padded). `quoteGrant` / LZ fee; dust-free amount. Vesting grants stay on home (`dstEid` must be 0); tokens stay on `GRS`, id ≥ 1, `funder = address(this)`. `start = 0` → now. Cliff end = `start + cliff`; linear until `cliffEnd + duration`. `duration = 0` unlocks all at cliff. Timestamp overflow → `InvalidSchedule`. Protocol `grant` is **not** bound by holder `MAX_CLIFF` / `MAX_DURATION` (team 60m / advisors 66m still fit). `scheduleOf` is SVG months for UIs; gated rows report `0/0`.

`**release(id)**` is permissionless to the beneficiary. Unreleased GRS cannot bridge.

`getAllocations()` home-only (11 rows). `getVestings(offset, limit)` — 0-based offset, id = offset+1.

### Holder `vest`

Any holder, home or spoke (EVM / Solana). Instant (cliff = duration = 0) reverts — use `transfer`. Cliff ≤ 365d, linear ≤ 4×365d. Solana: sequential id = `vesting_count + 1`; `get_vestings` remaining accounts are those PDAs.

### Token sales

Public TGE float from bucket **TokenSales** (150M, Instant, no vest). The book can hold many rows: each is remaining GRS (`grsAmount`) and remaining asset (`assetAmount`). `buy` pays a share of `assetAmount` and receives GRS immediately. Home may also `grant(TokenSales, …)` (EVM only); that spend **shares** the same 150M as `buy` on that OFT. Local listing (`dstEid = 0`) does not reserve the bucket; listing to a spoke does.

Home **LZ-publishes** the row with `sale(..., dstEid)`: home **burns** `grsAmount` from TokenSales inventory and the spoke `lzReceive` writes the row (`SaleAccepted`) **and mints that GRS into escrow**. Native `asset = 0` copies as native on every chain. `asset` and `recipient` are `bytes32` (EVM address left-padded; Solana mint / pubkey is already 32 bytes). On the wire `grsAmount` is OFT **shared decimals** (6); each chain stores local decimals.

```
home owner          sale(asset, assetAmount, grsAmount, recipient, dstEid)
                      → id = saleCount+1; SaleSet; dstEid ≠ 0 also SalePublished
spoke               lzReceive(sale payload)                           → mint escrow; SaleAccepted
anyone              quoteSale(...) / previewBuy(id, grsAmount)
                    Solana: quote_sale(dstEid, id) / preview_buy(id, amount)
anyone              buy(id, amount, to)   → quote in, GRS out
anyone              getSales(offset, limit) / saleCount
```

LZ sale payload is 192 bytes: `keccak256("GRS.sale") || id || asset || assetAmount || grsAmountSD || recipient`.

#### Book

Ids are **1-based**, assigned on `sale` (`saleCount + 1`). Rows are append-only on home; spoke `lzReceive` writes the published id. Several rows at once (ETH/SOL + USDC). Solana registry cap **16** rows.

| Field         | Closed / empty                                            | Meaning                                                                 |
| ------------- | --------------------------------------------------------- | ----------------------------------------------------------------------- |
| `asset`       | `bytes32(0)` / `Pubkey::default()`                        | Native ETH (EVM) or SOL (Solana). Else the ERC-20 / SPL mint as 32 bytes. |
| `assetAmount` | `0`                                                       | Remaining `asset` for remaining `grsAmount`. Zero **closes** (`SaleClosed`). |
| `grsAmount`   | `0`                                                       | Remaining GRS at this id.                                               |
| `recipient`   | `bytes32(0)` / `Pubkey::default()`                        | Quote payee. Empty → `owner()` (EVM) / `oft_store.admin` (Solana). EVM address left-padded; Solana pubkey as-is. |


`recipient` must not be the GRS contract itself (`InvalidRecipient`). Solana also rejects the program id, OFT store, and `sale_escrow`. EVM `buy` pays the low 20 bytes and reverts if the high 12 bytes are set (a Solana pubkey is the spoke payee after LZ, not an ETH / ERC-20 destination).

Home **lists** with `sale` (id auto; `dstEid = 0` is local, no burn). `dstEid ≠ 0` burns `grsAmount` (dust-free, TokenSales) then LZ-publishes. Spoke **lzReceive** writes the row and mints `grsAmount` into escrow (once per id). `sale` on a spoke reverts `NotHome`; a sale payload on home `lzReceive` reverts `NotSpoke`. `sale` is `onlyOwner` / admin on home. Solana: `sale` appends; `publish_sale` burns from `sale_escrow` and is the LZ hop. A row closes when remaining `assetAmount` / `grsAmount` hits 0 (full `buy`, or a listing already at 0).

#### `buy`

1. Open sale (`assetAmount ≠ 0` and `grsAmount ≠ 0`), buy `amount ≠ 0`, `to ≠ 0`. Buy over remaining → `SaleExceeded`. Sold-out `grsAmount == 0` → `SaleClosed`.
2. Cost: buying the **whole remainder** pays remaining `assetAmount` exactly. A partial fill is `floor(amount × assetAmount / remaining GRS)`. Zero cost reverts.
3. Decrement that row’s remaining `grsAmount` **and** `assetAmount`.
4. Debit TokenSales: EVM `spent[TokenSales]`; Solana `token_sales_spent`. Over 150M → `BucketExceeded`. Local listing does **not** lock the 150M; listing with `dstEid ≠ 0` **does** (home burns that GRS). `buy` hits `min(row remaining, 150M left, escrow)`.
5. Quote to `recipient` (or owner/admin): native must equal `cost` (`msg.value` / SOL transfer); ERC-20/SPL `transferFrom` / `transfer_checked` and `msg.value == 0`.
6. GRS from **escrow** to `to`. Instant — no vest. Buyer may `bridge` next.

Insufficient escrow reverts (ERC-20 / SPL). `buy` never mints.

#### Inventory and cap

|                | Home                                                                 | Spoke                                                                 |
| -------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Escrow         | EVM: `address(this)` (1B genesis). Solana: `sale_escrow` (fund from genesis mint). | Minted by home `sale(..., dstEid)` / `publish_sale` into this contract / `sale_escrow`. |
| TokenSales 150M | This OFT's `spent` / `token_sales_spent`. Home `grant(TokenSales)` and dest-chain `sale` count. | Same 150M **locally**. Not a shared LZ counter.                       |


Genesis 150M TokenSales inventory lives on **home**. A spoke sale is minted into escrow when home publishes the row (1:1 burn on home). Do not also grant the same TokenSales GRS on home.

`getSales(offset, limit)` — 0-based offset, id = offset+1. Empty page if `offset >= saleCount` or `limit = 0`.

### Foundation (200M)

Genesis GRS in a protocol vault — not the GRAI fee sink. 50M TGE float; remainder proprietary-gated (ops `grant`). Not for: affiliates (Revenue Share), integrations (Growth), TGE LP (LP & MM), locker dividends (GRAI), or team pay (Team vest).

---

## 4. Utility

Votes do not move custodian keys. GRS governs parameters and fee routing.


| Surface                     | Examples                                                                |
| --------------------------- | ----------------------------------------------------------------------- |
| GRAI `owner`                | `setConfig`, feeds, Grinders/Treasury wiring, liquidation consent, UUPS |
| Grinders `owner`            | custodian registry, allocate policy, UUPS                               |
| Treasury via `GRAI.owner()` | `setBeneficiar`, affiliate weights, royalty                             |


**Cap-table releases (home):** `grant` is `owner` for every bucket (Instant / Linear / Proprietary). Target stack for **protocol** params still: `ERC20Votes` on home GRS (checkpoints follow `_update`, including OFT) + Governor + timelock as `GRAI.owner()` / `Grinders.owner()`. Spoke GRS does not vote. Proposal **0.1%** (1M GRS), quorum **4%** of past supply, delay **48h** params / **7d** upgrades.

**Fees (default GRAI):** `treasuryCut` 33.33% of yield; `revenueShare` 5% affiliates; beneficiar net ≈ 30%. Stake GRS → `xGRS`; FeeVault streams stables/WETH pro-rata. Optional `veGRS` boosts votes. GRS never claims GRAI NAV or locker dividends.

**Not:** a deposit receipt (GRAI), operator license (Grinders NFT), affiliate right (GRAI-TREASURY NFT), or yield-minted token.

---

## 5. Launch


| Phase     | Action                                                            |
| --------- | ----------------------------------------------------------------- |
| Pre-TGE   | `beneficiar` + GRAI/Grinders `owner` = team multisig              |
| TGE       | 1B home mint + spoke OFTs + bridge; `grant` / sale / LP / airdrop |
| Migration | GRAI + Grinders `owner` → timelock (`GRS.proprietor`)             |
| Fee hook  | `setBeneficiar(FeeVault)` → GRS stakers                           |
| Steady    | params / upgrades only via GRS vote                               |


Until then live admin is `[GRAI.md](GRAI.md)` §13. Yield cuts are fixed at GRAI `initialize`; changing them is an upgrade, GRS-gated after migration. Defaults: `treasuryCutBps` 33_33, `revenueShareBps` 5_00, L1/L2 80/20.

---

## 6. Invariants

1. 1B cap; bridged GRS is a representation, not extra issuance.
2. `buy` / `grant` transfer escrow; they do not mint. Spoke sale inventory is minted on `lzReceive` of a home sale (home burned the same GRS).
3. GRAI NAV and GRS equity are different tokens.
4. GRS tracks protocol fee surplus (`beneficiar` net), not locker dividends.
5. After migration the GRS timelock is `GRAI.owner()` / `Grinders.owner()`.
6. GRS does not control Grinders wallets or swap keys; Treasury NFTs stay independent.

---

## 7. Surface


| Surface            | Functions                                              | Caller             |
| ------------------ | ------------------------------------------------------ | ------------------ |
| Cap table (home)   | `grant`, `quoteGrant`, `getAllocations`, `setProprietor`, `setVeGRS` | owner              |
| Token sales        | `sale`, `quoteSale`, `previewBuy`, `buy`                | owner / anyone     |
| Vesting            | `vest`, `release`, `getVestings`                       | holder / anyone    |
| Bridge (OFT)       | `bridge`, `quoteBridge`, `getPeers`                    | holder / anyone    |
| Votes (home hub)   | `transfer`, `delegate`                                 | holder             |


Spokes: `NotHome` on cap table and `sale`. Sale `lzReceive` is spoke-only (`NotSpoke` on home). Hub votes only on home GRS.

`[protocol.svg](protocol.svg)` · `[GRAI.md](GRAI.md)` · `[GRINDERS.md](GRINDERS.md)` · `[README.md](../README.md)`

*August 2026 — target tokenomics; subject to change before mainnet GRS.*