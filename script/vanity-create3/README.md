# Vanity CREATE3 salt grinder

Brute-forces numeric `CREATE3_SALT_TAG` values so a Grindurus CREATE3 address
matches a hex prefix/suffix. Derivation matches `../Create3Factory.sol`.

## Run

```bash
cd script/vanity-create3

# self-check vs Solidity
cargo run --release -- --check

# default: GRAI/proxy starts with 9999 and ends with 97a1 (~2^32 tries)
cargo run --release -- --prefix 9999 --suffix 97a1

# prefix only (faster)
cargo run --release -- --prefix 9999 --suffix ''

# other label
cargo run --release -- --prefix dead --suffix beef --label Grinders/proxy
```

On success prints `CREATE3_SALT_TAG=…` and writes `found.txt` (`tag` + `address`).

Use the tag with deploy scripts:

```bash
CREATE3_SALT_TAG=<tag> forge script script/1_DeployGRAI.s.sol:DeployGRAI --sig "predict()"
```
