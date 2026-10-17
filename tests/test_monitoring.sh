#!/usr/bin/env bash
# Checks for the optional monitoring stack (monitoring/): pins, localhost-only
# binds, provisioning files, and the node status helper against fake endpoints.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MON="${ROOT}/monitoring"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }
in_ci() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; }

compose="${MON}/docker-compose.yml"

# --- Images: tag + digest, and the digest matches the registry ---------------
images=()
while IFS= read -r ref; do images+=("${ref}"); done < <(grep -E '^\s+image:' "${compose}" | awk '{print $2}')
if [[ "${#images[@]}" -eq 3 ]]; then pass "3 monitoring images"; else fail "expected 3 images, found ${#images[@]}"; fi
for ref in "${images[@]}"; do
  if [[ "${ref}" =~ ^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]; then
    pass "pinned by tag + digest: ${ref%%@*}"
  else
    fail "not pinned by tag + digest: ${ref}"
    continue
  fi
  repo="${ref%%:*}"; rest="${ref#*:}"; tag="${rest%%@*}"; want="${ref##*@}"
  if got="$(python3 - "${repo}" "${tag}" <<'PY' 2>/dev/null
import json, sys, urllib.request
repo, tag = sys.argv[1], sys.argv[2]
tok = json.load(urllib.request.urlopen(
    f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull", timeout=20))["token"]
req = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}", method="HEAD", headers={
    "Authorization": f"Bearer {tok}",
    "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"})
print(urllib.request.urlopen(req, timeout=20).headers["Docker-Content-Digest"])
PY
)"; then
    if [[ "${got}" == "${want}" ]]; then pass "registry digest matches ${repo}:${tag}"; else fail "${repo}:${tag} registry digest ${got} != pin ${want}"; fi
  elif in_ci; then
    fail "could not read registry digest for ${repo}:${tag}"
  else
    echo "SKIP: registry digest for ${repo}:${tag} (offline?)"
  fi
done

# --- Everything binds 127.0.0.1 ---------------------------------------------
if grep -q -- '--web.listen-address=127.0.0.1:9090' "${compose}" \
   && grep -q -- '--web.listen-address=127.0.0.1:9100' "${compose}" \
   && grep -qE 'GF_SERVER_HTTP_ADDR: 127\.0\.0\.1$' "${compose}"; then
  pass "Prometheus, node_exporter and Grafana bind 127.0.0.1"
else
  fail "a monitoring service is not bound to 127.0.0.1"
fi
if grep -qE '0\.0\.0\.0|ports:' "${compose}"; then fail "monitoring compose must not publish ports or bind 0.0.0.0"; else pass "no published ports / 0.0.0.0 in monitoring compose"; fi
if grep -E 'targets:' "${MON}/prometheus/prometheus.yml" | grep -vq '127\.0\.0\.1'; then
  fail "every Prometheus target should be 127.0.0.1"
else
  pass "Prometheus scrapes only 127.0.0.1"
fi
if grep -qx 'GF_AUTH_ANONYMOUS_ENABLED: "false"' <(sed 's/^ *//' "${compose}") \
   && grep -qx 'GF_USERS_ALLOW_SIGN_UP: "false"' <(sed 's/^ *//' "${compose}"); then
  pass "Grafana: no anonymous access, no sign-up"
else
  fail "Grafana must disable anonymous access and sign-up"
fi

# --- Provisioning files -------------------------------------------------------
rules="${MON}/grafana/provisioning/alerting/rules.yml"
n_rules="$(grep -c '^      - uid: pulse-' "${rules}")"
if [[ "${n_rules}" -ge 10 && "$(grep -c 'noDataState: OK' "${rules}")" -eq "${n_rules}" && "$(grep -c 'condition: C' "${rules}")" -eq "${n_rules}" ]]; then
  pass "${n_rules} alert rules, each with condition C and noDataState OK"
else
  fail "alert rules malformed (rules=${n_rules})"
fi
if grep -q '\$' "${rules}"; then fail "rules.yml must not contain \$ (Grafana would treat it as an env variable)"; else pass "rules.yml has no \$ (no accidental env interpolation)"; fi
# shellcheck disable=SC2016  # literal ${ALERT_EMAIL_TO}: Grafana expands it, not bash
if grep -qF 'addresses: ${ALERT_EMAIL_TO}' "${MON}/grafana/provisioning/alerting/contact-points.yml"; then
  pass "alert recipient comes from ALERT_EMAIL_TO"
else
  fail "contact point should use \${ALERT_EMAIL_TO}"
