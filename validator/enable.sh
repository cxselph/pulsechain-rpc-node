#!/usr/bin/env bash
# enable.sh — switch the validator on and start it. Run this only when the node has
# met its readiness bar and the keys are imported (see "Optional: validator client" in README.md).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

if [[ -e "${VAL_ENABLED}" ]]; then
  echo "Already switched on. Start it with: sudo ./validator/start.sh"
  exit 0
fi
[[ -t 0 ]] || { echo "Run this in a terminal: it asks you to confirm." >&2; exit 1; }

fee="$(val_env_value FEE_RECIPIENT)"
cat <<MSG
About to switch on the validator on $(hostname).

  Fee recipient: ${fee:-(not set)}

Only switch it on if all of these are true:
  - These keys are not running anywhere else, and haven't in the last 2 epochs.
  - This wallet and slashing-protection DB are the newest ones (never a restored copy).
  - The fee recipient above is your address (check it on the hardware wallet).
MSG
read -r -p "Type 'switch on' to continue: " reply
[[ "${reply}" == "switch on" ]] || { echo "Nothing changed."; exit 1; }

# Checked before the marker exists, so skip only that line.
problems="$(val_preflight_problems | grep -v 'is switched off' || true)"
if [[ -n "${problems}" ]]; then
  echo "Not switching on:" >&2
  printf '%s\n' "${problems}" | sed 's/^/  - /' >&2
  exit 1
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "${VAL_ENABLED}"
"${VAL_DIR}/start.sh"
