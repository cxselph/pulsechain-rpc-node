#!/usr/bin/env bash
# logs.sh — follow the validator's log
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
run_docker logs -f --tail=100 "${VALIDATOR_CONTAINER}"
