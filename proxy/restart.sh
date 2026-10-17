#!/usr/bin/env bash
# restart.sh — recreate the HTTPS front end (applies Caddyfile / .env / certificate changes)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
proxy_compose up -d --force-recreate --remove-orphans
