#!/usr/bin/env bash
# reset-grafana-password.sh — set a new Grafana admin password (no old password needed)
# Use it the first time (install.sh calls it) and whenever the password is lost.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! container_running "${GRAFANA_CONTAINER}"; then
  echo "Grafana is not running. Start it first: ./monitoring/start.sh" >&2
  exit 1
fi
if [[ ! -t 0 ]]; then
  echo "Run this in an interactive terminal (it prompts for the password)." >&2
  exit 1
fi

echo "New Grafana password for user 'admin' (at least 12 characters; save it in your password manager)."
while true; do
  read -r -s -p "New password: " pw1; echo
  read -r -s -p "Repeat: " pw2; echo
  if [[ "${pw1}" != "${pw2}" ]]; then
    echo "The two entries don't match. Try again."
  elif (( ${#pw1} < 12 )); then
    echo "Too short (${#pw1} characters). Use at least 12."
  else
    break
  fi
done

# Passed on stdin, so the password never shows up in a process list.
if printf '%s\n' "${pw1}" | run_docker exec -i "${GRAFANA_CONTAINER}" \
    grafana cli admin reset-admin-password --password-from-stdin >/dev/null; then
  unset pw1 pw2
  echo "Grafana admin password updated. Sign in as 'admin' with the new password."
else
  unset pw1 pw2
  echo "Password reset failed. Check: ./monitoring/logs.sh grafana" >&2
  exit 1
fi
