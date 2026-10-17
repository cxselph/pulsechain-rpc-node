#!/usr/bin/env bash
# stop.sh — stop the monitoring stack (the node keeps running; data is kept)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mon_compose down
