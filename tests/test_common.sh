#!/usr/bin/env bash
# Unit checks for common.sh helpers (no Docker required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
# shellcheck disable=SC1091
source "${ROOT}/common.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# load_dotenv does not execute shell
# shellcheck disable=SC2016
printf 'DATA_DIR=/mnt/from-env\n# comment\nEVIL=$(echo pwned)\n' > "$tmp"
unset DATA_DIR
load_dotenv "$tmp"
if [[ "${DATA_DIR}" == "/mnt/from-env" ]]; then
  pass "load_dotenv reads DATA_DIR"
else
  fail "load_dotenv DATA_DIR got '${DATA_DIR:-}'"
fi
# shellcheck disable=SC2016
if [[ "${EVIL:-}" == '$(echo pwned)' ]]; then
  pass "load_dotenv stores command substitutions as literals"
else
  fail "load_dotenv mishandled EVIL='${EVIL:-}'"
fi

# Spaces around equals + inline comment
unset SPACY_PORT
printf 'SPACY_PORT = 18545 # wallets\n' > "$tmp"
load_dotenv "$tmp"
if [[ "${SPACY_PORT}" == "18545" ]]; then
  pass "load_dotenv accepts spaces around = and strips unquoted comments"
else
  fail "load_dotenv SPACY_PORT got '${SPACY_PORT:-}'"
fi

# export prefix
unset EXPORTED_DIR
printf 'export EXPORTED_DIR=/opt/pulse\n' > "$tmp"
load_dotenv "$tmp"
if [[ "${EXPORTED_DIR}" == "/opt/pulse" ]]; then
  pass "load_dotenv accepts export KEY=VALUE"
else
  fail "load_dotenv EXPORTED_DIR got '${EXPORTED_DIR:-}'"
fi

# Skipped malformed line is reported
unset SKIP_ME
skip_err="$(printf 'this is not = valid\n' > "$tmp"; load_dotenv "$tmp" 2>&1 >/dev/null || true)"
if [[ "${skip_err}" == *"skipped line"* ]]; then
  pass "load_dotenv warns on non KEY=VALUE lines"
else
  fail "load_dotenv should warn on malformed assignment, got '${skip_err}'"
fi

# Existing environment wins
export DATA_DIR=/already-set
printf 'DATA_DIR=/should-not-win\n' > "$tmp"
load_dotenv "$tmp"
if [[ "${DATA_DIR}" == "/already-set" ]]; then
  pass "load_dotenv does not override exported vars"
else
  fail "load_dotenv overrode DATA_DIR to '${DATA_DIR}'"
fi

# Defaults for ports (empty counts as unset)
if [[ "${HTTP_PORT}" == "8545" ]]; then
  pass "HTTP_PORT defaults to 8545"
else
  fail "HTTP_PORT is '${HTTP_PORT:-}'"
fi

empty_port="$(HTTP_PORT='' BEACON_HTTP_HOST='' bash -c "source '${ROOT}/common.sh'; printf '%s %s' \"\${HTTP_PORT}\" \"\${BEACON_HTTP_HOST}\"")"
if [[ "${empty_port}" == "8545 127.0.0.1" ]]; then
  pass "empty HTTP_PORT / BEACON_HTTP_HOST fall back to defaults"
else
  fail "empty-value defaults got '${empty_port}'"
fi

if [[ "${HTTP_ADDR}" == "0.0.0.0" && "${WS_ADDR}" == "0.0.0.0" && "${GETH_P2P_PORT}" == "30303" ]]; then
  pass "HTTP_ADDR / WS_ADDR / GETH_P2P_PORT defaults"
else
  fail "bind/P2P defaults got HTTP_ADDR='${HTTP_ADDR:-}' WS_ADDR='${WS_ADDR:-}' GETH_P2P_PORT='${GETH_P2P_PORT:-}'"
fi

empty_bind="$(HTTP_ADDR='' WS_ADDR='' GETH_P2P_PORT='' BEACON_P2P_TCP_PORT='' BEACON_P2P_UDP_PORT='' bash -c \
  "source '${ROOT}/common.sh'; printf '%s %s %s %s %s' \"\${HTTP_ADDR}\" \"\${WS_ADDR}\" \"\${GETH_P2P_PORT}\" \"\${BEACON_P2P_TCP_PORT}\" \"\${BEACON_P2P_UDP_PORT}\"")"
