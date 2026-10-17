#!/usr/bin/env bash
# Checks for the optional Tailscale access (tailscale/): pins, Tailscale's
# signing key, installer flags, firewall scope, and the one-name DNS answer
# (run in the pinned CoreDNS image and queried with dnscheck.py).
# shellcheck disable=SC2015,SC2016  # pass() never fails; '$VAR' patterns are literal Corefile text
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSD="${ROOT}/tailscale"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }
in_ci() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; }
# shellcheck source=../tailscale/lib.sh
source "${TSD}/lib.sh"

compose="${TSD}/docker-compose.yml"
image="$(grep -E '^\s+image:' "${compose}" | awk '{print $2}')"

# --- Pins -------------------------------------------------------------------------
[[ "${image}" =~ ^coredns/coredns:[0-9.]+@sha256:[0-9a-f]{64}$ ]] && pass "CoreDNS pinned by tag + digest" || fail "CoreDNS must be pinned by tag + digest"
tag="${image#coredns/coredns:}"; tag="${tag%%@*}"; want="${image##*@}"
if got="$(python3 - coredns/coredns "${tag}" <<'PY' 2>/dev/null
import json, sys, time, urllib.request
repo, tag = sys.argv[1], sys.argv[2]
def lookup():
    tok = json.load(urllib.request.urlopen(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull", timeout=20))["token"]
    req = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}", method="HEAD", headers={
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"})
    return urllib.request.urlopen(req, timeout=20).headers["Docker-Content-Digest"]
for attempt in range(4):  # registries sometimes answer 5xx for a moment
    try:
        print(lookup()); break
    except Exception:
        if attempt == 3: raise
        time.sleep(5 * (attempt + 1))
PY
)"; then
  [[ "${got}" == "${want}" ]] && pass "registry digest matches coredns:${tag}" || fail "coredns:${tag} registry digest ${got} != pin ${want}"
elif in_ci; then fail "could not read registry digest for coredns:${tag}"; else echo "SKIP: registry digest (offline?)"; fi
[[ "${TAILSCALE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && pass "Tailscale version pinned (${TAILSCALE_VERSION})" || fail "TAILSCALE_VERSION should be an exact version"
if command -v gpg >/dev/null 2>&1; then
  key="$(mktemp)"
  if curl -fsSL --max-time 20 https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o "${key}" 2>/dev/null; then
    fpr="$(gpg --batch --show-keys --with-colons "${key}" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "${fpr}" == "${TAILSCALE_GPG_FINGERPRINT}" ]] && pass "Tailscale's published key matches TAILSCALE_GPG_FINGERPRINT" \
      || fail "Tailscale's key fingerprint is now '${fpr}' (expected ${TAILSCALE_GPG_FINGERPRINT})"
  elif in_ci; then fail "could not download Tailscale's signing key"; else echo "SKIP: Tailscale key download"; fi
  rm -f "${key}"
elif in_ci; then fail "gpg needed"; else echo "SKIP: gpg not installed"; fi

# --- Installer and firewall --------------------------------------------------------
i="${TSD}/install.sh"
grep -q -- '--netfilter-mode=off' "${i}" && pass "tailscale up --netfilter-mode=off (UFW stays in charge)" || fail "installer must use --netfilter-mode=off"
grep -q -- '--accept-dns=false' "${i}" && pass "tailscale up --accept-dns=false (node keeps its DNS)" || fail "installer must use --accept-dns=false"
grep -q 'TAILSCALE_GPG_FINGERPRINT' "${i}" && grep -q 'Not installing' "${i}" && pass "installer refuses a Tailscale key with another fingerprint" || fail "installer must verify Tailscale's key"
if grep -qi 'funnel' "${i}"; then fail "never Tailscale Funnel"; else pass "no Funnel"; fi
mapfile_rules="$(grep -E 'ufw allow in on tailscale0' "${i}" | grep -oE 'port [0-9]+' | sort -u | tr '\n' ' ')"
[[ "${mapfile_rules}" == "port 443 port 53 port 80 " ]] && pass "tailnet firewall rules: only 443, 80, 53" || fail "unexpected tailscale0 ports: ${mapfile_rules}"
if grep -E 'ufw allow' "${i}" | grep -qE '8545|8546|3000|3500|8090|9090'; then fail "installer must not open RPC/API ports"; else pass "RPC/API ports not opened to the tailnet"; fi

# --- Container hardening + Corefile -------------------------------------------------
grep -q 'read_only: true' "${compose}" && grep -q 'cap_drop: \[ALL\]' "${compose}" && grep -q 'cap_add: \[NET_BIND_SERVICE\]' "${compose}" \
  && pass "CoreDNS: read-only, only NET_BIND_SERVICE" || fail "CoreDNS hardening missing"
grep -qE '^\s+bind \{\$TS_IP\}$' "${TSD}/Corefile" && pass "DNS answer bound to the Tailscale IP only" || fail "Corefile must bind {\$TS_IP}"
if grep -qE '^\s+(forward|proxy|cache)\b' "${TSD}/Corefile"; then fail "Corefile must not forward (it is not a resolver)"; else pass "no forwarding (not a resolver)"; fi

# --- Live DNS behaviour (pinned CoreDNS, dnscheck.py) --------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  name="ts-test-coredns-$$"
  docker run -d --name "${name}" --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
    -e TS_IP=127.0.0.1 -e PUBLIC_HOSTNAME=rpc.home -v "${TSD}/Corefile:/etc/coredns/Corefile:ro" \
    "${image}" -conf /etc/coredns/Corefile >/dev/null
  sleep 2
  q() { docker run --rm --network "container:${name}" -v "${TSD}/dnscheck.py:/d.py:ro" python:3.13-slim python3 /d.py 127.0.0.1 "$@"; }
  [[ "$(q rpc.home A)" == "NOERROR 127.0.0.1" ]] && pass "rpc.home A -> the Tailscale IP" || fail "rpc.home A: $(q rpc.home A)"
  [[ "$(q RPC.Home A)" == "NOERROR 127.0.0.1" ]] && pass "case-insensitive" || fail "RPC.Home A: $(q RPC.Home A)"
  [[ "$(q rpc.home AAAA)" == "NOERROR" ]] && pass "rpc.home AAAA -> no data (name exists)" || fail "rpc.home AAAA: $(q rpc.home AAAA)"
  [[ "$(q example.com A)" == "REFUSED" ]] && pass "other names refused" || fail "example.com: $(q example.com A)"
  [[ "$(q pve.home A)" == "REFUSED" ]] && pass "other .home names refused (UniFi keeps answering those)" || fail "pve.home: $(q pve.home A)"
  docker rm -f "${name}" >/dev/null
elif in_ci; then fail "docker needed for the DNS test"; else echo "SKIP: DNS test (no Docker)"; fi

if [[ "${FAILED}" -ne 0 ]]; then echo "One or more Tailscale checks failed." >&2; exit 1; fi
echo "All Tailscale checks passed."
