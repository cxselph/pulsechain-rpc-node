#!/usr/bin/env bash
# stop.sh — stop the validator (keys, wallet and slashing-protection DB are kept)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Stopped on purpose: ./start.sh (the node) must not bring it back.
rm -f "${VAL_RESUME_FILE}"
val_stop
echo "Validator stopped. It stays down (also across reboots and node restarts) until ./validator/resume.sh or Start validator on the control page."
