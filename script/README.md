# Deploy scripts

Foundry scripts for **GRAI** (+ Treasury + Grinders), **CoWCustodian**, and **GRS** on EVM.
Run from `grindurus-evm/`.

| Script | Role |
| ------ | ---- |
| [`DeployGRAI.s.sol`](DeployGRAI.s.sol) | CREATE3 GRAI + Treasury + Grinders, Chainlink feeds, bribeable flags |
| [`DeployCoWCustodian.s.sol`](DeployCoWCustodian.s.sol) | CoW custodian impl (+ optional Grinders register / mint / standalone) |
| [`DeployGRS.s.sol`](DeployGRS.s.sol) | LayerZero OFT GRS (plain `new`) + Solana peer / TGE sales helpers |
| [`Create3Factory.sol`](Create3Factory.sol) | Nick’s CREATE2 factory helpers |
| [`vanity-create3/`](vanity-create3/) | Salt grinder for vanity CREATE3 proxies |

## Prerequisites

```bash
forge build
```

| Env | Required | Notes |
| --- | -------- | ----- |
| `PRIVATE_KEY` | yes | Deployer; becomes initial `owner` |
| `ETHERSCAN_API_KEY` / `ARBISCAN_API_KEY` / `BASESCAN_API_KEY` | for `--verify` | See `[etherscan]` in `foundry.toml` |
| `ETH_RPC_URL` / `ARBITRUM_RPC_URL` / `BASE_RPC_URL` / `ROBINHOOD_RPC_URL` | for those aliases | Sepolia has a public default in `foundry.toml` |

Aliases: `--rpc-url sepolia|ethereum|arbitrum|base|robinhood` (from `foundry.toml`).

Shared flags:

- `OWNER_MULTISIG=` — start Ownable2Step handoff (multisig must still `acceptOwnership`)
- `CREATE3_SALT_TAG=` — shared salt fallback (default `grindurus`)
- `CREATE3_SALT_TAG_GRAI` / `_TREASURY` / `_GRINDERS` — per-contract vanity overrides
- `DRY_RUN=1` — CoW / GRS: log / predict only, no broadcast
- `CHAIN=` — CoW / GRS only; must match `--rpc-url` chain id

Network for `DeployGRAI` is taken from `block.chainid` (`--rpc-url`), not `CHAIN=`.

## Order

1. **GRAI** — CREATE3 GRAI + Treasury + Grinders, feeds, bribeable
2. **CoWCustodian** — impl + optional `Grinders.set` / `mint`
3. **GRS** (optional) — LayerZero OFT; then `setSolanaPeer` / list sales

```
DeployGRAI  →  DeployCoWCustodian  →  (optional) DeployGRS + setSolanaPeer
```

CREATE3 addresses depend **only** on salt tags (+ Nick’s factory on-chain).
GRS / custodian impl addresses are non-deterministic.

---

## 1. GRAI (+ Treasury + Grinders)

One script deploys and wires all three CREATE3 stacks, sets Chainlink feeds from the
per-chain asset table, and marks bribeable assets via `setConfig(BRIBEABLE)`.

```bash
# Predict addresses
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "predict()" --rpc-url arbitrum

# Simulate (no broadcast)
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --rpc-url arbitrum

# Deploy
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --rpc-url arbitrum --broadcast --verify

# Robinhood (set ROBINHOOD_RPC_URL in env / foundry.toml)
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --rpc-url robinhood --broadcast
```

Optional: `WETH=`, `MAX_STALENESS=`, `OWNER_MULTISIG=`, salt tags (see below).

### Post-deploy: bribeable

Re-apply bribeable flags for the current network’s asset table (owner = `PRIVATE_KEY`):

```bash
PRIVATE_KEY=0x... GRAI=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "setBribeable()" --rpc-url arbitrum --broadcast
```

If `GRAI=` is omitted, the CREATE3-predicted GRAI proxy for the current salt tags is used.

### Network asset defaults

| Chain | Assets / feeds | Bribeable | Default staleness |
| ----- | -------------- | --------- | ----------------- |
| Ethereum | WETH, ETH, USDC | USDC | 1h |
| Arbitrum | WETH, ETH, USDC | USDC | 1h |
| Base | WETH, ETH, USDC | USDC | 1h |
| Robinhood (4663) | WETH, ETH, USDG | USDG | 24h |
| Sepolia | WETH, ETH | — | 1h |

---

## 2. CoWCustodian

Requires Grinders already deployed (from `DeployGRAI`). Deploys the CoW impl.
Proxies are minted later with `Grinders.mint` (or set `MINT=true`).

```bash
PRIVATE_KEY=0x... forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
  --sig "predict()" --rpc-url arbitrum

PRIVATE_KEY=0x... GRINDERS=0x... forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
  --rpc-url arbitrum --broadcast --verify

# Register kind + mint one sleeve
PRIVATE_KEY=0x... GRINDERS=0x... MINT=true REGISTER=true \
  BASE_ASSET=0x... QUOTE_ASSET=0x... CUSTODIAN_OWNER=0x... \
  forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
  --rpc-url arbitrum --broadcast --verify

# Standalone proxy (no Grinders): initialize(admin)
PRIVATE_KEY=0x... STANDALONE=true \
  BASE_ASSET=0x... QUOTE_ASSET=0x... \
  forge script script/DeployCoWCustodian.s.sol:DeployCoWCustodian \
  --rpc-url ethereum --broadcast --verify
```

