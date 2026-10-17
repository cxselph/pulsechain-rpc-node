#!/usr/bin/env bash
# start.sh — start the Tailscale DNS answer
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ts_compose up -d --remove-orphans
