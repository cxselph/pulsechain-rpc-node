#!/usr/bin/env bash
# lib.sh — shared helpers for the control page scripts
# shellcheck shell=bash

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${CONTROL_DIR}/../common.sh"

# shellcheck disable=SC2034  # used by the scripts that source this file
{
CONTROL_ENV="${CONTROL_DIR}/.env"
CONTROL_VAR=/var/lib/node-control
CONTROL_UID=10001
CONTROL_CONTAINER=pulse-control
CONTROL_IMAGE=pulse-control:local
}

control_compose() {
  run_docker compose -f "${CONTROL_DIR}/docker-compose.yml" --project-directory "${CONTROL_DIR}" "$@"
}

# Value of KEY in control/.env (empty if unset). Does not execute the file.
control_env_value() {
  local key="$1" line
  [[ -f "${CONTROL_ENV}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${CONTROL_ENV}" | tail -n 1 || true)"
  _trim "${line#*=}"
}

wait_for_control() {
  local i
  for ((i = 1; i <= 30; i++)); do
    curl -fsS -m 3 http://127.0.0.1:8090/healthz >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
