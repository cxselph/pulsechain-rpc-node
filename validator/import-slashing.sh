#!/usr/bin/env bash
# import-slashing.sh — import a slashing-protection history (EIP-3076 JSON) from
# the machine the validator ran on before. Run it before the first start here.
#   sudo ./validator/import-slashing.sh /path/to/slashing_protection.json
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

file="${1:-}"
[[ -n "${file}" && -s "${file}" ]] || { echo "Usage: sudo $0 <slashing_protection.json>" >&2; exit 1; }
if val_running; then
  echo "Stop the validator first (sudo ./validator/stop.sh)." >&2
  exit 1
fi
file="$(cd "$(dirname "${file}")" && pwd)/$(basename "${file}")"
val_make_dirs
val_run -v "${file}:/import/slashing_protection.json:ro" -- slashing-protection-history import --pulsechain \
  --datadir=/validator-data/db --slashing-protection-json-file=/import/slashing_protection.json
echo "Imported. Start the validator only once the old machine has been stopped for at least 2 epochs."