Optional: `GRINDERS=` (else CREATE3-predicted Grinders proxy — use `CREATE3_SALT_TAG_GRINDERS`
if you overrode the Grinders tag), `REGISTER=true`, `STANDALONE=true`, `DRY_RUN=1`, `CHAIN=`.

---

## 3. GRS (LayerZero OFT)

Non-upgradeable. Sepolia defaults to **home** (`HOME=true`); other chains default to spoke
unless `HOME=` / `HOME_ADDRESS=` is set.

```bash
# Sepolia home
PRIVATE_KEY=0x... forge script script/DeployGRS.s.sol:DeployGRS \
  --rpc-url sepolia --broadcast --verify

# Arbitrum spoke
PRIVATE_KEY=0x... CHAIN=arbitrum HOME=false forge script script/DeployGRS.s.sol:DeployGRS \
  --rpc-url arbitrum --broadcast --verify
```

Optional: `DELEGATE=` (default deployer), `LZ_ENDPOINT=`, `HOME_ADDRESS=`, `HOME_EID=`,
`OWNER_MULTISIG=`, `DRY_RUN=1`.

### Wire Solana peer

`SOLANA_PEER` = Solana OFT store pubkey as **32-byte hex** (`0x` + 64 hex chars).
Default eid: Devnet `40168` on testnets, Mainnet `30168` on mainnets (`SOLANA_EID=` to override).

```bash
PRIVATE_KEY=0x... \
GRS=0x... \
SOLANA_PEER=0x... \
forge script script/DeployGRS.s.sol:DeployGRS \
  --sig "setSolanaPeer()" --rpc-url sepolia --broadcast
```

`setPeer` also installs default enforced options (Solana CU + ATA rent). Tune later with
`setEnforcedOptions` if needed.

### List TGE-style sales (home)

```bash
PRIVATE_KEY=0x... GRS=0x... USDC=0x... \
  forge script script/DeployGRS.s.sol:DeployGRS \
  --sig "listSaleUsdc1M()" --rpc-url $RPC --broadcast

PRIVATE_KEY=0x... GRS=0x... \
  forge script script/DeployGRS.s.sol:DeployGRS \
  --sig "listSaleEth400()" --rpc-url $RPC --broadcast

# Publish to Solana spoke (home must already setPeer)
PRIVATE_KEY=0x... GRS=0x... \
  forge script script/DeployGRS.s.sol:DeployGRS \
  --sig "listSaleUsdc1MToSolana()" --rpc-url $RPC --broadcast

PRIVATE_KEY=0x... GRS=0x... \
  forge script script/DeployGRS.s.sol:DeployGRS \
  --sig "listSaleSol9090ToSolana()" --rpc-url $RPC --broadcast
```

Example logs: [`logs/v1_deploy_grs.md`](logs/v1_deploy_grs.md),
[`v2`](logs/v2_deploy_grs.md), [`v3`](logs/v3_deploy_grs.md).

---

## Ownership handoff

If you set `OWNER_MULTISIG` during deploy, the multisig must accept on each contract:

```solidity
grai.acceptOwnership();
grinders.acceptOwnership();
grs.acceptOwnership(); // also syncs LZ endpoint delegate on GRS
```

Treasury is owned via GRAI linkage (`initialize(grai)`), not Ownable2Step from the deploy script.

---

## CREATE3 / vanity

- Factory: [`Create3Factory.sol`](Create3Factory.sol) (Nick’s deployer `0x4e59…956C`)
- Labels: `GRAI/impl|proxy`, `Treasury/impl|proxy`, `Grinders/impl|proxy`
- Salt grinder: [`vanity-create3/README.md`](vanity-create3/README.md)

Per-contract tags keep vanity independent:

```bash
# Grind separate tags
cd script/vanity-create3
cargo run --release -- --prefix 999999 --suffix '' --label GRAI/proxy
cargo run --release -- --prefix 77777777 --suffix '' --label Treasury/proxy
cargo run --release -- --prefix 888888 --suffix '' --label Grinders/proxy

# Put tags in .env, then:
set -a && source .env && set +a
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "predict()" --rpc-url arbitrum
```

Unset component tags fall back to `CREATE3_SALT_TAG`, then `"grindurus"`.

Sanity check: `forge test --match-contract DeployCreate3Test`.

---

## Networks (script defaults)

| Alias / chain | GRAI deploy | GRS home default |
| ------------- | ----------- | ---------------- |
| `ethereum` | WETH / ETH / USDC | home (typical) |
| `arbitrum` | WETH / ETH / USDC | spoke |
| `base` | WETH / ETH / USDC | spoke |
| `robinhood` | WETH / ETH / USDG | — (no GRS table entry required for GRAI) |
| `sepolia` | WETH / ETH | **home** |
| `base-sepolia` / `arbitrum-sepolia` | GRS / CoW only (`CHAIN=`) | spoke |

LayerZero endpoints and eids are baked into `DeployGRS.s.sol`
([LZ deployments](https://docs.layerzero.network/v2/deployments/deployed-contracts)).
