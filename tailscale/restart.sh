#!/usr/bin/env bash
# restart.sh — recreate the Tailscale DNS answer
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ts_compose up -d --force-recreate --remove-orphans
