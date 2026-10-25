#!/usr/bin/env bash
# start.sh — start the PulseChain node stack
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=validator/lib.sh
source "${SCRIPT_DIR}/validator/lib.sh"

run_compose up -d --remove-orphans
echo "Node started (${GETH_CONTAINER} + ${BEACON_CONTAINER})."
# Bring back a validator that ./stop.sh stopped. It passed its checks when it was
# created; a switched-off validator has no container (validator/disable.sh).
if [[ -e "${VAL_ENABLED}" ]] && val_exists && ! val_running; then
  run_docker start "${VALIDATOR_CONTAINER}" >/dev/null
  echo "Validator started again (doppelganger wait: 2-3 epochs before it signs)."
fi
echo "Follow logs with: ./logs.sh"
