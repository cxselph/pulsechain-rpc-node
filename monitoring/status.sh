#!/usr/bin/env bash
# status.sh — monitoring containers, helper timer, scrape targets
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "=== Containers ==="
mon_compose ps || true
echo ""
echo "=== Node status helper ==="
systemctl --no-pager --lines=0 status pulse-node-metrics.timer 2>/dev/null | sed -n '1,3p' || echo "timer not installed"
# The helper's directory sits behind systemd's root-only /var/lib/private, so
# read the values the way Prometheus does: through node_exporter.
if helper_metrics="$(curl -fsS -m 5 http://127.0.0.1:9100/metrics 2>/dev/null)"; then
  grep -E '^pulse_(el|cl)_(up|syncing|peers|current_block|highest_block|el_offline) ' <<<"${helper_metrics}" \
    || echo "node_exporter has no pulse_* metrics yet (helper output missing?)"
else
  echo "node_exporter not answering on 127.0.0.1:9100"
fi
echo ""
echo "=== Prometheus targets ==="
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' || echo "Prometheus not answering on 127.0.0.1:9090"
import json, urllib.request
with urllib.request.urlopen("http://127.0.0.1:9090/api/v1/targets", timeout=5) as r:
    for t in json.load(r)["data"]["activeTargets"]:
        print(f'  {t["labels"]["job"]:<12} {t["health"]:<8} {t.get("lastError","")}')
PY
fi
echo ""
echo "=== Grafana ==="
if curl -fsS -m 3 "${GRAFANA_HEALTH_URL}" >/dev/null 2>&1; then
  echo "  healthy. Open it through an SSH tunnel:"
  echo "    ssh -L 3000:127.0.0.1:3000 $(id -un)@$(hostname -f 2>/dev/null || hostname)"
  echo "    then http://localhost:3000/grafana/"
else
  echo "  not answering on 127.0.0.1:3000"
fi
