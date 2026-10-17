#!/usr/bin/env bash
# install.sh — reach https://<host> away from home over Tailscale (same address, same certificate)
#
#   1. Installs Tailscale from its signed repo (key fingerprint checked), pinned version.
#   2. Logs this node in: `tailscale up` prints a link to open (first time only).
#      --accept-dns=false     this node keeps its own DNS
#      --netfilter-mode=off   UFW stays in charge of what the tailnet can reach
#   3. Starts a one-name DNS answer (<host> -> this node's Tailscale IP) on the
#      Tailscale IP, and opens 443/80/53 on tailscale0 only.
#   4. Prints the two settings to make in the Tailscale admin console.
#
# Run after ./proxy/install.sh. Safe to re-run.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "${TS_DIR}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then SUDO=""; else sudo -v || die "Could not obtain sudo privileges."; SUDO="sudo"; fi
for cmd in curl python3 systemctl; do command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required."; done

host=""
[[ -f "${REPO_PROXY_ENV:=${TS_DIR}/../proxy/.env}" ]] && host="$(grep -E '^PUBLIC_HOSTNAME=' "${REPO_PROXY_ENV}" | tail -n 1 | cut -d= -f2-)"
[[ -n "${host}" ]] || die "Set up the HTTPS front end first (./proxy/install.sh), so there is a hostname and certificate."
container_running pulse-caddy || warn "The HTTPS front end (pulse-caddy) isn't running; start it with ./proxy/start.sh"

# --- 1. Install Tailscale -------------------------------------------------------
# shellcheck source=/dev/null
. /etc/os-release
if ! command -v tailscale >/dev/null 2>&1; then
  if os_is_debian_family "${ID:-}"; then
    distro="${ID}"; codename="${VERSION_CODENAME:-}"
    if [[ "${ID}" != "debian" && "${ID}" != "ubuntu" ]]; then distro=ubuntu; codename="${UBUNTU_CODENAME:-${codename}}"; fi
    [[ -n "${codename}" ]] || die "Can't tell the ${distro} release codename."
    command -v gpg >/dev/null 2>&1 || $SUDO apt-get install -y gnupg >/dev/null
    key_url="https://pkgs.tailscale.com/stable/${distro}/${codename}.noarmor.gpg"
    key_tmp="$(mktemp)"; trap 'rm -f "${key_tmp}"' EXIT
    curl -fsSL "${key_url}" -o "${key_tmp}" || die "Could not download Tailscale's signing key from ${key_url}"
    fpr="$(gpg --batch --show-keys --with-colons "${key_tmp}" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "${fpr}" == "${TAILSCALE_GPG_FINGERPRINT}" ]] \
      || die "Tailscale's signing key from ${key_url} has fingerprint '${fpr}', expected ${TAILSCALE_GPG_FINGERPRINT}. Not installing."
    $SUDO install -m 0644 "${key_tmp}" /usr/share/keyrings/tailscale-archive-keyring.gpg
    ok "Verified Tailscale signing key (${TAILSCALE_GPG_FINGERPRINT})"
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${distro} ${codename} main" \
      | $SUDO tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    $SUDO apt-get update -qq
    info "Installing tailscale ${TAILSCALE_VERSION} ..."
    $SUDO apt-get install -y "tailscale=${TAILSCALE_VERSION}" >/dev/null \
      || die "apt could not install tailscale=${TAILSCALE_VERSION} (list versions: apt-cache madison tailscale)"
  elif os_is_arch_family "${ID:-}" "${ID_LIKE:-}"; then
    $SUDO pacman -S --noconfirm --needed tailscale >/dev/null || die "pacman could not install tailscale"
  else
    die "Install Tailscale yourself (https://tailscale.com/download/linux), then re-run."
  fi
fi
$SUDO systemctl enable --now tailscaled >/dev/null 2>&1
ok "Tailscale $(tailscale version | head -n 1) installed"

