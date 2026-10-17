#!/usr/bin/env bash
# restart.sh — rebuild and recreate the control page (applies code / .env changes)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
control_compose up -d --build --force-recreate --remove-orphans
