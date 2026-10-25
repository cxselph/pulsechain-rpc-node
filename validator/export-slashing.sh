#!/usr/bin/env bash
# export-slashing.sh — export the slashing-protection history (EIP-3076 JSON).
# Needed before moving the validator: stop it, wait 2 epochs, export, import there.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

if val_running; then
  echo "Stop the validator first (sudo ./validator/stop.sh), so the history can't change after the export." >&2
  exit 1
fi
val_make_dirs
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
val_run -- slashing-protection-history export --pulsechain \
  --datadir=/validator-data/db --slashing-protection-export-dir="/validator-data/exports/${stamp}"
echo "Exported to ${VAL_DATA}/exports/${stamp}/"
ls -l "${VAL_DATA}/exports/${stamp}/"
