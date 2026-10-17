#!/usr/bin/env bash
# start.sh — start the monitoring stack
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mon_compose up -d --remove-orphans
