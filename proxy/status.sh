#!/usr/bin/env bash
# status.sh — HTTPS front end: container, certificate, firewall, and a live check of every route
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

host="$(proxy_hostname)"
[[ -n "${host}" ]] || { echo "PUBLIC_HOSTNAME is not set in proxy/.env. Run ./proxy/install.sh first." >&2; exit 1; }

echo "=== Container ==="
proxy_compose ps || true
echo ""
echo "=== Certificate (${PROXY_TLS_DIR}/cert.pem) ==="
openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -subject -issuer -enddate 2>/dev/null || echo "  not readable"
if ! openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
  echo "  ⚠ expires within 30 days: issue a new one and run ./proxy/install.sh --cert … --key …"
fi
echo ""
echo "=== Firewall (443 / 80) ==="
if command -v ufw >/dev/null 2>&1; then
  sudo ufw status | grep -E 'Pulse HTTPS|Pulse HTTP redirect' || echo "  no Pulse HTTPS rules"
else
  echo "  UFW not installed"
fi
echo ""
echo "=== Routes (via 127.0.0.1) ==="
proxy_checks "${host}" || true
