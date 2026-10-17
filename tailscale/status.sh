#!/usr/bin/env bash
# status.sh — Tailscale connection, DNS answer, firewall, and a check over the tailnet
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ts_ip="$(ts_env_value TS_IP)"; host="$(ts_env_value PUBLIC_HOSTNAME)"
echo "=== Tailscale ==="
if command -v tailscale >/dev/null 2>&1; then
  echo "  state:   $(ts_backend_state)   version: $(tailscale version 2>/dev/null | head -n 1)"
  echo "  this node: $(tailscale ip -4 2>/dev/null || echo '?')  ($(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1{print $2}'))"
else
  echo "  not installed"
fi
echo ""
echo "=== DNS answer (${host:-?} on ${ts_ip:-?}) ==="
ts_compose ps || true
if [[ -n "${ts_ip}" && -n "${host}" ]]; then
  echo "  ${host} A  -> $(python3 "${TS_DIR}/dnscheck.py" "${ts_ip}" "${host}" A || true)"
  echo "  example.com -> $(python3 "${TS_DIR}/dnscheck.py" "${ts_ip}" example.com A || true)   (should be REFUSED)"
fi
echo ""
echo "=== Firewall (tailscale0) ==="
if command -v ufw >/dev/null 2>&1; then sudo ufw status | grep -E 'tailscale0|41641' || echo "  no Tailscale rules"; fi
echo ""
if [[ -n "${ts_ip}" && -n "${host}" ]]; then
  echo "=== Over the tailnet ==="
  body="$(curl -sS -m 10 -k --resolve "${host}:443:${ts_ip}" -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "https://${host}/" || true)"
  if [[ "${body}" == *'"result":"0x171"'* ]]; then echo "  ok   wallet RPC https://${host} via ${ts_ip}"; else echo "  FAIL wallet RPC via ${ts_ip}: ${body:-no answer}"; fi
fi
