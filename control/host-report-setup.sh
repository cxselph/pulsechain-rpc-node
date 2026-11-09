#!/usr/bin/env bash
# host-report-setup.sh — let the hypervisor push its health report to this VM
# for the control page's "Host" card. Optional.
#
#   sudo ./control/host-report-setup.sh --from <hypervisor IP> '<ssh-ed25519 public key>'
#   sudo ./control/host-report-setup.sh --remove
#
# One way only: the hypervisor gets an SSH key that can do exactly one thing
# here, store the text it sends as the report (forced command, no shell, no
# forwarding, only from that IP). This VM gets no access to the hypervisor.
# Re-run it to change the key or the IP; it replaces the old entry.
set -euo pipefail

ACCOUNT=host-report
HOME_DIR=/var/lib/host-report
REPORT_DIR=/var/lib/node-control/host-report
RECEIVER=/usr/local/lib/node-control/host-report-receive
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-report-receive.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[[ "${EUID}" -eq 0 ]] || die "Run with sudo."

if [[ "${1:-}" == "--remove" ]]; then
  if id "${ACCOUNT}" >/dev/null 2>&1; then userdel "${ACCOUNT}"; fi
  rm -rf "${HOME_DIR}" "${RECEIVER}"
  ok "Removed the ${ACCOUNT} account and its key. The last report stays in ${REPORT_DIR} (delete it to hide the card)."
  exit 0
fi

FROM=""
KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) KEY="$1"; shift ;;
  esac
done
[[ -n "${FROM}" && -n "${KEY}" ]] || usage
[[ "${FROM}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || die "--from must be an IPv4 address (or CIDR), got: ${FROM}"
read -r ktype kdata _ <<<"${KEY}"
[[ "${ktype}" == "ssh-ed25519" && "${kdata}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "Expected an ssh-ed25519 public key (one line starting with ssh-ed25519)."
[[ -f "${SRC}" ]] || die "Missing ${SRC}"

# Account: no password (but not "locked", which some sshd setups refuse), and
# nothing it can do except the forced command below.
if ! id "${ACCOUNT}" >/dev/null 2>&1; then
  useradd --system --home-dir "${HOME_DIR}" --no-create-home --shell /bin/sh \
    --comment "hypervisor health report (control page)" "${ACCOUNT}"
  ok "Created the ${ACCOUNT} account"
fi
usermod -p '*' "${ACCOUNT}"

install -d -m 0755 -o root -g root "$(dirname "${RECEIVER}")"
install -m 0755 -o root -g root "${SRC}" "${RECEIVER}"
install -d -m 0755 -o "${ACCOUNT}" -g "${ACCOUNT}" "${REPORT_DIR}"

# Home and key list owned by root, so the account can't change its own key.
install -d -m 0755 -o root -g root "${HOME_DIR}" "${HOME_DIR}/.ssh"
umask 022
printf 'restrict,from="%s",command="%s" %s %s pve-host-report\n' "${FROM}" "${RECEIVER}" "${ktype}" "${kdata}" \
  > "${HOME_DIR}/.ssh/authorized_keys.new"
chmod 0644 "${HOME_DIR}/.ssh/authorized_keys.new"
mv -f "${HOME_DIR}/.ssh/authorized_keys.new" "${HOME_DIR}/.ssh/authorized_keys"
ok "Key installed: only from ${FROM}, only runs ${RECEIVER}"

# Things in sshd's own config that would keep the key from working.
if command -v sshd >/dev/null 2>&1; then
  cfg="$(sshd -T -C "user=${ACCOUNT},host=hypervisor,addr=${FROM%/*}" 2>/dev/null || true)"
  if [[ -n "${cfg}" ]]; then
    if grep -qiE '^(allowusers|allowgroups) ' <<<"${cfg}" && ! grep -qiE "^allowusers .*\b${ACCOUNT}\b" <<<"${cfg}"; then
      warn "sshd has AllowUsers/AllowGroups set; add ${ACCOUNT} there or the hypervisor can't connect."
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
    warn "UFW is on and no SSH rule was found; allow port 22 from ${FROM} if the hypervisor can't connect."
  fi
fi

echo ""
echo "This VM's SSH host key (compare with what the hypervisor's install prints):"
if [[ -f /etc/ssh/ssh_host_ed25519_key.pub ]]; then ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub; fi
echo ""
echo "Reports land in ${REPORT_DIR}/report.txt; the control page shows them on its Host card."