fi
for f in "${MON}"/grafana/dashboards/*.json; do
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["title"]' "${f}" 2>/dev/null; then
    pass "dashboard JSON valid: $(basename "${f}")"
  else
    fail "invalid dashboard JSON: ${f}"
  fi
done
for key in GF_SMTP_HOST GF_SMTP_USER GF_SMTP_PASSWORD GF_SMTP_FROM_ADDRESS ALERT_EMAIL_TO; do
  grep -qE "^${key}=" "${MON}/.env.example" || fail ".env.example is missing ${key}"
done
pass ".env.example lists the SMTP and recipient settings"
if git -C "${ROOT}" check-ignore -q monitoring/.env; then pass "monitoring/.env is gitignored"; else fail "monitoring/.env must be gitignored (it holds the SMTP password)"; fi

# --- Prometheus config is valid (promtool from the pinned image) --------------
prom_image="$(grep -E '^\s+image: prom/prometheus' "${compose}" | awk '{print $2}')"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker run --rm --entrypoint promtool -v "${MON}/prometheus:/cfg:ro" "${prom_image}" check config /cfg/prometheus.yml >/dev/null 2>&1; then
    pass "promtool check config"
  else
    fail "promtool check config failed"
  fi
elif in_ci; then
  fail "docker needed for promtool check"
else
  echo "SKIP: promtool (no Docker)"
fi

# --- Node status helper against fake go-pulse / Prysm endpoints ---------------
if python3 - "${MON}/exporter/pulse-node-metrics.py" <<'PY'
import http.server, json, os, subprocess, sys, tempfile, threading

helper = sys.argv[1]
state = {}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self._send({"jsonrpc": "2.0", "id": 1, "result": state["rpc"][req["method"]]})
    def do_GET(self):
        self._send({"data": state["beacon"][self.path]})

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{srv.server_port}"

def run(rpc_url, beacon_url):
    out = tempfile.mkdtemp()
    env = dict(os.environ, STATE_DIRECTORY=out, PULSE_RPC_URL=rpc_url, PULSE_BEACON_URL=beacon_url)
    subprocess.run([sys.executable, helper], env=env, check=True, capture_output=True)
    m = {}
    for line in open(os.path.join(out, "pulse_node.prom")):
        if line and not line.startswith("#"):
            k, v = line.split(); m[k] = int(v)
    return m

def expect(m, **want):
    for k, v in want.items():
        assert m.get(k) == v, f"{k}={m.get(k)} want {v}"

state["rpc"] = {"eth_syncing": {"currentBlock": "0x1c9c3c", "highestBlock": "0x1a88a40", "syncedAccounts": "0x10",
                                "syncedStorage": "0x20", "syncedBytecodes": "0x0", "healedTrienodes": "0x0", "healedBytecodes": "0x0"},
                "net_peerCount": "0x2c"}
state["beacon"] = {"/eth/v1/node/syncing": {"head_slot": "2780000", "sync_distance": "0", "is_syncing": False,
                                            "is_optimistic": True, "el_offline": True},
                   "/eth/v1/node/peer_count": {"connected": "14", "disconnected": "10"}}
m = run(url, url)
expect(m, pulse_el_up=1, pulse_el_syncing=1, pulse_el_current_block=1875004, pulse_el_highest_block=27822656,
       pulse_el_peers=44, pulse_el_sync_progress=1875004 + 16 + 32, pulse_el_snap_synced_accounts=16,
       pulse_cl_up=1, pulse_cl_syncing=0, pulse_cl_el_offline=1, pulse_cl_optimistic=1,
       pulse_cl_head_slot=2780000, pulse_cl_sync_distance=0, pulse_cl_peers=14)
print("PASS: helper while syncing")

state["rpc"] = {"eth_syncing": False, "eth_blockNumber": "0x1a88b00", "net_peerCount": "0x32"}
m = run(url, url)
expect(m, pulse_el_syncing=0, pulse_el_current_block=27822848, pulse_el_highest_block=27822848, pulse_el_sync_progress=27822848)
print("PASS: helper when synced")

m = run("http://127.0.0.1:9", "http://127.0.0.1:9")
expect(m, pulse_el_up=0, pulse_cl_up=0)
assert "pulse_metrics_last_run_timestamp_seconds" in m and "pulse_el_peers" not in m
print("PASS: helper when both clients are down")
PY
then
  pass "node status helper"
else
  fail "node status helper"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "One or more monitoring checks failed." >&2
  exit 1
fi
echo "All monitoring checks passed."
exit 0
