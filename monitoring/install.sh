#!/usr/bin/env bash
# install.sh — set up the optional monitoring stack (Prometheus + node_exporter + Grafana)
# Safe to re-run: it updates the helper, keeps Grafana's data and only asks for a
# Grafana password the first time.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${MON_DIR}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  sudo -v || die "Could not obtain sudo privileges."
  SUDO="sudo"
fi
command -v systemctl >/dev/null 2>&1 || die "systemd is required (for the node status helper)."
command -v python3 >/dev/null 2>&1 || die "python3 is required (Debian: sudo apt install python3)."
command -v curl >/dev/null 2>&1 || die "curl is required (Debian: sudo apt install curl)."

# --- 1. Settings file -------------------------------------------------------
if [[ ! -f "${MON_ENV}" ]]; then
  cp "${MON_DIR}/.env.example" "${MON_ENV}"
  chmod 600 "${MON_ENV}"
  ok "Created monitoring/.env from .env.example"
  echo ""
  echo -e "${BOLD}Fill in the alert email settings, then run this script again:${NC}"
  echo "  nano ${MON_ENV}"
  echo "  (GF_SMTP_USER, GF_SMTP_PASSWORD, GF_SMTP_FROM_ADDRESS, ALERT_EMAIL_TO)"
  exit 0
fi
chmod 600 "${MON_ENV}"
mapfile -t missing < <(mon_missing_keys)
if [[ "${#missing[@]}" -gt 0 ]]; then
  die "monitoring/.env still needs: ${missing[*]}  (nano ${MON_ENV})"
fi
ok "monitoring/.env has the alert email settings (mode 600)"

# --- 2. Node status helper (systemd timer, unprivileged) --------------------
info "Installing the node status helper (pulse-node-metrics)..."
$SUDO install -d -m 0755 "${MON_HELPER_DIR}"
$SUDO install -m 0755 "${MON_DIR}/exporter/pulse-node-metrics.py" "${MON_HELPER_DIR}/pulse-node-metrics.py"
sed "s#@DATA_DIR@#${DATA_DIR}#g" "${MON_DIR}/exporter/pulse-node-metrics.service" \
  | $SUDO tee /etc/systemd/system/pulse-node-metrics.service >/dev/null
$SUDO chmod 0644 /etc/systemd/system/pulse-node-metrics.service
$SUDO install -m 0644 "${MON_DIR}/exporter/pulse-node-metrics.timer" /etc/systemd/system/pulse-node-metrics.timer
$SUDO systemctl daemon-reload
# Run once now so the output directory exists before node_exporter mounts it.
$SUDO systemctl start pulse-node-metrics.service || warn "First helper run failed (is the node running?). Check: journalctl -u pulse-node-metrics"
$SUDO systemctl enable --now pulse-node-metrics.timer >/dev/null
# Behind systemd's root-only /var/lib/private, so check with sudo.
if $SUDO test -s "${MON_TEXTFILE_DIR}/pulse_node.prom"; then
  ok "Node status helper running every 30 s ($($SUDO grep -c '^pulse_' "${MON_TEXTFILE_DIR}/pulse_node.prom") metrics)"
else
  warn "Helper output not found yet at ${MON_TEXTFILE_DIR}/pulse_node.prom"
fi

# --- 3. Data directories (on the chain disk; history only, no backup needed) --
info "Preparing ${DATA_DIR}/monitoring ..."
$SUDO install -d -m 0755 "${DATA_DIR}/monitoring"
$SUDO install -d -m 0755 -o 65534 -g 65534 "${DATA_DIR}/monitoring/prometheus"
$SUDO install -d -m 0755 -o 472 -g 0 "${DATA_DIR}/monitoring/grafana"
first_install=0
if ! $SUDO test -e "${DATA_DIR}/monitoring/grafana/grafana.db"; then
  first_install=1
  # Random throwaway admin password for the very first start; replaced below.
  GRAFANA_INITIAL_ADMIN_PASSWORD="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export GRAFANA_INITIAL_ADMIN_PASSWORD
  COMPOSE_ENV_KEYS="${COMPOSE_ENV_KEYS},GRAFANA_INITIAL_ADMIN_PASSWORD"
fi
ok "Data directories ready"

# --- 4. Start the stack ------------------------------------------------------
wait_for_docker || die "Cannot reach the Docker daemon."
info "Pulling monitoring images (pinned by digest)..."
mon_compose pull
info "Starting Prometheus, node_exporter and Grafana..."
mon_compose up -d --remove-orphans
unset GRAFANA_INITIAL_ADMIN_PASSWORD
info "Waiting for Grafana..."
wait_for_grafana || die "Grafana did not become healthy. Check: ./monitoring/logs.sh grafana"
ok "Grafana is up"

# --- 5. Grafana admin password (first install only) -------------------------
if [[ "${first_install}" -eq 1 ]]; then
  echo ""
  if [[ -t 0 ]]; then
    "${MON_DIR}/reset-grafana-password.sh"
  else
    warn "Not an interactive terminal, so no Grafana password was set."
    warn "Run ./monitoring/reset-grafana-password.sh before signing in."
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Monitoring is running.${NC}"
echo ""
echo "  Open Grafana from your computer through an SSH tunnel:"
echo "    ssh -L 3000:127.0.0.1:3000 $(id -un)@$(hostname -f 2>/dev/null || hostname)"
echo "    then http://localhost:3000/grafana/   (user: admin)"
echo ""
echo "  Send a test alert email: Grafana → Alerting → Contact points → email → Test"
echo "  Check everything:        ./monitoring/status.sh"
echo "  Forgot the password:     ./monitoring/reset-grafana-password.sh"
echo ""
