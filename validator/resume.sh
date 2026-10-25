#!/usr/bin/env bash
# resume.sh — start a switched-on validator again after validator/stop.sh.
# No sudo needed (the control page's Start validator runs this). Switching on
# the first time is sudo ./validator/enable.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
rm -f "${VAL_RESUME_FILE}"
val_resume
