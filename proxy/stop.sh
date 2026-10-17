#!/usr/bin/env bash
# stop.sh — stop the HTTPS front end (the node keeps running)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
proxy_compose down
