#!/usr/bin/env bash
# cert-push-receive.sh — the one thing the certificate pusher's SSH key can do here (set up by
# cert-push-setup.sh): read a certificate chain and its key on stdin, check them, install them for Caddy and
# restart it. Runs as root through one sudo rule, from a root-owned copy in /usr/local/lib/pulse-proxy.
#
#   ssh certpush@<this VM> < bundle.pem      (the bundle: the certificate chain, then the private key, PEM)
#
# Checks before anything changes: at most 64 KiB, the chain and the key parse, the key belongs to the
# certificate, it covers the hostname cert-push-setup.sh allowed (/etc/pulse-proxy/push-host; a wildcard for its
# parent counts) and it hasn't expired. The same certificate again changes nothing. Caddy is only restarted while
# it already serves that hostname (proxy/.env PUBLIC_HOSTNAME); before the switch, the files wait for
# ./proxy/install.sh --host <host>. After a restart it checks Caddy serves the new certificate, and puts the old
# files back (and restarts again) if not. Prints one "result=..." line last.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cert_check.sh
source "${HERE}/cert_check.sh"

# Settings: fixed paths. (sudo resets the environment, so these can only be changed by a test run directly.)
TLS_DIR="${PULSE_TLS_DIR:-/etc/pulse-proxy/tls}"
PUSH_HOST_FILE="${PULSE_PUSH_HOST_FILE:-/etc/pulse-proxy/push-host}"
PROXY_ENV_FILE="${PULSE_PROXY_ENV_FILE:-$(cat /etc/pulse-proxy/proxy-env-path 2>/dev/null || true)}"
DOCKER="${PULSE_DOCKER:-/usr/bin/docker}"
CADDY_CONTAINER="${PULSE_CADDY_CONTAINER:-pulse-caddy}"
SERVED_CHECK_TRIES="${PULSE_SERVED_CHECK_TRIES:-15}"
MAX_BYTES=65536

say() { echo "$*"; }
fail() { echo "result=refused: $*"; exit 1; }

host="$(tr -d '[:space:]' < "${PUSH_HOST_FILE}" 2>/dev/null || true)"
[[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || fail "no allowed hostname in ${PUSH_HOST_FILE} (run cert-push-setup.sh)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
head -c $((MAX_BYTES + 1)) > "${work}/in"
[[ "$(wc -c < "${work}/in")" -le "${MAX_BYTES}" ]] || fail "more than ${MAX_BYTES} bytes"

# The certificates (in order) and the one private key block.
awk '/-----BEGIN CERTIFICATE-----/{on=1} on{print} /-----END CERTIFICATE-----/{on=0}' "${work}/in" > "${work}/cert.pem"
awk '/-----BEGIN [A-Z ]*PRIVATE KEY-----/{n++; on=(n==1)} on{print} /-----END [A-Z ]*PRIVATE KEY-----/{on=0}' \
  "${work}/in" > "${work}/key.pem"
[[ -s "${work}/cert.pem" ]] || fail "no certificate in what was sent"
[[ -s "${work}/key.pem" ]] || fail "no private key in what was sent"

problems="$(cert_problems "${work}/cert.pem" "${work}/key.pem" "${host}")"
[[ -z "${problems}" ]] || fail "$(tr '\n' ';' <<<"${problems}")"

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }
new_fp="$(fingerprint "${work}/cert.pem")"
if [[ -s "${TLS_DIR}/cert.pem" && "$(fingerprint "${TLS_DIR}/cert.pem")" == "${new_fp}" ]]; then
  say "result=unchanged (${host}, $(openssl x509 -in "${work}/cert.pem" -noout -enddate | cut -d= -f2))"
  exit 0
fi

# Install, keeping the previous pair to put back.
install -d -m 0755 "${TLS_DIR}"
for f in cert.pem key.pem; do
  if [[ -e "${TLS_DIR}/${f}" ]]; then cp -p "${TLS_DIR}/${f}" "${TLS_DIR}/${f}.prev"; fi
done
install -m 0644 "${work}/cert.pem" "${TLS_DIR}/cert.pem"
install -m 0600 "${work}/key.pem" "${TLS_DIR}/key.pem"
say "Installed the certificate for ${host} (expires $(openssl x509 -in "${work}/cert.pem" -noout -enddate | cut -d= -f2))"

serving_host=""
if [[ -n "${PROXY_ENV_FILE}" && -f "${PROXY_ENV_FILE}" ]]; then
  serving_host="$(grep -E '^[[:space:]]*PUBLIC_HOSTNAME[[:space:]]*=' "${PROXY_ENV_FILE}" | tail -n 1 | cut -d= -f2- \
    | tr -d '"[:space:]' || true)"
fi
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
if [[ "$(lower "${serving_host}")" != "$(lower "${host}")" ]]; then
  say "result=installed, waiting: Caddy serves ${serving_host:-no hostname yet}; run ./proxy/install.sh --host ${host} to switch"
  exit 0
fi

served_fp() {
  echo | openssl s_client -connect 127.0.0.1:443 -servername "${host}" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}
restart_and_check() {
  "${DOCKER}" restart -t 10 "${CADDY_CONTAINER}" >/dev/null
  for _ in $(seq 1 "${SERVED_CHECK_TRIES}"); do
    [[ "$(served_fp)" == "$1" ]] && return 0
    sleep 2
  done
  return 1
}

if restart_and_check "${new_fp}"; then
  say "result=installed and served (${host})"
  exit 0
fi
# Caddy didn't come back with it: put the previous pair back.
if [[ -e "${TLS_DIR}/cert.pem.prev" && -e "${TLS_DIR}/key.pem.prev" ]]; then
  mv -f "${TLS_DIR}/cert.pem.prev" "${TLS_DIR}/cert.pem"
  mv -f "${TLS_DIR}/key.pem.prev" "${TLS_DIR}/key.pem"
  restart_and_check "$(fingerprint "${TLS_DIR}/cert.pem")" || true
  fail "Caddy didn't serve the new certificate after a restart; the previous one is back (see ./proxy/logs.sh)"
fi
fail "Caddy didn't serve the new certificate after a restart, and there was no previous one to put back"
