#!/usr/bin/env bash
# logs.sh — follow the Tailscale DNS answer logs
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ts_compose logs -f --tail=100
