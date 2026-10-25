#!/usr/bin/env bash
# lib.sh — shared helpers for the validator scripts
# shellcheck shell=bash

VAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${VAL_DIR}/../common.sh"

# shellcheck disable=SC2034  # used by the scripts that source this file
{
VALIDATOR_IMAGE_PINNED="registry.gitlab.com/pulsechaincom/prysm-pulse/validator:v2.3.0@sha256:ade27eff3b3586cabd073bb14a70831ee7c143f1a7de1bec019d0e54e5261346"
VALIDATOR_CONTAINER=pulse-validator
VAL_ENV="${VAL_ENV:-${VAL_DIR}/.env}"
# Host side of the container's /validator-data (/validator is the binary). Tests point this at a temp dir.
VAL_DATA="${VAL_DATA:-${DATA_DIR}/validator}"
VAL_ENABLED="${VAL_DATA}/ENABLED"
VAL_PASSWORD_FILE="${VAL_DATA}/wallet-password.txt"
# Written by `accounts import` (Prysm's "direct" imported wallet).
VAL_KEYSTORE="${VAL_DATA}/wallet/direct/accounts/all-accounts.keystore.json"
# Written by ./stop.sh when it stopped a running validator, so ./start.sh brings
# it back. A validator stopped on its own (validator/stop.sh) stays down.
VAL_RESUME_FILE="${VAL_RESUME_FILE:-${VAL_DIR}/.resume-with-node}"
VAL_STOP_TIMEOUT_SEC=120
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
}

# Compose interpolation reads DATA_DIR / BEACON_* (exported by common.sh) and validator/.env.
val_compose() {
  run_docker compose -f "${VAL_DIR}/docker-compose.yml" --project-directory "${VAL_DIR}" "$@"
}

# Runs a one-off validator command (import, export, list) against the data dir.
# Extra docker options go before "--", validator arguments after it.
val_run() {
  local opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  run_docker run --rm --network none "${opts[@]}" -v "${VAL_DATA}:/validator-data" \
    "${VALIDATOR_IMAGE_PINNED}" "$@"
}

# Value of KEY in validator/.env (empty if missing). Does not execute the file.
val_env_value() {
  local key="$1" line
  [[ -f "${VAL_ENV}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${VAL_ENV}" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  _trim "${line}"
}

# True for a 0x address that isn't the zero address.
fee_recipient_is_valid() {
  local addr="$1"
  [[ "${addr}" =~ ^0x[0-9a-fA-F]{40}$ ]] || return 1
  [[ "$(printf '%s' "${addr}" | tr 'A-F' 'a-f')" != "${ZERO_ADDRESS}" ]]
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Prints one line per reason the validator must not start. Empty output = OK.
val_preflight_problems() {
  local fee mode
  [[ -e "${VAL_ENABLED}" ]] \
    || echo "The validator is switched off (no ${VAL_ENABLED}). Switch it on with ./validator/enable.sh."
  fee="$(val_env_value FEE_RECIPIENT)"
  if [[ -z "${fee}" ]]; then
    echo "FEE_RECIPIENT is not set in validator/.env."
  elif ! fee_recipient_is_valid "${fee}"; then
    echo "FEE_RECIPIENT '${fee}' is not a valid address (0x + 40 hex characters, not the zero address)."
  fi
  [[ -s "${VAL_KEYSTORE}" ]] \
    || echo "No imported keys (${VAL_KEYSTORE} is missing). Import them with ./validator/import-keys.sh."
  if [[ ! -s "${VAL_PASSWORD_FILE}" ]]; then
    echo "The wallet password file ${VAL_PASSWORD_FILE} is missing or empty."
  else
    mode="$(file_mode "${VAL_PASSWORD_FILE}")"
    [[ "${mode}" == "600" || "${mode}" == "400" ]] \
      || echo "${VAL_PASSWORD_FILE} has mode ${mode}; it must be 600 (only root can read it)."
  fi
}

# Creates the data layout: the top level stays readable so scripts can see ENABLED,
# the wallet, DB and exports are root-only.
val_make_dirs() {
  install -d -m 0755 "${VAL_DATA}"
  install -d -m 0700 "${VAL_DATA}/wallet" "${VAL_DATA}/db" "${VAL_DATA}/exports"
}

val_running() {
  container_running "${VALIDATOR_CONTAINER}"
}

val_exists() {
  run_docker inspect "${VALIDATOR_CONTAINER}" >/dev/null 2>&1
}

# Stops the validator but keeps the container, so ./start.sh can bring it back
# without a new check. Docker leaves a container stopped this way down across reboots.
val_stop() {
  if val_running; then
    echo "Stopping the validator (up to ${VAL_STOP_TIMEOUT_SEC} s)..."
    run_docker stop -t "${VAL_STOP_TIMEOUT_SEC}" "${VALIDATOR_CONTAINER}" >/dev/null
  fi
}

# Starts the existing container of a switched-on validator. Needs no root: it
# passed the start checks when it was created. Returns 1 if there's nothing to start.
val_resume() {
  if val_running; then
    echo "The validator is already running."
    return 0
  fi
  if [[ ! -e "${VAL_ENABLED}" ]] || ! val_exists; then
    echo "The validator isn't switched on, so there's nothing to start. Switch it on over SSH: sudo ./validator/enable.sh" >&2
    return 1
  fi
  run_docker start "${VALIDATOR_CONTAINER}" >/dev/null
  echo "Validator started again (doppelganger wait: 2-3 epochs before it signs)."
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "Run this with sudo: the validator's files are root-only." >&2; exit 1; }
}
