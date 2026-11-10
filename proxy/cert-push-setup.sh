#!/usr/bin/env bash
# cert-push-setup.sh — let another machine (the NAS that renews the Let's Encrypt certificate) push the HTTPS
# certificate here, so it renews without anyone copying files. Optional.
#
#   sudo ./proxy/cert-push-setup.sh --from <pusher IP> --host <hostname> '<ssh-ed25519 public key>'
#   sudo ./proxy/cert-push-setup.sh --remove
#
# One way only: the pusher gets an SSH key that can do exactly one thing here, run cert-push-receive.sh as root
# (forced command, no shell, no forwarding, only from that IP), which installs a certificate for <hostname> after
# checking it and restarts Caddy. This VM gets no access to the pusher. Re-run it to change the key, IP or hostname.
set -euo pipefail

ACCOUNT=certpush
HOME_DIR=/var/lib/certpush
LIB_DIR=/usr/local/lib/pulse-proxy
RECEIVER="${LIB_DIR}/cert-push-receive"
SUDOERS=/etc/sudoers.d/pulse-cert-push
STATE_DIR=/etc/pulse-proxy
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[[ "${EUID}" -eq 0 ]] || die "Run with sudo."

if [[ "${1:-}" == "--remove" ]]; then
  if id "${ACCOUNT}" >/dev/null 2>&1; then userdel "${ACCOUNT}"; fi
  rm -rf "${HOME_DIR}" "${LIB_DIR}" "${SUDOERS}" "${STATE_DIR}/push-host" "${STATE_DIR}/proxy-env-path"
  ok "Removed the ${ACCOUNT} account, its key and the receiver. The installed certificate stays."
  exit 0
fi

FROM="" HOST="" KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) KEY="$1"; shift ;;
  esac
done
[[ -n "${FROM}" && -n "${HOST}" && -n "${KEY}" ]] || usage
[[ "${FROM}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || die "--from must be an IPv4 address (or CIDR), got: ${FROM}"
[[ "${HOST}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || die "--host must be a hostname like rpc.home.example.com, got: ${HOST}"
read -r ktype kdata _ <<<"${KEY}"
[[ "${ktype}" == "ssh-ed25519" && "${kdata}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "Expected an ssh-ed25519 public key (one line starting with ssh-ed25519)."
for f in cert-push-receive.sh cert_check.sh; do [[ -f "${SRC_DIR}/${f}" ]] || die "Missing ${SRC_DIR}/${f}"; done
command -v visudo >/dev/null 2>&1 || die "sudo/visudo is required."

# Account: no password (but not "locked", which some sshd setups refuse), and nothing it can do except the
# forced command below.
if ! id "${ACCOUNT}" >/dev/null 2>&1; then
  useradd --system --home-dir "${HOME_DIR}" --no-create-home --shell /bin/sh \
    --comment "HTTPS certificate pusher (proxy)" "${ACCOUNT}"
  ok "Created the ${ACCOUNT} account"
fi
usermod -p '*' "${ACCOUNT}"

# The receiver and its check, as root-owned copies: what runs as root never reads files this repo's user can edit.
install -d -m 0755 -o root -g root "${LIB_DIR}"
install -m 0755 -o root -g root "${SRC_DIR}/cert-push-receive.sh" "${RECEIVER}"
install -m 0644 -o root -g root "${SRC_DIR}/cert_check.sh" "${LIB_DIR}/cert_check.sh"

# What it may install, and where Caddy's hostname is read (as data, never run).
install -d -m 0755 -o root -g root "${STATE_DIR}"
printf '%s\n' "${HOST}" > "${STATE_DIR}/push-host"
printf '%s\n' "${SRC_DIR}/.env" > "${STATE_DIR}/proxy-env-path"
chmod 0644 "${STATE_DIR}/push-host" "${STATE_DIR}/proxy-env-path"
ok "Allowed hostname: ${HOST}"

# One sudo rule: exactly the receiver, nothing else.
printf '%s ALL=(root) NOPASSWD: %s\n' "${ACCOUNT}" "${RECEIVER}" > "${SUDOERS}.new"
chmod 0440 "${SUDOERS}.new"
visudo -cf "${SUDOERS}.new" >/dev/null || { rm -f "${SUDOERS}.new"; die "The sudo rule didn't check out."; }
mv -f "${SUDOERS}.new" "${SUDOERS}"
ok "sudo: ${ACCOUNT} may run only ${RECEIVER}"

# Home and key list owned by root, so the account can't change its own key.
install -d -m 0755 -o root -g root "${HOME_DIR}" "${HOME_DIR}/.ssh"
umask 022
printf 'restrict,from="%s",command="sudo -n %s" %s %s cert-push\n' "${FROM}" "${RECEIVER}" "${ktype}" "${kdata}" \
  > "${HOME_DIR}/.ssh/authorized_keys.new"
chmod 0644 "${HOME_DIR}/.ssh/authorized_keys.new"
mv -f "${HOME_DIR}/.ssh/authorized_keys.new" "${HOME_DIR}/.ssh/authorized_keys"
ok "Key installed: only from ${FROM}, only runs the receiver"

# Things in sshd's own config that would keep the key from working.
if command -v sshd >/dev/null 2>&1; then
  cfg="$(sshd -T -C "user=${ACCOUNT},host=pusher,addr=${FROM%/*}" 2>/dev/null || true)"
  if [[ -n "${cfg}" ]]; then
    if grep -qiE '^(allowusers|allowgroups) ' <<<"${cfg}" && ! grep -qiE "^allowusers .*\b${ACCOUNT}\b" <<<"${cfg}"; then
      warn "sshd has AllowUsers/AllowGroups set; add ${ACCOUNT} there or the pusher can't connect."
    fi
    grep -qiE '^pubkeyauthentication no' <<<"${cfg}" && warn "sshd has PubkeyAuthentication no for this login."
    grep -qiE '^authorizedkeysfile .*\.ssh/authorized_keys' <<<"${cfg}" \
      || warn "sshd's AuthorizedKeysFile isn't the default; it must include .ssh/authorized_keys."
  fi
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ufw status 2>/dev/null | grep -qE '^(22|22/tcp|OpenSSH)[[:space:]]'; then
    ok "UFW allows SSH"
  else
    warn "UFW is on and no SSH rule was found; allow port 22 from ${FROM} if the pusher can't connect."
  fi
fi

echo ""
echo "This VM's SSH host key (the pusher should pin it):"
if [[ -f /etc/ssh/ssh_host_ed25519_key.pub ]]; then cat /etc/ssh/ssh_host_ed25519_key.pub; fi
echo ""
echo "The first certificate for ${HOST} waits in place until you switch Caddy to it: ./proxy/install.sh --host ${HOST}"
