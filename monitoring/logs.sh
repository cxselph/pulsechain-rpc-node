#!/usr/bin/env bash
# logs.sh — follow monitoring logs: ./monitoring/logs.sh [grafana|prometheus|node-exporter]
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mon_compose logs -f --tail=100 "$@"
