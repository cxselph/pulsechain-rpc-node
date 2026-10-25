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
# Bring back a validator that ./stop.sh stopped (not one stopped on purpose with
# validator/stop.sh). It passed its checks when it was created.
if [[ -e "${VAL_RESUME_FILE}" ]]; then
  rm -f "${VAL_RESUME_FILE}"
  val_resume || true
fi
echo "Follow logs with: ./logs.sh"
