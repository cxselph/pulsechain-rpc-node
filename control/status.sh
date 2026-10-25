#!/usr/bin/env bash
# status.sh — control page container, helper units, last actions
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "=== Container ==="
control_compose ps || true
if curl -fsS -m 3 http://127.0.0.1:8090/healthz >/dev/null 2>&1; then echo "  healthz: ok"; else echo "  healthz: not answering"; fi
echo ""
echo "=== node-control helper ==="
for unit in node-control.path node-control-refresh.timer node-control-watchdog.timer node-control-logs.service; do
  printf '  %-28s %s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done
if [[ -r "${CONTROL_VAR}/state/status.json" ]]; then
  python3 - "${CONTROL_VAR}/state/status.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
r = s.get("repo", {})
print(f"  status written {s.get('generated_at')}; fork {r.get('head_short')} on {r.get('branch')}, "
      f"{r.get('behind', 0)} update(s) available, can apply: {r.get('can_apply')}")
for reason in r.get("blocked_reasons", []):
    print(f"  blocked: {reason}")
PY
else
  echo "  no status.json yet"
fi
echo ""
echo "=== Last actions ==="
if [[ -r "${CONTROL_VAR}/state/history.jsonl" ]]; then
  python3 - "${CONTROL_VAR}/state/history.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]).read().splitlines()[-5:]:
    e = json.loads(line)
    result = "ok  " if e.get("ok") else "FAIL"
    print(f"  {e.get('finished', '')}  {result}  {e.get('label')}: {e.get('summary')}")
PY
else
  echo "  none yet"
fi
