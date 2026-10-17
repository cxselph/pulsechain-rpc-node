#!/usr/bin/env bash
# Checks for the optional HTTPS front end (proxy/): pin, hardening, routes in
# the Caddyfile, and the certificate validator against good and bad certificates.
# shellcheck disable=SC2015,SC2016  # pass() never fails, so `a && pass || fail` is safe; '$VAR' patterns are literal Caddyfile text
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROXY="${ROOT}/proxy"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }
in_ci() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; }
# shellcheck source=../proxy/lib.sh
source "${PROXY}/lib.sh"

compose="${PROXY}/docker-compose.yml"
caddyfile="${PROXY}/Caddyfile"
image="$(grep -E '^\s+image:' "${compose}" | awk '{print $2}')"

# --- Image pin ------------------------------------------------------------------
if [[ "${image}" =~ ^caddy:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
  pass "Caddy pinned by tag + digest"
  tag="${image#caddy:}"; tag="${tag%%@*}"; want="${image##*@}"
  if got="$(python3 - "${tag}" <<'PY' 2>/dev/null
import json, sys, urllib.request
tok = json.load(urllib.request.urlopen("https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/caddy:pull", timeout=20))["token"]
req = urllib.request.Request(f"https://registry-1.docker.io/v2/library/caddy/manifests/{sys.argv[1]}", method="HEAD", headers={
    "Authorization": f"Bearer {tok}",
    "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"})
print(urllib.request.urlopen(req, timeout=20).headers["Docker-Content-Digest"])
PY
)"; then
    [[ "${got}" == "${want}" ]] && pass "registry digest matches caddy:${tag}" || fail "caddy:${tag} registry digest ${got} != pin ${want}"
  elif in_ci; then fail "could not read registry digest for caddy:${tag}"; else echo "SKIP: registry digest (offline?)"; fi
else
  fail "Caddy image must be pinned by tag + digest: ${image}"
fi

# --- Container hardening + Caddyfile rules ---------------------------------------
grep -q 'read_only: true' "${compose}" && grep -q 'cap_drop: \[ALL\]' "${compose}" && grep -q 'cap_add: \[NET_BIND_SERVICE\]' "${compose}" \
  && grep -q 'no-new-privileges:true' "${compose}" && pass "Caddy: read-only, all capabilities dropped except NET_BIND_SERVICE, no-new-privileges" \
  || fail "Caddy container hardening missing"
grep -q '/etc/pulse-proxy/tls:/etc/caddy/tls:ro' "${compose}" && pass "certificate mounted read-only" || fail "TLS dir must be mounted read-only"
grep -qE '^\s+admin off$' "${caddyfile}" && pass "Caddy admin API off" || fail "Caddyfile must have 'admin off'"
if grep -qi 'strict-transport-security' "${caddyfile}"; then fail "no HSTS with a private CA (it locks out devices that don't trust it)"; else pass "no HSTS header"; fi
grep -qE 'reverse_proxy 127\.0\.0\.1:\{\$HTTP_PORT\}' "${caddyfile}" && grep -qE 'reverse_proxy 127\.0\.0\.1:\{\$WS_PORT\}' "${caddyfile}" \
  && grep -qE 'reverse_proxy 127\.0\.0\.1:3000' "${caddyfile}" && pass "upstreams are 127.0.0.1 only" || fail "Caddy upstreams should all be 127.0.0.1"
awk '/@rpc \{/,/\}/' "${caddyfile}" | grep -q 'method POST OPTIONS' && awk '/@rpc \{/,/\}/' "${caddyfile}" | grep -qE 'path /$' \
  && pass "RPC route limited to POST/OPTIONS on /" || fail "RPC route should match only POST/OPTIONS on /"
grep -q '{{.Host}}' "${PROXY}/site/index.html" && pass "landing page shows the hostname" || fail "landing page should template {{.Host}}"

# --- Certificate validator (cert_problems) ----------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
(
  cd "${tmp}"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj "/CN=Test CA" >/dev/null 2>&1
  for name in rpc.home other.home rpc.home.evil.example; do
    openssl req -newkey rsa:2048 -nodes -keyout "${name}.key" -out "${name}.csr" -subj "/CN=${name}" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "${name}" > ext.cnf
    openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${name}.crt" -days 2 -extfile ext.cnf >/dev/null 2>&1
  done
  printf 'not a key\n' > junk.key
)
out="$(cert_problems "${tmp}/rpc.home.crt" "${tmp}/rpc.home.key" rpc.home)"
[[ -z "${out}" ]] && pass "valid certificate accepted" || fail "valid certificate rejected: ${out}"
out="$(cert_problems "${tmp}/other.home.crt" "${tmp}/other.home.key" rpc.home)"
[[ "${out}" == *"not issued for rpc.home"* ]] && pass "certificate for another name rejected" || fail "wrong-name certificate accepted"
out="$(cert_problems "${tmp}/rpc.home.evil.example.crt" "${tmp}/rpc.home.evil.example.key" rpc.home)"
[[ "${out}" == *"not issued for rpc.home"* ]] && pass "look-alike name (rpc.home.evil.example) rejected" || fail "look-alike name accepted"
out="$(cert_problems "${tmp}/rpc.home.crt" "${tmp}/other.home.key" rpc.home)"
[[ "${out}" == *"does not belong"* ]] && pass "mismatched key rejected" || fail "mismatched key accepted"
out="$(cert_problems "${tmp}/rpc.home.crt" "${tmp}/junk.key" rpc.home)"
[[ "${out}" == *"not a PEM private key"* ]] && pass "garbage key rejected" || fail "garbage key accepted"
if openssl req -x509 -newkey rsa:2048 -nodes -keyout "${tmp}/old.key" -out "${tmp}/old.crt" -subj "/CN=rpc.home" \
     -addext "subjectAltName=DNS:rpc.home" -not_before 20200101000000Z -not_after 20200102000000Z >/dev/null 2>&1; then
  out="$(cert_problems "${tmp}/old.crt" "${tmp}/old.key" rpc.home)"
  [[ "${out}" == *"expired"* ]] && pass "expired certificate rejected" || fail "expired certificate accepted"
else
  echo "SKIP: expired-certificate case (this openssl lacks -not_after)"
fi

# --- Caddyfile parses (caddy validate, pinned image, throwaway cert) --------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker run --rm -e PUBLIC_HOSTNAME=rpc.home -e HTTP_PORT=8545 -e WS_PORT=8546 \
       -v "${caddyfile}:/etc/caddy/Caddyfile:ro" -v "${tmp}/rpc.home.crt:/etc/caddy/tls/cert.pem:ro" \
       -v "${tmp}/rpc.home.key:/etc/caddy/tls/key.pem:ro" --entrypoint caddy "${image}" \
       validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    pass "caddy validate"
  else
    fail "caddy validate failed"
  fi
elif in_ci; then fail "docker needed for caddy validate"; else echo "SKIP: caddy validate (no Docker)"; fi

if [[ "${FAILED}" -ne 0 ]]; then echo "One or more proxy checks failed." >&2; exit 1; fi
echo "All proxy checks passed."
