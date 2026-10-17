#!/usr/bin/env bash
# lib.sh — shared helpers for the Tailscale scripts
# shellcheck shell=bash

TS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${TS_DIR}/../common.sh"

# shellcheck disable=SC2034  # used by the scripts that source this file
{
TS_ENV="${TS_DIR}/.env"
# Tailscale's apt signing key ("Tailscale Inc. (Package repository signing key)").
TAILSCALE_GPG_FINGERPRINT="2596A99EAAB33821893C0A79458CA832957F5868"
# Version installed on first setup (~14-day rule). Later updates: apt, reviewed.
TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.102.5}"
COREDNS_CONTAINER=pulse-coredns
}

ts_compose() {
  run_docker compose -f "${TS_DIR}/docker-compose.yml" --project-directory "${TS_DIR}" "$@"
}

ts_env_value() {
  local key="$1" line
  [[ -f "${TS_ENV}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TS_ENV}" | tail -n 1 || true)"
  _trim "${line#*=}"
}

# BackendState from `tailscale status --json` (Running, NeedsLogin, Stopped, ...).
ts_backend_state() {
  tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}
