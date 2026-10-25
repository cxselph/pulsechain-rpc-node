#!/usr/bin/env bash
# status.sh — is the validator switched on, running, and what does its log say?
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ -e "${VAL_ENABLED}" ]]; then echo "Switched on:   yes (since $(cat "${VAL_ENABLED}" 2>/dev/null || echo '?'))"; else echo "Switched on:   no"; fi
fee="$(val_env_value FEE_RECIPIENT)"
echo "Fee recipient: ${fee:-(not set)}"
if val_running; then
  echo "Container:     running"
elif val_exists; then
  echo "Container:     stopped"
else
  echo "Container:     not created"
fi
if val_exists; then
  echo
  echo "Last log lines:"
  run_docker logs --tail=8 "${VALIDATOR_CONTAINER}" 2>&1 | sed 's/^/  /'
fi
