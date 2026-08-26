# Audit skills (installed via script)

Run from repo root:

```bash
./scripts/install-audit-skills.sh
```

This clones [pashov/skills](https://github.com/pashov/skills) and [trailofbits/skills](https://github.com/trailofbits/skills) and symlinks:

- `solidity-auditor`, `fizz`, `x-ray` (Pashov)
- `trailmark`, `variant-analysis` (Trail of Bits)

Cloned repos are not committed to git; re-run the script after a fresh checkout.
