#!/usr/bin/env bash
# logs.sh — follow the control page logs
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
control_compose logs -f --tail=100
