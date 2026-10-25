#!/usr/bin/env bash
# disable.sh — switch the validator off: stop it, remove its container and the ENABLED
# marker. Keys, wallet and slashing-protection DB stay. This is not an exit:
# the validator stays active on chain and loses a little balance while offline.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

val_stop
if val_exists; then
  run_docker rm "${VALIDATOR_CONTAINER}" >/dev/null
fi
rm -f "${VAL_ENABLED}"
echo "Validator switched off. Switch it back on with: sudo ./validator/enable.sh"
