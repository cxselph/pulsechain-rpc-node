#!/usr/bin/env bash
# lib.sh — shared helpers for the monitoring scripts
# shellcheck shell=bash

MON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${MON_DIR}/../common.sh"

# shellcheck disable=SC2034  # used by the scripts that source this file
{
MON_ENV="${MON_DIR}/.env"
MON_HELPER_DIR=/usr/local/lib/pulsechain-rpc-node
MON_TEXTFILE_DIR=/var/lib/pulse-node-metrics
GRAFANA_CONTAINER=pulse-grafana
GRAFANA_HEALTH_URL="http://127.0.0.1:3000/grafana/api/health"
# Secrets monitoring/.env must provide before the stack starts.
MON_REQUIRED_KEYS=(GF_SMTP_HOST GF_SMTP_USER GF_SMTP_PASSWORD GF_SMTP_FROM_ADDRESS ALERT_EMAIL_TO)
}

# Compose interpolation reads DATA_DIR (exported by common.sh) and monitoring/.env.
mon_compose() {
  run_docker compose -f "${MON_DIR}/docker-compose.yml" --project-directory "${MON_DIR}" "$@"
}

# Value of KEY in monitoring/.env (empty if missing). Does not execute the file.
mon_env_value() {
  local key="$1" line
  [[ -f "${MON_ENV}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${MON_ENV}" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  _trim "${line}"
}

# Prints the names of required keys that are still empty.
mon_missing_keys() {
  local key
  for key in "${MON_REQUIRED_KEYS[@]}"; do
    [[ -n "$(mon_env_value "${key}")" ]] || printf '%s\n' "${key}"
  done
}

wait_for_grafana() {
  local i
  for ((i = 1; i <= 60; i++)); do
    if curl -fsS -m 3 "${GRAFANA_HEALTH_URL}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
