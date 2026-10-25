#!/usr/bin/env bash
# restart.sh — recreate the validator (applies image / .env changes). Runs the checks again.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

problems="$(val_preflight_problems)"
if [[ -n "${problems}" ]]; then
  echo "Not restarting the validator:" >&2
  printf '%s\n' "${problems}" | sed 's/^/  - /' >&2
  exit 1
fi
val_stop
val_compose up -d --force-recreate --remove-orphans
echo "Validator recreated. Doppelganger protection makes it wait 2-3 epochs before it signs."
