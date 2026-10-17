#!/usr/bin/env bash
# stop.sh — stop the Tailscale DNS answer (Tailscale itself keeps running)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ts_compose down
