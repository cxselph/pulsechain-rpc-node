#!/usr/bin/env bash
# import-keys.sh — import validator keystores (keystore-m_*.json) into the wallet
#   sudo ./validator/import-keys.sh /media/usb/validator_keys
# Asks for the keystore password, and on first use for a new wallet password,
# which is saved root-only in the data dir so the validator can start unattended.
# Only keystores are needed. Never bring the mnemonic to this machine.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

keys_dir="${1:-}"
[[ -n "${keys_dir}" && -d "${keys_dir}" ]] || { echo "Usage: sudo $0 <folder with keystore-m_*.json>" >&2; exit 1; }
keys_dir="$(cd "${keys_dir}" && pwd)"
shopt -s nullglob
keystores=("${keys_dir}"/keystore-m_*.json)
shopt -u nullglob
[[ "${#keystores[@]}" -gt 0 ]] || { echo "No keystore-m_*.json files in ${keys_dir}." >&2; exit 1; }
if val_running; then
  echo "Stop the validator first (sudo ./validator/stop.sh): keys are only imported while it's down." >&2
  exit 1
fi
[[ -t 0 ]] || { echo "Run this in a terminal: it asks for passwords." >&2; exit 1; }

val_make_dirs
if [[ ! -s "${VAL_PASSWORD_FILE}" ]]; then
  echo "Choose a wallet password (at least 8 characters). Save it in your password manager."
  while :; do
    read -r -s -p "New wallet password: " pw1; echo
    read -r -s -p "Again: " pw2; echo
    if [[ "${pw1}" != "${pw2}" ]]; then echo "They don't match. Try again."; continue; fi
    if [[ "${#pw1}" -lt 8 ]]; then echo "Too short. Try again."; continue; fi
    break
  done
  (umask 077; printf '%s' "${pw1}" > "${VAL_PASSWORD_FILE}")
  unset pw1 pw2
fi
chmod 600 "${VAL_PASSWORD_FILE}"

echo "Importing ${#keystores[@]} keystore(s) from ${keys_dir}. Prysm asks for the keystore password next."
val_run -it -v "${keys_dir}:/import:ro" -- accounts import --pulsechain \
  --wallet-dir=/validator-data/wallet --wallet-password-file=/validator-data/wallet-password.txt --keys-dir=/import

echo
echo "Keys in the wallet now:"
val_run -- accounts list --pulsechain --wallet-dir=/validator-data/wallet --wallet-password-file=/validator-data/wallet-password.txt

echo
echo "Next:"
echo "  - Check the public keys above against your deposit_data-*.json."
echo "  - Wipe the keystores from the USB stick once you've confirmed the offline copy."
echo "  - When everything is ready: sudo ./validator/enable.sh"
