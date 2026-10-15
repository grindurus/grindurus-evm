# Deploy scripts

Foundry scripts for **GRAI** (+ Treasury + Grinders), **CoWCustodian**, and **GRS** on EVM.
Run from `grindurus-evm/`.

| Script | Role |
| ------ | ---- |
| [`DeployGRAI.s.sol`](DeployGRAI.s.sol) | CreateX CREATE3: GRAI + Treasury + Grinders, Chainlink feeds, bribeable |
| [`DeployGRS.s.sol`](DeployGRS.s.sol) | LayerZero OFT GRS (plain `new`) + Solana peer / TGE sales helpers |

## Prerequisites

```bash
forge build
```

| Env | Required | Notes |
| --- | -------- | ----- |
| `PRIVATE_KEY` | yes | Deployer; GRAI `owner` + Grinders `toreador` |
| `ETHERSCAN_API_KEY` / `ARBISCAN_API_KEY` / `BASESCAN_API_KEY` | for `--verify` | See `[etherscan]` in `foundry.toml` |
| `ETH_RPC_URL` / `ARBITRUM_RPC_URL` / `BASE_RPC_URL` / `ROBINHOOD_RPC_URL` | for those aliases | Sepolia has a public default in `foundry.toml` |

Aliases: `--rpc-url sepolia|ethereum|arbitrum|base|robinhood` (from `foundry.toml`).

Shared flags:

- `OWNER_MULTISIG=` — start Ownable2Step handoff (multisig must still `acceptOwnership`)
- `DRY_RUN=1` — GRS helpers: log only, no broadcast
- `CHAIN=` — GRS only; must match `--rpc-url` chain id

Network for `DeployGRAI` is taken from `block.chainid` (`--rpc-url`), not `CHAIN=`.

## Order

1. **GRAI** — impl+proxy for GRAI / Treasury / Grinders, feeds, bribeable
2. **CoWCustodian** / **SwapCustodian** — via `deployCoWCustodian()` / `deploySwapCustodian()` (needs `GRINDERS=`)
3. **GRS** (optional) — LayerZero OFT; then `setSolanaPeer` / list sales

```
DeployGRAI  →  deployCoWCustodian / deploySwapCustodian  →  (optional) DeployGRS + setSolanaPeer
```

If CreateX is on-chain, addresses are **CREATE3** with a permissioned salt
(`deployer ‖ 0x00 ‖ id`): only `PRIVATE_KEY` can occupy the salt; proxy `initialize` is in
ERC1967 creation bytecode (atomic). If CreateX is missing, falls back to plain `new` CREATE
(no vanity). Canonical CreateX: `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` (`CREATEX=`).

Vanity GRAI proxy (e.g. `0x999999…`): mine the free `uint88` id (~16⁷ tries for 6 hex chars), then deploy:

```bash
# fast offline miner (permissioned salt: deployer ‖ 0x00 ‖ id)
python3 -m venv .venv && . .venv/bin/activate
pip install eth_hash pycryptodome eth_account
PRIVATE_KEY=0x... python script/mine_create3.py --prefix 999999
# → GRAI_PROXY_SALT_ID=<id>
PRIVATE_KEY=0x... python script/mine_create3.py --prefix 777777 \
  --env-name TREASURY_PROXY_SALT_ID
PRIVATE_KEY=0x... python script/mine_create3.py --prefix 888888 \
  --env-name GRINDERS_PROXY_SALT_ID

PRIVATE_KEY=0x... GRAI_PROXY_SALT_ID=<id> TREASURY_PROXY_SALT_ID=<id> \
  GRINDERS_PROXY_SALT_ID=<id> \
  forge script script/DeployGRAI.s.sol:DeployGRAI --rpc-url arbitrum --broadcast --verify
```

---

## 1. GRAI (+ Treasury + Grinders)

Deploys each stack (`Impl` + `ERC1967Proxy(...initialize...)`) via CreateX CREATE3 when present,
else `new`; wires Treasury and Grinders, sets Chainlink feeds, marks bribeable assets.

```bash
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

Optional: `WETH=`, `MAX_STALENESS=`, `OWNER_MULTISIG=`.

### Post-deploy: bribeable

Re-apply bribeable flags for the current network’s asset table (owner = `PRIVATE_KEY`):

```bash
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "setBribeable(address)" 0xGRAI --rpc-url arbitrum --broadcast
```

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

Requires Grinders already deployed. Deploys/registers CoW impl (`impl=0` → new) and optionally a proxy.

```bash
# New impl + Grinders.set, no proxy:
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "deployCoWCustodian(address,address,bool)" 0xGrinders 0x0000000000000000000000000000000000000000 false \
  --rpc-url arbitrum --broadcast --verify

# Existing impl + proxy:
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "deployCoWCustodian(address,address,bool)" 0xGrinders 0xImpl true \
  --rpc-url arbitrum --broadcast --verify
```

---

## 2b. SwapCustodian / LiFiCustodian

Same pattern as CoW (`impl=0` → new, always `Grinders.set`, optional proxy).

```bash
PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "deploySwapCustodian(address,address,bool)" 0xGrinders 0x0000000000000000000000000000000000000000 false \
  --rpc-url arbitrum --broadcast --verify

PRIVATE_KEY=0x... forge script script/DeployGRAI.s.sol:DeployGRAI \
  --sig "deployLiFiCustodian(address,address,bool)" 0xGrinders 0x0000000000000000000000000000000000000000 true \
  --rpc-url arbitrum --broadcast --verify
```

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

If you set `OWNER_MULTISIG` during deploy, the multisig must accept on GRAI (and GRS if deployed):

```solidity
grai.acceptOwnership();
grs.acceptOwnership(); // also syncs LZ endpoint delegate on GRS
```

Treasury and Grinders have no local Ownable2Step — admin is `GRAI.owner()` (Grinders also has a separate `toreador` ops role set at deploy to the deployer EOA).

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
