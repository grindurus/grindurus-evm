# GRAI Protocol — Internal Security Review

| Field | Value |
|-------|-------|
| **Date** | 2026-07-05 |
| **Reviewer** | Internal / Cursor-assisted review |
| **Commit scope** | `grindurus-evm/src` (current implementation) |
| **Solidity** | ^0.8.24 |
| **Type** | Informal code review — **not** a substitute for a professional third-party audit |

---

## Executive Summary

GRAI is a UUPS-upgradeable ERC20 index token backed by a two-tranche (senior/junior) multi-asset NAV vault. The codebase is compact, uses OpenZeppelin upgradeable primitives, applies `ReentrancyGuard` on state-changing entry points, and separates oracle logic into an upgradeable router.

**No critical exploitable vulnerabilities** were identified under a standard deployment with a trusted admin and correctly configured oracle feeds.

The main risks are **admin centralization**, **accounting invariants that can block asset removal**, **non-standard ERC20 compatibility**, and **oracle misconfiguration** (especially on L2 and with Pyth pull feeds).

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 6 |
| Low | 5 |
| Informational | 6 |

---

## Scope

### In scope

| File | Description |
|------|-------------|
| `src/GRAI.sol` | UUPS ERC20 + protocol core (mint/burn/allocate/distribute/NAV) |
| `src/PriceOracleRouter.sol` | UUPS oracle router (Chainlink / Pyth / custom) |
| `src/VaultBase.sol` | Multi-asset custody (ERC20 + native ETH via `address(0)`) |
| `src/SeniorVault.sol` | Idle reserve (burn redemptions) |
| `src/JuniorVault.sol` | Active capital store |
| `src/interfaces/*` | Public interfaces |

### Out of scope

- Off-chain custody / strategy logic
- Frontend, deployment keys, key management
- Economic modelling beyond on-chain accounting
- Formal verification
- Fork/integration tests against live mainnet state

---

## Architecture Overview

```
GRAI (UUPS proxy)
  ├── SeniorVault (multi-asset idle)
  ├── JuniorVault (multi-asset active)
  └── PriceOracleRouter (UUPS proxy)
        ├── Chainlink feeds
        ├── Pyth feeds
        └── Custom on-chain feeds
```

**Key design choices:**

- Single `SeniorVault` + single `JuniorVault` hold all registered assets.
- Native ETH is represented by `address(0)`.
- `totalValue` is internal USD-denominated accounting (18 decimals), updated on `mint`, `burn`, and `distribute` (senior yield portion only).
- Burns redeem **only** from senior idle balances, not from junior or custody.
- ERC-1046 `tokenURI()` is supported for wallet metadata.

---

## Methodology

- Manual line-by-line review of in-scope contracts
- Invariant and edge-case analysis (rounding, oracle failure modes, reentrancy, upgrade safety)
- Cross-check against existing unit tests (`forge test --no-match-path "test/fork/*"`)
- Trust-model and admin-privilege analysis

---

## Trust Model

| Actor | Trust assumption |
|-------|------------------|
| `DEFAULT_ADMIN_ROLE` (GRAI) | Can upgrade implementation, allocate junior funds to any custody, remove assets (sweeping vault balances), change splits/treasury/tokenURI |
| `owner` (PriceOracleRouter) | Can register feeds, change `maxStaleness`, upgrade router |
| Custom oracle signer | Can set on-chain prices for custom feeds |
| Custody wallets | Off-chain; on-chain only `allocate` / permissionless `distribute` |
| Users | Trust oracle prices and senior idle liquidity at burn time |

---

## Findings

### [H-1] `activeAmount` never decreases — `removeAsset` permanently blocked after allocation

**Severity:** High  
**Status:** Open  
**Location:** `GRAI.sol` — `allocate`, `removeAsset`

`activeAmount` is incremented in `allocate` but never reduced when capital returns via `distribute` or any other path.

```solidity
// allocate
a.activeAmount += amount;

// removeAsset
require(a.activeAmount == 0, "active funds");
```

**Impact:** Once any amount has been allocated for an asset, that asset can never be delisted via `removeAsset`, even if all funds have returned and the junior vault is empty.

**Recommendation:**

- Add a `deallocate` admin function, or
- Decrease `activeAmount` when yield/capital is returned (e.g. on `distribute`), or
- Rename to `totalAllocated` and replace the removal guard with a check on current junior balance / outstanding custody exposure.

---

### [H-2] Admin centralization and upgrade authority

