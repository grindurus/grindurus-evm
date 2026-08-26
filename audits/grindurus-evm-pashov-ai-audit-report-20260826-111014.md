# 🔐 Security Review — grindurus-evm (GRAI / Grinders / GRS)

**Audit tooling:** [Pashov solidity-auditor](https://github.com/pashov/skills) + [Trail of Bits skills](https://github.com/trailofbits/skills) (trailmark, variant-analysis)  
**Method:** Multi-agent static review (economic, access control, math/precision, execution traces), Foundry test verification (198 passed / 0 failed)  
**Date:** 2026-08-26

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL (default)                                          |
| **Files reviewed**               | `CoWCustodian.sol` · `LiFiCustodian.sol` · `SwapCustodian.sol`<br>`Custodian.sol` · `GRAI.sol` · `Grinders.sol`<br>`GRS.sol` · `PriceOracleRouter.sol` · `Treasury.sol` |
| **Confidence threshold (1-100)** | 75                                                     |
| **Excluded**                     | `interfaces/`, `lib/`, `test/`, `mocks/`               |

---

## Executive summary

The codebase is mature: extensive Foundry coverage, explicit lifecycle documentation, and several previously dangerous paths (liquidation atomicity, redeem reentrancy, referral loops) are already guarded and tested.

No **Critical** or **High** unprivileged fund-theft path was confirmed in this pass. The main actionable items are an **unimplemented custodian kind** that can still be registered, **keeper-dependent liquidation sweeps** that can fail silently per custodian, and **documented trust boundaries** around CoW order signing and treasury solvency.

---

## Findings

[82] **1. LiFi custodian is an empty stub but can be registered and allocated capital**

`LiFiCustodian` (all functions) · Confidence: 82

**Description**

`LiFiCustodian` contains only a kind constant and `TO BE IMPLEMENTED`; it inherits `Custodian` but provides no swap path. `Grinders.set` / `Grinders.mint` still allow registering this implementation, and the owner can `allocate` real assets into a wallet that cannot trade them back.

**Fix**

```diff
- // TO BE IMPLEMENTED
+ function swap(...) external { ... }

// Or, until implemented:
+ function mint(...) public override onlyOwner returns (address custodian) {
+     if (custodianKind == LIFI_KIND) revert UnknownCustodianKind(custodianKind);
+     ...
+ }
```

---

[78] **2. Per-custodian liquidation sweeps can fail silently, stranding assets for redeemers**

`Grinders.liquidate` · Confidence: 78

**Description**

When paging custodians (`fromId < toId`), each `ICustodian.liquidate()` call is wrapped in `try/catch {}`. A reverting custodian (buggy implementation, ETH push failure, or malicious proxy) is skipped without aborting the sweep. GRAI redemption later pays only from balances already on GRAI, so assets left in failed custodians dilute redeemers until a successful keeper sweep.

**Fix**

```diff
- } catch {}
+ } catch (bytes memory err) {
+     emit LiquidateCustodianFailed(i, custodian, err);
+ }
+ // Optionally: revert after emitting, or track failed ids for keeper retry
```

---

[75] **3. CoW custodian does not constrain economic order fields beyond asset/receiver bounds**

`CoWCustodian.isValidSignature` · Confidence: 75

**Description**

The contract correctly binds `receiver == address(this)`, sell/buy ∈ `{base, quote}`, and digest equality, but does not cap `feeAmount`, `partiallyFillable`, `validTo`, or balance-source fields. A compromised or careless NFT owner can sign orders that leak value to solvers/fees while still passing EIP-1271 validation — principal cannot be sent to an arbitrary wallet, but execution quality is entirely off-chain policy.

---

[75] **4. Treasury books credit on claim even when affiliate payouts are skipped for insufficient balance**

`Treasury.distribute` · Confidence: 75

**Description**

`_creditBooks(locker, claimedValue)` runs before the balance check. If `balance < grossProfitShare`, the function returns without paying affiliates, but referral book volumes (`value`, `l1Value`, `l2Value`) still increase. `poachOf` pricing (`value + l1Value`) can rise without a matching treasury payout, skewing poach economics during treasury insolvency.

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. Not scored._

- **Fail-open liquidation gate on Grinders** — `Grinders.liquidation` — Code smells: `try/catch` around `grai.liquidation()` returns `true` on revert; empty `grai` code also returns `true` — Keepers may run sweeps when the linked GRAI contract is miswired or reverting; impact depends on whether GRAI is actually in `REDEMPTION`.

- **Pyth unsafe price reads** — `PriceOracleRouter._pyth` — Code smells: `getPriceUnsafe` without on-chain `updatePriceFeeds` — Staleness is bounded by `maxStaleness`, but manipulable publish timestamps within the window remain an oracle-trust assumption.

- **Swap custodian arbitrary external call** — `SwapCustodian.swap` — Code smells: `target.call(data)` with max ERC20 approvals to arbitrary `target` — Owner-only; a malicious router could drain approved inventory; operational key-management risk.

- **Custodian yield fallback routing** — `Custodian.distribute` — Code smells: nested `try/catch` falls back to transferring yield to `grinders` if `grai.distribute` fails — Yield may sit on Grinders instead of entering GRAI dividend accounting until manually recovered.

- **Orphan GRAI dilution at redeem** — `GRAI.redeem` / `GRAI.liquidate` — Code smells: unlock fees and unredeemed escrow GRAI on the contract reduce per-share asset claims — Documented protocol behavior; monitor `balanceOf(GRAI) - totalLocked` before liquidation.

- **LiFi / incomplete deployment surface** — `Grinders.mint` — Code smells: no on-chain guard preventing mint of unimplemented custodian kinds — Complements Finding #1; deployment checklist item.

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [82] | LiFi custodian is an empty stub but can be registered and allocated capital |
| 2 | [78] | Per-custodian liquidation sweeps can fail silently, stranding assets for redeemers |
| 3 | [75] | CoW custodian does not constrain economic order fields beyond asset/receiver bounds |
| 4 | [75] | Treasury books credit on claim even when affiliate payouts are skipped for insufficient balance |

---

## Positive observations

- **Liquidation atomicity:** `GRAI.liquidate` flips regime then calls Grinders sweeps without swallowing reverts at the GRAI layer (`test_LiquidateReverts_WhenGrindersLiquidateReverts`).
- **Redeem reentrancy:** `nonReentrant` on `redeem` prevents nested claims mid-loop over the asset basket.
- **Bribe settlement:** FoT protection via `received == bribeAmount` and escrow reservation before `_pay`.
- **Referral safety:** Floyd cycle detection on `rebind` / first `mint` bind; protocol sinks rejected as referrers.
- **GRS cross-chain:** Compose disabled; magic `to` addresses blocked; `MAX_SUPPLY` enforced on spoke `_credit`.
- **Test suite:** 198 Foundry tests passing (excluding `DeployCreate3.t.sol` — missing `script/Create3Factory.sol` breaks compilation of that file only).

---

## Tooling installed (cloud)

```bash
./scripts/install-audit-skills.sh
```

Installs:

| Skill | Source | Use |
|---|---|---|
| `solidity-auditor` | pashov/skills | Parallel Solidity security review |
| `fizz` | pashov/skills | Fuzz/invariant generation |
| `x-ray` | pashov/skills | Threat modeling |
| `trailmark` | trailofbits/skills | Static call-graph / attack-surface analysis |
| `variant-analysis` | trailofbits/skills | Systematic variant hunting after a root cause |

---

## Recommendations

1. Block `LiFiCustodian` registration until implemented, or complete the swap module.
2. Emit events / surface failed custodian liquidations; consider keeper monitoring.
3. Document CoW signing policy (max fee, no partial fills) for custodian NFT operators.
4. Reorder `Treasury.distribute` so book credits occur only after confirming payout solvency, or split book credit from payout paths.
5. Add `script/Create3Factory.sol` or remove/fix `test/DeployCreate3.t.sol` so `forge test` compiles cleanly.

---

## Multi-agent addendum (2026-08-26)

Parallel reviews: [access control](bc-5a046869-eb1f-52d6-8ea6-cbccced292df), [math/precision](bc-878b916d-e301-56bd-86ea-ee0884326631), [economic security](bc-038fbc83-7133-5ae3-bd42-713e83c11f2f), [execution traces](bc-1bfacaf1-7590-5354-b1b3-39bd1fb6458b).

### New high-signal items (beyond §Findings above)

| Theme | Agents | Note |
|-------|--------|------|
| **Dividend `accShare` dust trap** | Math | Small harvests can bump `totalClaimable` while every locker floors to 0 claimable — blocks delist, strands wei |
| **`setGrai` + fail-open `liquidation()`** | Access | Miswired `grai` lets permissionless sweeps run outside GRAI `REDEMPTION` |
| **Initialize placeholders** | Access | GRAI/Grinders default `grinders`/`treasury`/`grai` to admin/EOA until rewired — deposit/sweep footgun |
| **Uncapped `distribute` on custodians** | Economic | Principal can be labeled yield; `totalValue` unchanged → double liability |
| **Poach unit mismatch** | Economic | `poachOf` is USD book; `poach` charges GRAI 1:1 — mispriced when supply ≠ book |
| **Sticky treasury books after redeem** | Economic | Books survive full exit; poach asks can exceed live exposure |
| **Heartbeat griefing** | Economic | Owner ops refresh `grinding()` and can block quorum liquidation |
| **First-depositor inflation** | Math | Tiny seed + large second deposit mints almost all supply at stale `totalValue` |
| **Quorum/bribe math split** | Math | `hasQuorum` strict product vs floored `voteBps` in `previewBribe` |
| **Liquidate drain-before-forward** | Execution | Custodian drained in `try`, forward to GRAI can fail silently — assets stuck on Grinders |
| **Claim CEI ordering** | Execution | `treasury.distribute` (external affiliate calls) runs before locker/tip payout |

### Confirmed cross-agent themes (already in report or leads)

- LiFi stub, silent `liquidate` try/catch, CoW field gaps, treasury book-credit-before-payout
- Orphan GRAI dilution, swap during liquidation, oracle spot/`getPriceUnsafe` trust
- Admin trust: uncapped deallocate, split UUPS owners, NFT owner vs protocol admin roles
- Reentrancy: GRAI paths guarded (`bribe` escrow-before-pay, `redeem` snapshot); Grinders/Treasury unguarded — hookable assets can interleave `liquidate` during claim/redeem
- ETH/WETH fallbacks on redeem/Treasury can route funds to `beneficiar` or soft-fail unpaid shares

### Overall conclusion

No unprivileged Critical/High theft path was confirmed across agents. The strongest **new** actionable items are the dividend dust trap (math), deployment/wiring fail-open paths (access), and economic mismatches in poach/treasury/yield accounting. Most other hits are documented trust boundaries, keeper dependencies, or intentional governance economics.

---

> ⚠️ This review was performed by an AI assistant using Pashov + Trail of Bits skill workflows. AI analysis cannot verify complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
