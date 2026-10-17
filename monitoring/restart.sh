#!/usr/bin/env bash
# restart.sh — recreate the monitoring containers (applies .env / config changes)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mon_compose up -d --force-recreate --remove-orphans