**Severity:** High  
**Status:** Acknowledged (design)  
**Location:** `GRAI.sol`, `PriceOracleRouter.sol`

| Privilege | Risk |
|-----------|------|
| GRAI UUPS upgrade | Malicious implementation can steal all vault funds |
| `allocate(asset, custody, amount)` | Drains junior vault to any non-zero address |
| `removeAsset` | Sweeps all senior/junior balances to `msg.sender` (admin) |
| Oracle `owner` | Can register malicious custom feeds or widen staleness window |

**Impact:** A compromised admin key is equivalent to full protocol loss.

**Recommendation:** Multisig + timelock; separate `UPGRADER_ROLE` from day-to-day operations; consider on-chain limits on `allocate` destinations.

---

### [M-1] `totalValue` accounting vs. physical vault balances

**Severity:** Medium  
**Status:** Open (design nuance)  
**Location:** `GRAI.sol`, `VaultBase.sol`

`totalValue` is updated only through `mint`, `burn`, and `distribute`. Direct transfers to vaults (ERC20 `transfer` or ETH via `receive()`) increase physical balances without updating `totalValue`.

**Impact:**

- **For existing holders at burn:** Unaccounted senior donations improve exit liquidity (more senior idle) without raising GRAI price — effectively hidden yield.
- **For subsequent minters:** `mint` pricing uses stale `totalValue`, so new entrants may receive **more GRAI per dollar** than fair NAV would imply, diluting existing holders.
- This is **unaccounted protocol income**, not stolen funds, but it breaks the invariant that `totalValue / supply` reflects all protocol assets.

**Recommendation (pick one):**

1. Revert on unsolicited deposits (`receive()` revert; document no direct token transfers).
2. Add admin `sync()` to recompute `totalValue` from on-chain balances × oracle prices.
3. Document explicitly that direct vault transfers are voluntary donations that do not rebase NAV.

---

### [M-2] Burn accounting vs. senior-only payout

**Severity:** Medium  
**Status:** Acknowledged (design)  
**Location:** `GRAI.sol` — `burn`

`burnValue` is deducted from `totalValue` based on full NAV share, but physical payout is:

```solidity
redeem = graiAmount * idleBal / supply; // senior idle only
```

**Impact:** When senior idle is low relative to NAV (most capital in junior/custody), burners receive less in assets than `burnValue` implies. `totalValue` and redeemable liquidity diverge over time.

**Recommendation:** Expose a view function `redeemableValue(graiAmount)`; optionally revert when senior liquidity is insufficient for expected payout; document clearly for integrators.

---

### [M-3] Fee-on-transfer, rebasing, and non-standard ERC20

**Severity:** Medium  
**Status:** Open  
**Location:** `GRAI.sol` — `mint`, `distribute`

Mint computes `depositValue` from the requested `amount`, but fee-on-transfer tokens may deliver less to the vault.

**Impact:** NAV overstated relative to actual assets → insolvency risk for other holders.

**Recommendation:** Asset whitelist; or measure `balanceAfter - balanceBefore` on mint/distribute deposits.

---

### [M-4] Oracle — Pyth `getPriceUnsafe` and missing L2 sequencer checks

**Severity:** Medium  
**Status:** Open  
**Location:** `PriceOracleRouter.sol`

- Pyth prices are read via `getPriceUnsafe` with a staleness window only.
- Chainlink reads on L2 do not check the L2 sequencer uptime feed.

**Impact:** Stale or unreliable prices during oracle downtime / sequencer outages can cause mispriced mints, burns, or yield accounting.

**Recommendation:** Use Pyth's validated/staleness-aware API where available; add Chainlink sequencer uptime + grace period on Arbitrum, Base, Optimism.

---

### [M-5] Oracle feeds are immutable after registration

**Severity:** Medium  
**Status:** Open  
**Location:** `PriceOracleRouter.sol`, `GRAI.sol`

- Feeds can be added but not removed or re-typed (`exists` guard).
- `GRAI.oracle` is set only in `initialize`; no `setOracle`.

**Impact:** Misconfigured feeds require router upgrade or GRAI upgrade to remediate.

**Recommendation:** Add `removeFeed` / `updateFeed`; add `setOracle` on GRAI (admin + timelock).

---

### [M-6] Permissionless `distribute` with unverified caller

**Severity:** Medium  
**Status:** Open  
**Location:** `GRAI.sol` — `distribute`

Any address can call `distribute` if it supplies yield. `yieldReturned[msg.sender][asset]` is incremented without verifying the caller is a registered custody wallet.

