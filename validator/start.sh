#!/usr/bin/env bash
# start.sh — start the validator, but only after the setup checks pass
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

if val_running; then
  echo "The validator is already running."
  exit 0
fi
problems="$(val_preflight_problems)"
if [[ -n "${problems}" ]]; then
  echo "Not starting the validator:" >&2
  printf '%s\n' "${problems}" | sed 's/^/  - /' >&2
  exit 1
fi
if ! our_stack_running; then
  echo "Note: the node isn't running. The validator waits for the beacon until it is."
fi
val_compose up -d --remove-orphans
echo "Validator started. Doppelganger protection makes it wait 2-3 epochs (about 10-16 minutes) before it signs."
echo "Follow it with: sudo ./validator/logs.sh"
