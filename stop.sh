#!/usr/bin/env bash
# stop.sh — gracefully stop the PulseChain node stack
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=validator/lib.sh
source "${SCRIPT_DIR}/validator/lib.sh"

# The validator goes down first, so it never signs against a beacon that's stopping.
# Its container is kept, and ./start.sh brings it back.
val_stop

echo "Stopping node (grace period up to ~5 minutes for clean shutdown)..."
run_compose down
echo "Node stopped. Chain data is preserved in ${DATA_DIR}"
