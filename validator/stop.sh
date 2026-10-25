#!/usr/bin/env bash
# stop.sh — stop the validator (keys, wallet and slashing-protection DB are kept)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
val_stop
echo "Validator stopped. It stays down (also across reboots) until ./validator/start.sh."