if [[ "${empty_bind}" == "0.0.0.0 0.0.0.0 30303 13000 12000" ]]; then
  pass "empty HTTP_ADDR / P2P ports fall back to defaults"
else
  fail "empty bind/P2P defaults got '${empty_bind}'"
fi

if HTTP_ADDR=127.0.0.1 wallet_rpc_is_localhost && ! HTTP_ADDR=0.0.0.0 wallet_rpc_is_localhost; then
  pass "wallet_rpc_is_localhost treats 127.0.0.1 as localhost-only"
else
  fail "wallet_rpc_is_localhost misclassified HTTP_ADDR"
fi

# confirm_yes is non-interactive safe
if confirm_yes "should not prompt" </dev/null; then
  fail "confirm_yes returned true without a TTY/yes"
else
  pass "confirm_yes declines when stdin is not a TTY"
fi

# Public vs RFC1918 / CGNAT
if is_public_ipv4 "8.8.8.8" && is_public_ipv4 "1.2.3.4"; then
  pass "is_public_ipv4 accepts public addresses"
else
  fail "is_public_ipv4 rejected a public address"
fi
if is_public_ipv4 "10.0.0.1" || is_public_ipv4 "192.168.1.1" || is_public_ipv4 "172.16.5.5" \
   || is_public_ipv4 "127.0.0.1" || is_public_ipv4 "169.254.1.1" || is_public_ipv4 "100.64.0.1" \
   || is_public_ipv4 "100.127.255.255"; then
  fail "is_public_ipv4 treated a private/CGNAT/loopback address as public"
else
  pass "is_public_ipv4 rejects RFC1918, loopback, link-local, and CGNAT"
fi
if is_public_ipv4 "100.63.0.1"; then
  pass "100.63.0.1 is not CGNAT (treated as public)"
else
  fail "100.63.0.1 should not be classified as CGNAT"
fi

# JWT helper
if jwt_payload_is_valid ""; then
  fail "jwt_payload_is_valid accepted empty"
else
  pass "jwt_payload_is_valid rejects empty"
fi
if jwt_payload_is_valid "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; then
  pass "jwt_payload_is_valid accepts 64 hex chars"
else
  fail "jwt_payload_is_valid rejected a valid payload"