# --- 2. Log in (first time) / apply settings ----------------------------------------
ts_name="${host%%.*}"
if [[ "$(ts_backend_state)" != "Running" ]]; then
  [[ -t 0 ]] || die "Not logged in to Tailscale. Run this script in an interactive terminal."
  echo ""
  echo -e "${BOLD}Log this node in to your tailnet:${NC} open the link that appears below, sign in, approve."
fi
$SUDO tailscale up --hostname="${ts_name}" --accept-dns=false --netfilter-mode=off
[[ "$(ts_backend_state)" == "Running" ]] || die "Tailscale is not connected."
ts_ip="$(tailscale ip -4 | head -n 1)"
[[ "${ts_ip}" =~ ^100\. ]] || die "Unexpected Tailscale IP '${ts_ip}'."
ok "On the tailnet as ${ts_name} (${ts_ip})"

# --- 3. Firewall: only what the tailnet needs ---------------------------------------
if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow in on tailscale0 to any port 443 proto tcp comment 'Pulse HTTPS - Tailscale' >/dev/null
  $SUDO ufw allow in on tailscale0 to any port 80 proto tcp comment 'Pulse HTTP redirect - Tailscale' >/dev/null
  $SUDO ufw allow in on tailscale0 to any port 53 proto udp comment 'Pulse DNS - Tailscale' >/dev/null
  $SUDO ufw allow in on tailscale0 to any port 53 proto tcp comment 'Pulse DNS - Tailscale' >/dev/null
  # WireGuard itself (authenticated): lets peers connect directly instead of via relays.
  $SUDO ufw allow 41641/udp comment 'Tailscale WireGuard' >/dev/null
  ok "UFW: tailnet may reach 443, 80, 53 (and SSH); nothing else"
else
  warn "UFW not found. With --netfilter-mode=off, make sure your firewall allows tailscale0 → 443/80/53."
fi

# --- 4. DNS answer --------------------------------------------------------------------
printf 'TS_IP=%s\nPUBLIC_HOSTNAME=%s\n' "${ts_ip}" "${host}" > "${TS_ENV}"
wait_for_docker || die "Cannot reach the Docker daemon."
ts_compose pull -q
ts_compose up -d --force-recreate --remove-orphans
sleep 2
answer="$(python3 "${TS_DIR}/dnscheck.py" "${ts_ip}" "${host}" A || true)"
refused="$(python3 "${TS_DIR}/dnscheck.py" "${ts_ip}" example.com A || true)"
if [[ "${answer}" == "NOERROR ${ts_ip}" ]]; then ok "DNS: ${host} -> ${ts_ip}"; else die "DNS answer wrong: '${answer}'. Check ./tailscale/logs.sh"; fi
if [[ "${refused}" == REFUSED* ]]; then ok "DNS: other names refused (not a resolver)"; else warn "example.com got '${refused}', expected REFUSED"; fi

body="$(curl -sS -m 10 -k --resolve "${host}:443:${ts_ip}" -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "https://${host}/" || true)"
if [[ "${body}" == *'"result":"0x171"'* ]]; then ok "https://${host} answers on the Tailscale IP"; else warn "https://${host} via ${ts_ip} didn't answer: ${body}"; fi

echo ""
echo -e "${GREEN}${BOLD}Tailscale is set up on this node.${NC} Two settings in https://login.tailscale.com/admin :"
echo ""
echo -e "  1. ${BOLD}Machines${NC} → ${ts_name} → ⋯ → ${BOLD}Disable key expiry${NC}"
echo -e "  2. ${BOLD}DNS${NC} → Nameservers → ${BOLD}Add nameserver → Custom${NC}:"
echo -e "       Nameserver: ${BOLD}${ts_ip}${NC}"
echo -e "       ✓ Restrict to domain (split DNS): ${BOLD}${host}${NC}"
echo ""
echo "  Then on a phone with Tailscale on and Wi-Fi off: https://${host} should load as usual."
echo "  Check anytime: ./tailscale/status.sh"
echo ""
