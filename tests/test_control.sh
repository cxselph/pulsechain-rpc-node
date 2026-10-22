#!/usr/bin/env bash
# Checks for the optional control page (control/): pins and hash-locked
# packages, container hardening, the action allow-list, and both Python test
# suites (node-control helper; web app inside the built image).
# shellcheck disable=SC2015  # pass() never fails, so `a && pass || fail` is safe
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="${ROOT}/control"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }
in_ci() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; }

# --- Supply chain -----------------------------------------------------------------
grep -qE '^FROM python:3\.[0-9]+-slim@sha256:[0-9a-f]{64}$' "${CTL}/Dockerfile" && pass "base image pinned by digest" || fail "Dockerfile FROM must be pinned by digest"
grep -q -- '--require-hashes' "${CTL}/Dockerfile" && pass "pip installs with --require-hashes" || fail "Dockerfile must use pip --require-hashes"
pkgs="$(grep -cE '^[a-z0-9_.-]+==' "${CTL}/requirements.txt")"
hashed="$(awk '/^[a-z0-9_.-]+==/{p=1} p&&/--hash=sha256:/{h[p]=1} /^[a-z0-9_.-]+==/{n++; p=n} END{print length(h)}' "${CTL}/requirements.txt")"
[[ "${pkgs}" -gt 0 && "${pkgs}" -eq "${hashed}" ]] && pass "requirements.txt: all ${pkgs} packages pinned with hashes" || fail "every package in requirements.txt needs a --hash (${hashed}/${pkgs})"

# --- Container hardening ----------------------------------------------------------
c="${CTL}/docker-compose.yml"
if grep -q 'docker.sock' "${c}"; then fail "the control page must never get the Docker socket"; else pass "no Docker socket in the control page"; fi
grep -q 'read_only: true' "${c}" && grep -q 'cap_drop: \[ALL\]' "${c}" && grep -q 'user: "10001:10001"' "${c}" && grep -q 'no-new-privileges:true' "${c}" \
  && pass "control page: read-only, no capabilities, uid 10001, no-new-privileges" || fail "control page container hardening missing"
grep -q '/var/lib/node-control/state:/state:ro' "${c}" && pass "helper state mounted read-only" || fail "state must be read-only for the page"
if grep -qE 'ports:|0\.0\.0\.0' "${c}"; then fail "control page must not publish ports"; else pass "no published ports"; fi
grep -q -- '"--bind", "127.0.0.1:8090"' "${CTL}/Dockerfile" && pass "gunicorn binds 127.0.0.1:8090" || fail "gunicorn must bind 127.0.0.1"
grep -q 'reverse_proxy 127.0.0.1:8090' "${ROOT}/proxy/Caddyfile" && grep -q 'handle_errors 502 503' "${ROOT}/proxy/Caddyfile" \
  && pass "Caddy routes / to the control page, landing page as fallback" || fail "Caddyfile should proxy / to 127.0.0.1:8090 with a fallback"
for u in node-control.service node-control-refresh.service; do
  grep -q '^User=@USER@$' "${CTL}/systemd/${u}" && ! grep -q '^User=root' "${CTL}/systemd/${u}" && pass "${u} runs as the repo owner, not root" || fail "${u} must run as @USER@"
done

# --- The page and the helper agree on the action list ------------------------------
if python3 - "${CTL}" <<'PY'
import ast, sys
def keys(path, name):
    for node in ast.walk(ast.parse(open(path).read())):
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == name for t in node.targets):
            return sorted(k.value for k in node.value.keys)
a = keys(sys.argv[1] + "/app/control.py", "ACTIONS")
h = keys(sys.argv[1] + "/node-control.py", "ACTIONS")
assert a == h and a, (a, h)
print("PASS: page and helper allow the same actions:", ", ".join(a))
PY
then :; else fail "control.py and node-control.py ACTIONS differ"; fi

# --- status.sh renders helper state and history (no services needed) -------------
sv="$(mktemp -d)"; mkdir -p "${sv}/state"
printf '%s\n' '{"generated_at":"2026-10-17T21:40:44+00:00","repo":{"head_short":"e1501f5","branch":"main","behind":0,"can_apply":false,"blocked_reasons":[]}}' > "${sv}/state/status.json"
printf '%s\n' '{"finished":"2026-10-17T21:41:00+00:00","ok":true,"label":"Check for updates","summary":"up to date"}' \
  '{"finished":"2026-10-17T21:42:00+00:00","ok":false,"label":"Apply update","summary":"not applied: local changes"}' > "${sv}/state/history.jsonl"
out="$(NODE_CONTROL_VAR="${sv}" bash "${CTL}/status.sh" 2>&1 || true)"
if grep -q 'fork e1501f5 on main' <<<"${out}" && grep -q 'ok    Check for updates: up to date' <<<"${out}" \
   && grep -q 'FAIL  Apply update: not applied: local changes' <<<"${out}" && ! grep -qE 'Traceback|SyntaxError' <<<"${out}"; then
  pass "status.sh prints helper status and last actions"
else
  printf '%s\n' "${out}" >&2
  fail "status.sh output"
fi
rm -rf "${sv}"

# --- Python tests --------------------------------------------------------------------
if (cd "${CTL}" && python3 -m unittest tests/test_node_control.py tests/test_node_logs.py >/dev/null 2>&1); then
  pass "node-control and node-logs helper tests"
else
  (cd "${CTL}" && python3 -m unittest tests/test_node_control.py tests/test_node_logs.py) || true
  fail "node-control / node-logs helper tests"
fi
grep -q 'node-control-logs.service' "${CTL}/install.sh" && grep -q '^User=@USER@$' "${CTL}/systemd/node-control-logs.service" \
  && grep -q '^Restart=always$' "${CTL}/systemd/node-control-logs.service" \
  && pass "console log helper: installed by install.sh, runs as the repo owner, restarts on failure" || fail "node-control-logs.service setup"
# Grafana links open in their own (reused) tab, so the control page stays put.
if ! grep -rhoE '<a [^>]*href="/grafana[^>]*>' "${CTL}/app/templates" "${ROOT}/proxy/site" | grep -v 'target="grafana" rel="noopener"' | grep -q .; then
  pass "Grafana links open in the grafana tab"
else
  fail "a Grafana link is missing target=\"grafana\" rel=\"noopener\""
fi
grep -q 'textContent = l' "${CTL}/app/static/app.js" && ! grep -q 'innerHTML = l' "${CTL}/app/static/app.js" \
  && pass "console renders log lines as text, never HTML" || fail "console must render log lines with textContent"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker build -q -t pulse-control:test "${CTL}" >/dev/null \
     && docker run --rm --network none -v "${CTL}:/src:ro" -w /src --entrypoint python3 pulse-control:test -m unittest tests/test_app.py >/dev/null 2>&1; then
    pass "image builds with hash-locked packages; web app tests pass inside it"
  else
    docker run --rm --network none -v "${CTL}:/src:ro" -w /src --entrypoint python3 pulse-control:test -m unittest tests/test_app.py || true
    fail "control page image build or web app tests"
  fi
elif in_ci; then
  fail "docker needed to build the control page image"
else
  echo "SKIP: web app tests (no Docker)"
fi

if [[ "${FAILED}" -ne 0 ]]; then echo "One or more control page checks failed." >&2; exit 1; fi
echo "All control page checks passed."
