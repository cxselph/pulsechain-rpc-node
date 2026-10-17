#!/usr/bin/env bash
# start.sh — start the control page (rebuilds the image if the code changed)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
control_compose up -d --build --remove-orphans
