#!/usr/bin/env bash
# stop.sh — stop the control page (the node keeps running)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
control_compose down
