#!/usr/bin/env bash
set -euo pipefail

# Install Pashov + Trail of Bits audit skills for Cursor Cloud Agent / local dev.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="${ROOT}/.cursor/skills"

mkdir -p "${SKILLS_DIR}"
cd "${SKILLS_DIR}"

clone_or_pull() {
  local name="$1"
  local url="$2"
  if [[ -d "${name}/.git" ]]; then
    git -C "${name}" pull --ff-only
  else
    git clone --depth 1 "${url}" "${name}"
  fi
}

clone_or_pull pashov-skills https://github.com/pashov/skills.git
clone_or_pull trailofbits-skills https://github.com/trailofbits/skills.git

ln -sfn pashov-skills/solidity-auditor solidity-auditor
ln -sfn pashov-skills/fizz fizz
ln -sfn pashov-skills/x-ray x-ray
ln -sfn trailofbits-skills/plugins/trailmark/skills/trailmark trailmark
ln -sfn trailofbits-skills/plugins/variant-analysis/skills/variant-analysis variant-analysis

echo "Audit skills installed under ${SKILLS_DIR}"
