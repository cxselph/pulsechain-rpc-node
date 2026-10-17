#!/usr/bin/env bash
# install.sh — set up the HTTPS front end (Caddy) for https://<host>
#
#   ./proxy/install.sh --host rpc.home --cert ~/cert.pem --key ~/key.pem   # first time
#   ./proxy/install.sh --cert new-cert.pem --key new-key.pem              # renew the certificate
#   ./proxy/install.sh                                                     # re-apply (keeps the installed certificate)
#
# The certificate must be issued for exactly <host> by a CA your devices trust
# (for a local-only name, your own private CA).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${PROXY_DIR}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

new_host="" new_cert="" new_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) new_host="${2:-}"; shift 2 ;;
    --cert) new_cert="${2:-}"; shift 2 ;;
    --key)  new_key="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
if [[ -n "${new_cert}" || -n "${new_key}" ]] && [[ -z "${new_cert}" || -z "${new_key}" ]]; then
  die "--cert and --key go together."
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  sudo -v || die "Could not obtain sudo privileges."
  SUDO="sudo"
fi
command -v openssl >/dev/null 2>&1 || die "openssl is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

# --- 1. Hostname --------------------------------------------------------------
[[ -f "${PROXY_ENV}" ]] || { cp "${PROXY_DIR}/.env.example" "${PROXY_ENV}"; ok "Created proxy/.env"; }
if [[ -n "${new_host}" ]]; then
  [[ "${new_host}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "--host '${new_host}' is not a hostname like rpc.home"
  upsert_dotenv "${PROXY_ENV}" PUBLIC_HOSTNAME "${new_host}"
fi
host="$(proxy_hostname)"
[[ -n "${host}" ]] || die "No hostname yet. Run: ./proxy/install.sh --host rpc.home --cert <cert.pem> --key <key.pem>"
ok "Hostname: ${host}"

# --- 2. Certificate -----------------------------------------------------------
if [[ -n "${new_cert}" ]]; then
  [[ -r "${new_cert}" && -r "${new_key}" ]] || die "Can't read ${new_cert} / ${new_key}"
  problems="$(cert_problems "${new_cert}" "${new_key}" "${host}")"
  [[ -z "${problems}" ]] || die "Certificate not usable:\n${problems}"
  $SUDO install -d -m 0755 "${PROXY_TLS_DIR}"
  $SUDO install -m 0644 "${new_cert}" "${PROXY_TLS_DIR}/cert.pem"
  $SUDO install -m 0600 "${new_key}" "${PROXY_TLS_DIR}/key.pem"
  ok "Installed certificate and key in ${PROXY_TLS_DIR} (key readable by root only)"
  warn "Delete your copy of the key now that it's installed:  rm ${new_key}"
elif ! $SUDO test -s "${PROXY_TLS_DIR}/cert.pem" || ! $SUDO test -s "${PROXY_TLS_DIR}/key.pem"; then
  die "No certificate installed yet. Run: ./proxy/install.sh --cert <cert.pem> --key <key.pem>"
else
  tmp_key="$(mktemp)"; trap 'rm -f "${tmp_key}"' EXIT
  $SUDO cat "${PROXY_TLS_DIR}/key.pem" > "${tmp_key}"
  problems="$(cert_problems "${PROXY_TLS_DIR}/cert.pem" "${tmp_key}" "${host}")"
  rm -f "${tmp_key}"
  [[ -z "${problems}" ]] || die "Installed certificate not usable:\n${problems}"
  ok "Using the installed certificate in ${PROXY_TLS_DIR}"
fi
echo "   $(openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -subject) · expires $(openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -enddate | cut -d= -f2)"

# --- 3. Firewall (443 + 80 from LAN_ALLOW_FROM only) ---------------------------
if command -v ufw >/dev/null 2>&1; then
  lan_ranges="$(lan_allow_from_list)" || die "Fix LAN_ALLOW_FROM in .env first."
  for range in ${lan_ranges}; do
    $SUDO ufw allow from "${range}" to any port 443 proto tcp comment 'Pulse HTTPS - LAN' >/dev/null
    $SUDO ufw allow from "${range}" to any port 80 proto tcp comment 'Pulse HTTP redirect - LAN' >/dev/null
  done
  ok "UFW: 443 and 80 allowed from ${LAN_ALLOW_FROM}"
else
  warn "UFW not found. Make sure only your LAN can reach ports 443 and 80."
fi

# --- 4. Start -----------------------------------------------------------------
wait_for_docker || die "Cannot reach the Docker daemon."
info "Pulling Caddy (pinned by digest)..."
proxy_compose pull
info "Starting the HTTPS front end..."
proxy_compose up -d --force-recreate --remove-orphans
sleep 3

# --- 5. Grafana: switch to https://<host>/grafana/ -----------------------------
mon_env="${PROXY_DIR}/../monitoring/.env"
if [[ -f "${mon_env}" ]]; then
  upsert_dotenv "${mon_env}" GRAFANA_ROOT_URL "https://${host}/grafana/"
  upsert_dotenv "${mon_env}" GRAFANA_COOKIE_SECURE "true"
  if container_running pulse-grafana; then
    info "Restarting Grafana for https://${host}/grafana/ ..."
    "${PROXY_DIR}/../monitoring/restart.sh" >/dev/null
    for _ in $(seq 1 30); do curl -fsS -m 3 http://127.0.0.1:3000/grafana/api/health >/dev/null 2>&1 && break; sleep 2; done
  fi
  ok "Grafana now lives at https://${host}/grafana/ (the SSH tunnel is no longer needed)"
fi

# --- 6. Check every route -----------------------------------------------------
echo ""
info "Checking every route through 127.0.0.1 ..."
if proxy_checks "${host}"; then
  ok "All routes answer"
else
  warn "Some checks failed. See ./proxy/logs.sh"
fi

echo ""
echo -e "${GREEN}${BOLD}HTTPS front end is running.${NC}"
echo ""
echo "  Wallets:  RPC URL https://${host}   (chain ID 369, symbol PLS)"
echo "            WebSocket wss://${host}"
echo "  Browser:  https://${host}   ·   Grafana https://${host}/grafana/"
echo ""
echo "  Devices need a DNS record for ${host} pointing at this machine, and must trust"
echo "  the CA that issued the certificate. Check everything: ./proxy/status.sh"
echo ""
