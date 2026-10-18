#!/usr/bin/env bash
# install.sh — set up the control page (https://<host>/) and its node-control helper
# Run as the user that owns this repo (the helper runs as that user, not root).
# Safe to re-run: keeps the password and history, re-renders the systemd units,
# rebuilds the image.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${CONTROL_DIR}"
REPO_DIR="$(cd "${CONTROL_DIR}/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || die "Run as the user that owns the repo (not root); it asks for sudo where needed."
OWNER="$(id -un)"; OWNER_GROUP="$(id -gn)"
[[ "$(stat -c %U "${REPO_DIR}" 2>/dev/null || stat -f %Su "${REPO_DIR}")" == "${OWNER}" ]] \
  || die "${REPO_DIR} is not owned by ${OWNER}. Run this as the repo owner."
id -nG "${OWNER}" | tr ' ' '\n' | grep -qx docker \
  || die "${OWNER} must be in the docker group (the helper restarts containers). Log out and back in after ./install.sh."
for cmd in python3 curl openssl systemctl git; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required."
done
sudo -v || die "Could not obtain sudo privileges."
SUDO=sudo

# --- 1. Settings --------------------------------------------------------------
if [[ ! -f "${CONTROL_ENV}" ]]; then
  cp "${CONTROL_DIR}/.env.example" "${CONTROL_ENV}"
  ok "Created control/.env"
fi
chmod 600 "${CONTROL_ENV}"
host="$(control_env_value PUBLIC_HOSTNAME)"
if [[ -z "${host}" && -f "${REPO_DIR}/proxy/.env" ]]; then
  host="$(grep -E '^PUBLIC_HOSTNAME=' "${REPO_DIR}/proxy/.env" | tail -n 1 | cut -d= -f2-)"
  [[ -n "${host}" ]] && upsert_dotenv "${CONTROL_ENV}" PUBLIC_HOSTNAME "${host}"
fi
[[ -n "$(control_env_value CONTROL_SECRET_KEY)" ]] || upsert_dotenv "${CONTROL_ENV}" CONTROL_SECRET_KEY "$(openssl rand -hex 32)"
if [[ -n "${host}" ]]; then ok "Hostname: ${host}"; else warn "No PUBLIC_HOSTNAME (set up the HTTPS front end first: ./proxy/install.sh)"; fi

# --- 2. Directories -----------------------------------------------------------
info "Preparing ${CONTROL_VAR} ..."
$SUDO install -d -m 0755 -o "${OWNER}" -g "${OWNER_GROUP}" "${CONTROL_VAR}" "${CONTROL_VAR}/state"
# Requests: written by the container user (${CONTROL_UID}), read and removed by
# ${OWNER} through the group (setgid keeps new files in ${OWNER_GROUP}).
$SUDO install -d -m 2770 -o "${CONTROL_UID}" -g "${OWNER_GROUP}" "${CONTROL_VAR}/requests"
$SUDO install -d -m 0755 "${DATA_DIR}/control"
ok "Directories ready"

# --- 3. node-control helper (systemd, runs as ${OWNER}) ------------------------
info "Installing the node-control helper units (run as ${OWNER})..."
for unit in node-control.path node-control.service node-control-refresh.service node-control-refresh.timer node-control-logs.service; do
  sed -e "s|@USER@|${OWNER}|g" -e "s|@GROUP@|${OWNER_GROUP}|g" -e "s|@REPO@|${REPO_DIR}|g" \
    "${CONTROL_DIR}/systemd/${unit}" | $SUDO tee "/etc/systemd/system/${unit}" >/dev/null
  $SUDO chmod 0644 "/etc/systemd/system/${unit}"
done
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now node-control.path node-control-refresh.timer node-control-logs.service >/dev/null
$SUDO systemctl restart node-control-logs.service  # pick up unit changes on a re-run
info "Collecting status (git fetch, containers, Debian updates)..."
$SUDO systemctl start node-control-refresh.service || warn "First status refresh failed: journalctl -u node-control-refresh"
if [[ -s "${CONTROL_VAR}/state/status.json" ]]; then ok "Helper status written"; else warn "No status.json yet"; fi

# --- 4. Build and start the page -----------------------------------------------
wait_for_docker || die "Cannot reach the Docker daemon."
info "Building the control page image (base image and packages pinned)..."
control_compose build --pull
control_compose up -d --force-recreate --remove-orphans
wait_for_control || die "The control page did not start. Check ./control/logs.sh"
ok "Control page running on 127.0.0.1:8090"

# --- 5. Password (first time) --------------------------------------------------
if [[ -z "$(control_env_value CONTROL_PASSWORD_HASH)" ]]; then
  echo ""
  if [[ -t 0 ]]; then
    "${CONTROL_DIR}/set-password.sh"
  else
    warn "No password set. Run ./control/set-password.sh before signing in."
  fi
fi

# --- 6. Route https://<host>/ to the page --------------------------------------
if [[ -f "${REPO_DIR}/proxy/.env" ]] && container_running pulse-caddy; then
  info "Reloading the HTTPS front end so / goes to the control page..."
  "${REPO_DIR}/proxy/restart.sh" >/dev/null
  sleep 2
  if [[ -n "${host}" ]] && curl -sS -m 10 -k --resolve "${host}:443:127.0.0.1" "https://${host}/login" | grep -q 'Sign in'; then
    ok "https://${host}/ shows the control page"
  else
    warn "Could not confirm https://${host}/ (check ./proxy/status.sh)"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Control page is running.${NC}"
echo ""
[[ -n "${host}" ]] && echo "  Open:  https://${host}/"
echo "  Check:  ./control/status.sh"
echo "  Forgot the password:  ./control/set-password.sh"
echo ""
