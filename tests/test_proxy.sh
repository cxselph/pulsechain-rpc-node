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
  if got="$(python3 - library/caddy "${tag}" <<'PY' 2>/dev/null
import json, sys, time, urllib.request
repo, tag = sys.argv[1], sys.argv[2]
def lookup():
    tok = json.load(urllib.request.urlopen(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull", timeout=20))["token"]
    req = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}", method="HEAD", headers={
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"})
    return urllib.request.urlopen(req, timeout=20).headers["Docker-Content-Digest"]
for attempt in range(4):  # registries sometimes answer 5xx for a moment
    try:
        print(lookup()); break
    except Exception:
        if attempt == 3: raise
        time.sleep(5 * (attempt + 1))
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
awk '/handle @rpc \{/,/^\t\}/' "${caddyfile}" | grep -qE 'header_up Host \{upstream_hostport\}' \
  && pass "RPC upstream gets an IP Host header (passes go-pulse --http.vhosts)" || fail "RPC route should send header_up Host {upstream_hostport}"
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

# --- Wildcard certificates (cert_check.sh covers_host) ------------------------------
(
  cd "${tmp}"
  openssl req -newkey rsa:2048 -nodes -keyout wild.key -out wild.csr -subj "/CN=*.home.example" >/dev/null 2>&1
  printf 'subjectAltName=DNS:*.home.example\n' > ext.cnf
  openssl x509 -req -in wild.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out wild.crt -days 2 -extfile ext.cnf >/dev/null 2>&1
)
out="$(cert_problems "${tmp}/wild.crt" "${tmp}/wild.key" rpc.home.example)"
[[ -z "${out}" ]] && pass "wildcard *.home.example accepted for rpc.home.example" || fail "wildcard rejected: ${out}"
out="$(cert_problems "${tmp}/wild.crt" "${tmp}/wild.key" a.rpc.home.example)"
[[ "${out}" == *"not issued for"* ]] && pass "wildcard doesn't cover a deeper name" || fail "wildcard accepted for a.rpc.home.example"
out="$(cert_problems "${tmp}/wild.crt" "${tmp}/wild.key" home.example)"
[[ "${out}" == *"not issued for"* ]] && pass "wildcard doesn't cover its own parent" || fail "wildcard accepted for home.example"
out="$(cert_problems "${tmp}/wild.crt" "${tmp}/wild.key" rpc.home.example.evil)"
[[ "${out}" == *"not issued for"* ]] && pass "wildcard doesn't cover a look-alike" || fail "wildcard accepted for rpc.home.example.evil"

# --- Certificate receiver (cert-push-receive.sh), with a stand-in docker ----------
rx="${tmp}/rx"; mkdir -p "${rx}/tls"
printf 'rpc.home.example\n' > "${rx}/push-host"
printf 'PUBLIC_HOSTNAME=rpc.home\n' > "${rx}/proxy.env"
printf '#!/bin/sh\necho "$*" >> "%s/docker-calls"\n' "${rx}" > "${rx}/docker"; chmod +x "${rx}/docker"
receive() {  # receive <file to send>: run the receiver as the forced command would, with test paths
  PULSE_TLS_DIR="${rx}/tls" PULSE_PUSH_HOST_FILE="${rx}/push-host" PULSE_PROXY_ENV_FILE="${rx}/proxy.env" \
    PULSE_DOCKER="${rx}/docker" PULSE_SERVED_CHECK_TRIES=1 bash "${PROXY}/cert-push-receive.sh" < "$1" 2>&1 || true
}
cat "${tmp}/wild.crt" "${tmp}/ca.crt" "${tmp}/wild.key" > "${rx}/bundle.pem"
out="$(receive "${rx}/bundle.pem")"
[[ "${out}" == *"result=installed, waiting"*"--host rpc.home.example"* ]] && pass "receiver installs and waits while Caddy serves another name" || fail "receiver (before switch): ${out}"
[[ "$(openssl x509 -in "${rx}/tls/cert.pem" -noout -subject)" == *"*.home.example"* ]] && pass "receiver wrote the certificate" || fail "receiver didn't write the certificate"
[[ "$(grep -c BEGIN "${rx}/tls/cert.pem")" -eq 2 ]] && pass "receiver kept the whole chain" || fail "receiver dropped the chain"
[[ "$(stat -c %a "${rx}/tls/key.pem" 2>/dev/null || stat -f %Lp "${rx}/tls/key.pem")" == "600" ]] && pass "key is 0600" || fail "key permissions"
[[ ! -e "${rx}/docker-calls" ]] && pass "no Caddy restart before the switch" || fail "Caddy restarted before the switch"
out="$(receive "${rx}/bundle.pem")"
[[ "${out}" == *"result=unchanged"* ]] && pass "same certificate again changes nothing" || fail "resend: ${out}"
printf 'PUBLIC_HOSTNAME=rpc.home.example\n' > "${rx}/proxy.env"
rm -f "${rx}/tls/cert.pem"   # so it's new again
out="$(receive "${rx}/bundle.pem")"
grep -q "restart -t 10 pulse-caddy" "${rx}/docker-calls" 2>/dev/null && pass "Caddy restarted once it serves the name" || fail "no restart after the switch: ${out}"
[[ "${out}" == *"result=refused"*"previous one is back"* || "${out}" == *"no previous one"* || "${out}" == *"result=installed and served"* ]] \
  && pass "receiver checks what Caddy serves after the restart" || fail "after restart: ${out}"
cat "${tmp}/other.home.crt" "${tmp}/other.home.key" > "${rx}/wrong.pem"
out="$(receive "${rx}/wrong.pem")"
[[ "${out}" == *"result=refused"*"not issued for rpc.home.example"* ]] && pass "receiver refuses a certificate for another name" || fail "wrong name: ${out}"
cat "${tmp}/wild.crt" "${tmp}/other.home.key" > "${rx}/mismatch.pem"
out="$(receive "${rx}/mismatch.pem")"
[[ "${out}" == *"result=refused"*"does not belong"* ]] && pass "receiver refuses a key that isn't the certificate's" || fail "mismatch: ${out}"
cat "${tmp}/wild.crt" > "${rx}/nokey.pem"
out="$(receive "${rx}/nokey.pem")"
[[ "${out}" == *"result=refused: no private key"* ]] && pass "receiver refuses a bundle with no key" || fail "no key: ${out}"
head -c 70000 /dev/zero > "${rx}/big.pem"
out="$(receive "${rx}/big.pem")"
[[ "${out}" == *"result=refused: more than"* ]] && pass "receiver refuses more than 64 KiB" || fail "big: ${out}"
grep -q 'RECEIVER="${LIB_DIR}/cert-push-receive"' "${PROXY}/cert-push-setup.sh" \
  && grep -qF "printf 'restrict,from=\"%s\",command=\"sudo -n %s\" %s %s cert-push" "${PROXY}/cert-push-setup.sh" \
  && grep -qF 'NOPASSWD: %s' "${PROXY}/cert-push-setup.sh" && pass "setup forces the receiver, restricted, from one address" || fail "setup's key line"

# --- A hostname change reaches the control page (its Flask TRUSTED_HOSTS) ------------
grep -q 'upsert_dotenv "${ctl_env}" PUBLIC_HOSTNAME "${host}"' "${PROXY}/install.sh" \
  && grep -q 'control/restart.sh' "${PROXY}/install.sh" \
  && pass "install.sh moves the control page to the new hostname" || fail "install.sh should update control/.env PUBLIC_HOSTNAME"

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