fi
printf '%s\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$tmp"
if [[ "$(jwt_payload "$tmp")" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]; then
  pass "jwt_payload strips trailing newline"
else
  fail "jwt_payload did not strip newline"
fi
if jwt_payload_is_valid "not-hex" || jwt_payload_is_valid "$(printf '0%.0s' {1..63})"; then
  fail "jwt_payload_is_valid accepted an invalid payload"
else
  pass "jwt_payload_is_valid rejects short or non-hex payloads"
fi

# upsert_dotenv uncomments and replaces
printf '# GETH_IMAGE=registry.gitlab.com/pulsechaincom/go-pulse:v3.3.0\nother=keep\n' > "$tmp"
upsert_dotenv "$tmp" GETH_IMAGE "${GETH_IMAGE_LATEST}"
if grep -qx "GETH_IMAGE=${GETH_IMAGE_LATEST}" "$tmp" \
   && grep -qx 'other=keep' "$tmp" \
   && ! grep -q '^# GETH_IMAGE=' "$tmp"; then
  pass "upsert_dotenv uncomments and sets GETH_IMAGE"
else
  fail "upsert_dotenv result was: $(tr '\n' '|' < "$tmp")"
fi

# Syntax of helper scripts
for script in install.sh start.sh stop.sh restart.sh logs.sh update.sh status.sh common.sh; do
  if bash -n "${ROOT}/${script}"; then
    pass "bash -n ${script}"
  else
    fail "bash -n ${script}"
  fi
done

# restart.sh must recreate from compose, not `compose restart`, and must force-recreate
if grep -E 'run_compose[[:space:]]+restart' "${ROOT}/restart.sh" >/dev/null; then
  fail "restart.sh still uses 'compose restart' (drops compose/flag edits)"
else
  pass "restart.sh does not use 'compose restart'"
fi
if grep -qE 'up -d --force-recreate' "${ROOT}/restart.sh"; then
  pass "restart.sh uses up -d --force-recreate"
else
  fail "restart.sh should call up -d --force-recreate so running nodes actually bounce"
fi

# update.sh opt-in latest persists to .env
if grep -q -- '--latest' "${ROOT}/update.sh" && grep -q 'upsert_dotenv' "${ROOT}/update.sh"; then
  pass "update.sh --latest writes .env via upsert_dotenv"
else
  fail "update.sh should persist --latest into .env"
fi
if grep -qE 'up -d --force-recreate' "${ROOT}/update.sh"; then
  pass "update.sh recreates containers after pull"
else
  fail "update.sh should force-recreate after pull"
fi

# Installer hardening
if grep -q 'chmod 600' "${ROOT}/install.sh"; then
  pass "install.sh sets JWT mode 600"
else
  fail "install.sh should chmod 600 the JWT"
fi
if grep -q 'jwt_payload_is_valid' "${ROOT}/install.sh"; then
  pass "install.sh validates existing JWT secrets"
else
  fail "install.sh should validate existing jwt.hex"
fi
if grep -q 'our_stack_running' "${ROOT}/install.sh"; then
  pass "install.sh ignores ports held by this stack"
else
  fail "install.sh should skip port conflicts when pulse-geth/pulse-beacon are running"
fi
if grep -q 'PULSE_ALLOW_PORT_CONFLICTS' "${ROOT}/install.sh"; then
  pass "install.sh has PULSE_ALLOW_PORT_CONFLICTS override"
else
  fail "install.sh should allow non-interactive port-conflict override"
fi
if grep -q 'docker.io' "${ROOT}/install.sh" && grep -q 'wait_for_docker' "${ROOT}/install.sh"; then
  pass "install.sh removes distro docker packages and waits for the daemon"
else
  fail "install.sh should remove docker.io conflicts and wait_for_docker"
fi
if grep -q 'PULSE_ALLOW_DOCKER_CE' "${ROOT}/install.sh" && grep -q 'debian_docker_conflict_installed' "${ROOT}/install.sh"; then
  pass "install.sh confirms before replacing an existing distro Docker"
else
  fail "install.sh should warn/confirm before removing docker.io"
fi
if grep -q 'container_running' "${ROOT}/install.sh"; then
  pass "install.sh checks containers after up"
else
  fail "install.sh should verify pulse-geth and pulse-beacon are running"
fi
if grep -q 'effective_install_user' "${ROOT}/install.sh"; then
  pass "install.sh uses effective_install_user (not raw \$USER)"
else
  fail "install.sh should not rely on possibly-empty USER"
fi
if grep -q 'omarchy-pkg-add' "${ROOT}/install.sh" && grep -q 'os_is_omarchy' "${ROOT}/install.sh"; then
  pass "install.sh has an Omarchy/Arch package path"
else
  fail "install.sh should install Docker via omarchy-pkg-add or pacman"
fi
if grep -q 'systemctl enable docker' "${ROOT}/install.sh"; then
  pass "install.sh enables docker.service on boot"
else
  fail "install.sh should enable docker.service so Omarchy nodes survive reboot"
fi
if grep -E '^[[:space:]]*[^#[:space:]].*pacman[[:space:]].*-Syu' "${ROOT}/install.sh"; then
  fail "install.sh must not run pacman -Syu (Omarchy ALPM guard)"
else
  pass "install.sh does not run pacman -Syu"
fi

# Distro detection helpers
if os_is_debian_family ubuntu && os_is_debian_family debian && os_is_debian_family linuxmint && os_is_debian_family pop; then
  pass "os_is_debian_family accepts Ubuntu/Debian/Mint/Pop"
else
  fail "os_is_debian_family rejected a Debian-family id"
fi
if os_is_debian_family arch || os_is_debian_family omarchy; then
  fail "os_is_debian_family accepted an Arch id"
else
  pass "os_is_debian_family rejects arch/omarchy"
fi
if os_is_omarchy omarchy; then
  pass "os_is_omarchy accepts ID=omarchy"
else
  fail "os_is_omarchy rejected ID=omarchy"
fi
omarchy_home="$(mktemp -d)"
mkdir -p "${omarchy_home}/.local/share/omarchy"
if HOME="${omarchy_home}" os_is_omarchy ubuntu debian; then
  fail "os_is_omarchy treated Ubuntu with leftover Omarchy files as Omarchy"
else
  pass "os_is_omarchy ignores leftover Omarchy files on Debian-family"
fi
if HOME="${omarchy_home}" os_is_omarchy arch ""; then
  pass "os_is_omarchy accepts Arch with Omarchy homedir marker"
else
  fail "os_is_omarchy rejected Arch with Omarchy homedir marker"
fi
rm -rf "${omarchy_home}"
if os_is_arch_family arch "" && os_is_arch_family omarchy "" && os_is_arch_family cachyos "arch"; then
  pass "os_is_arch_family accepts arch, omarchy, and ID_LIKE=arch"
else
  fail "os_is_arch_family rejected an Arch-family id"
fi
if os_is_arch_family ubuntu ""; then
  fail "os_is_arch_family accepted ubuntu"
else
  pass "os_is_arch_family rejects ubuntu"
fi

if grep -q 'Omarchy' "${ROOT}/README.md"; then
  pass "README documents Omarchy Linux"
else
  fail "README should document Omarchy support"
fi

# status.sh prints wallet URL via detect_lan_ip
if grep -q 'detect_lan_ip' "${ROOT}/status.sh"; then
  pass "status.sh prints wallet RPC via detect_lan_ip"
else
  fail "status.sh should print the LAN RPC URL"
fi
if grep -q 'wallet_rpc_is_localhost' "${ROOT}/status.sh" && grep -q 'Do not send transactions yet' "${ROOT}/status.sh"; then
  pass "status.sh honors localhost bind and warns while syncing"
else
  fail "status.sh should mention localhost-only bind and sync warnings"
fi
if grep -q 'Config.Image' "${ROOT}/status.sh"; then
  pass "status.sh prints running image refs"
else
  fail "status.sh should inspect running image names"
fi

if grep -q 'FEE_RECIPIENT' "${ROOT}/.env.example"; then
  fail ".env.example still documents unused FEE_RECIPIENT"
else
  pass ".env.example does not document unused FEE_RECIPIENT"
fi
if grep -q 'HTTP_ADDR' "${ROOT}/.env.example" && grep -q 'GETH_P2P_PORT' "${ROOT}/.env.example"; then
  pass ".env.example documents HTTP_ADDR and P2P ports"
else
  fail ".env.example should document HTTP_ADDR and GETH_P2P_PORT"
fi

# Docker signing key check (install.sh refuses keys with another fingerprint)
if command -v gpg >/dev/null 2>&1; then
  printf 'not a key\n' > "$tmp"
  if docker_gpg_key_is_valid "$tmp"; then
    fail "docker_gpg_key_is_valid accepted a non-key file"
  else
    pass "docker_gpg_key_is_valid rejects a non-key file"
  fi
  if docker_gpg_key_is_valid /nonexistent/docker.asc; then
    fail "docker_gpg_key_is_valid accepted a missing file"
  else
    pass "docker_gpg_key_is_valid rejects a missing file"
  fi
  if curl -fsSL --max-time 20 https://download.docker.com/linux/debian/gpg -o "$tmp" 2>/dev/null; then
    if docker_gpg_key_is_valid "$tmp"; then
      pass "Docker's published key matches DOCKER_GPG_FINGERPRINT"
    else
      fail "Docker's published key no longer matches DOCKER_GPG_FINGERPRINT (got '$(gpg_key_fingerprint "$tmp")')"
    fi
  elif [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
    fail "could not download Docker's signing key"
  else
    echo "SKIP: could not download Docker's signing key"
  fi
elif [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
  fail "gpg is required for the Docker key checks"
else
  echo "SKIP: gpg not installed; Docker key checks skipped"
fi
if grep -q 'docker_gpg_key_is_valid' "${ROOT}/install.sh"; then
  pass "install.sh verifies Docker's signing key"
else
  fail "install.sh should verify Docker's signing key"
fi

# Docker shutdown/mount safeguards (written under a temp root, no sudo)
sg_root="$(mktemp -d)"
(
  # shellcheck disable=SC2034  # read by install_docker_safeguards
  SUDO=""
  install_docker_safeguards "${sg_root}" /blockchain
  echo "first=${DOCKER_SAFEGUARDS_CHANGED} needs_edit=${DOCKER_DAEMON_JSON_NEEDS_EDIT}"
  install_docker_safeguards "${sg_root}" /blockchain
  echo "second=${DOCKER_SAFEGUARDS_CHANGED}"
) > "${sg_root}/out"
dropin="${sg_root}/etc/systemd/system/docker.service.d/${DOCKER_DROPIN_NAME}"
if grep -qx 'RequiresMountsFor=/blockchain' "${dropin}" 2>/dev/null \
   && grep -qx "TimeoutStopSec=${DOCKER_STOP_TIMEOUT_SEC}" "${dropin}" \
   && grep -q "\"shutdown-timeout\": ${DOCKER_SHUTDOWN_TIMEOUT_SEC}" "${sg_root}/etc/docker/daemon.json"; then
  pass "install_docker_safeguards writes the drop-in and daemon.json"
else
  fail "install_docker_safeguards did not write the expected files"
fi
if grep -qx 'first=1 needs_edit=0' "${sg_root}/out" && grep -qx 'second=0' "${sg_root}/out"; then
  pass "install_docker_safeguards is idempotent (second run changes nothing)"
else
  fail "install_docker_safeguards change tracking wrong: $(tr '\n' ' ' < "${sg_root}/out")"
fi
if (( DOCKER_STOP_TIMEOUT_SEC > DOCKER_SHUTDOWN_TIMEOUT_SEC )); then
  pass "systemd stop timeout exceeds Docker's container shutdown timeout"
else
  fail "DOCKER_STOP_TIMEOUT_SEC must exceed DOCKER_SHUTDOWN_TIMEOUT_SEC"
fi
printf '{ "log-driver": "local" }\n' > "${sg_root}/etc/docker/daemon.json"
(
  # shellcheck disable=SC2034  # read by install_docker_safeguards
  SUDO=""
  install_docker_safeguards "${sg_root}" /blockchain
  echo "needs_edit=${DOCKER_DAEMON_JSON_NEEDS_EDIT}"
) > "${sg_root}/out2"
if grep -qx 'needs_edit=1' "${sg_root}/out2" && grep -q '"log-driver": "local"' "${sg_root}/etc/docker/daemon.json" \
   && ! grep -q 'shutdown-timeout' "${sg_root}/etc/docker/daemon.json"; then
  pass "an existing daemon.json is left untouched and flagged"
else
  fail "existing daemon.json must not be rewritten (and should be flagged)"
fi
rm -rf "${sg_root}"
if grep -q 'install_docker_safeguards ""' "${ROOT}/install.sh"; then
  pass "install.sh applies the Docker safeguards"
else
  fail "install.sh should call install_docker_safeguards"
fi

# LAN_ALLOW_FROM parsing
if out="$(LAN_ALLOW_FROM="172.31.0.0/16 192.168.1.0/24" lan_allow_from_list)" \
   && [[ "${out}" == $'172.31.0.0/16\n192.168.1.0/24' ]]; then
  pass "lan_allow_from_list returns each CIDR"
else
  fail "lan_allow_from_list did not return the CIDRs"
fi
if LAN_ALLOW_FROM="172.31.0.0/16 0.0.0.0/0x" lan_allow_from_list >/dev/null 2>&1 \
   || LAN_ALLOW_FROM="anywhere" lan_allow_from_list >/dev/null 2>&1; then
  fail "lan_allow_from_list accepted an invalid entry"
else
  pass "lan_allow_from_list rejects invalid entries"
fi
# shellcheck disable=SC2016  # literal text in install.sh
if grep -qF 'for range in ${lan_ranges}' "${ROOT}/install.sh" && ! grep -q 'for range in 10.0.0.0/8' "${ROOT}/install.sh"; then
  pass "install.sh UFW rules use LAN_ALLOW_FROM"
else
  fail "install.sh should build RPC rules from LAN_ALLOW_FROM"
fi

# install.sh must find sbin tools (ufw) when run as a normal user on Debian
if (
  PATH=/usr/bin:/bin
  eval "$(sed -n '/^# Debian does not put \/usr\/sbin/,/^export PATH/p' "${ROOT}/common.sh")"
  [[ ":${PATH}:" == *:/usr/sbin:* && ":${PATH}:" == *:/sbin:* ]]
); then
  pass "common.sh adds /usr/sbin and /sbin to PATH (all installers)"
else
  fail "common.sh should add /usr/sbin and /sbin to PATH (Debian users lack them, so ufw is missed)"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more common.sh / script checks failed." >&2
  exit 1
fi
echo "All common.sh checks passed."
exit 0