**Impact:** No direct fund loss (caller must bring assets), but on-chain yield attribution is unreliable for governance, reporting, or slashing logic.

**Recommendation:** Require `allocatedAmount[msg.sender][asset] > 0` or a dedicated `CUSTODY_ROLE`.

---

### [L-1] Direct vault donations — unaccounted income (H-1 reclassified)

**Severity:** Low  
**Status:** Acknowledged  
**Location:** `VaultBase.sol`

See [M-1]. If the protocol intentionally treats unsolicited vault deposits as voluntary donations that do not rebase NAV, this is a **documented design choice**, not an exploitable bug. Residual risk: dilution of existing holders on the next `mint`.

---

### [L-2] Chainlink round completeness not checked

**Severity:** Low  
**Location:** `PriceOracleRouter._chainlink`

Only `answer > 0` and staleness are validated; `answeredInRound >= roundId` is not checked.

---

### [L-3] `mintSplit = 0` routes 100% to junior

**Severity:** Low  
**Location:** `GRAI.setMintSplit`

All new deposits go to junior; no senior idle is built for that asset → instant burn liquidity is zero for those deposits.

---

### [L-4] Unbounded ETH `call{value}` in vault withdraw

**Severity:** Low  
**Location:** `VaultBase.withdraw`

Forwards all gas to recipient; smart contract recipients with heavy fallbacks may fail redemption.

---

### [L-5] `nav()` view excludes junior and custody

**Severity:** Low  
**Location:** `GRAI.nav`

Returns USD value of senior idle only, which may diverge significantly from `totalValue` used for mint/burn pricing.

---

### [L-6] Vaults are non-upgradeable and bound to GRAI proxy address

**Severity:** Low  
**Location:** `GRAI.initialize`, `VaultBase`

Vault `proprietor` is the GRAI proxy address (correct for UUPS). A future migration to a new GRAI proxy would leave vaults attached to the old address — requires a deliberate migration plan.

---

## Informational

| ID | Note |
|----|------|
| I-1 | Reentrancy protection and CEI ordering on `burn` (`_burn` before external withdrawals) appear correct. |
| I-2 | `ERC20Burnable` intentionally omitted — burns must go through protocol redemption. |
| I-3 | Storage gaps present: GRAI (`39`), PriceOracleRouter (`48`). |
| I-4 | `_disableInitializers()` correctly used in implementation constructors. |
| I-5 | Integer rounding dust on multi-asset burn loops is expected. |
| I-6 | ERC-1046 metadata is off-chain; no on-chain security impact. |

---

## What Looks Good

- Compact, readable codebase with clear separation of oracle / vault / core logic.
- `SafeERC20`, `ReentrancyGuard`, and UUPS with `_authorizeUpgrade` gated by admin.
- Multi-asset vault abstraction with unified `address(0)` sentinel for native ETH.
- Oracle router consolidates Chainlink, Pyth, and custom feeds without per-asset adapter contracts.
- Unit test suite covers core flows including ETH mint/burn, allocate, distribute, and oracle failure modes.

---

## Recommended Remediation Priority

| Priority | Item | Effort |
|----------|------|--------|
| P0 | Multisig + timelock for admin roles | Operational |
| P1 | Fix `activeAmount` / `removeAsset` ([H-1]) | Medium |
| P1 | Asset whitelist or balance-diff on mint ([M-3]) | Low–Medium |
| P2 | Document or fix unaccounted vault donations ([M-1]) | Low |
| P2 | L2 sequencer checks + safer Pyth API ([M-4]) | Medium |
| P2 | `setOracle`, `removeFeed`, redeemable liquidity views | Low |
| P3 | Restrict `distribute` caller ([M-6]) | Low |

---

## Conclusion

The GRAI EVM implementation is structurally sound for an MVP or testnet deployment with a trusted admin. Before mainnet launch with significant TVL, we recommend:

1. Professional third-party audit
2. Resolving [H-1] (`activeAmount` / asset removal)
3. Decentralizing admin and upgrade keys
4. Hardening oracle configuration (L2 feeds, Pyth keepers, custom feed governance)
5. Explicit policy on supported ERC20 types and unsolicited vault deposits

---

## Disclaimer

This document is an **internal informal review** prepared for the development team. It does not constitute financial, legal, or investment advice. Findings reflect the codebase at the time of review and may not cover all vulnerabilities. A full independent audit is strongly recommended before mainnet deployment.
