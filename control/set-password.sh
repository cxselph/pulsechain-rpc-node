#!/usr/bin/env bash
# set-password.sh — set a new control page password (no old password needed)
# Also rotates the session key, so every device has to sign in again.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ -t 0 ]] || { echo "Run this in an interactive terminal (it prompts for the password)." >&2; exit 1; }
[[ -f "${CONTROL_ENV}" ]] || { echo "control/.env is missing. Run ./control/install.sh first." >&2; exit 1; }
run_docker image inspect "${CONTROL_IMAGE}" >/dev/null 2>&1 || { echo "Image ${CONTROL_IMAGE} not built yet. Run ./control/install.sh first." >&2; exit 1; }

echo "New control page password (at least 12 characters; save it in your password manager)."
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

# Hash with the app's own library inside the image; the password goes in on stdin.
hash_b64="$(printf '%s\n' "${pw1}" | run_docker run --rm -i --network none --entrypoint python3 "${CONTROL_IMAGE}" -c '
import base64, sys
from werkzeug.security import generate_password_hash
pw = sys.stdin.readline().rstrip("\n")
print(base64.b64encode(generate_password_hash(pw).encode()).decode())')"
unset pw1 pw2
[[ -n "${hash_b64}" ]] || { echo "Hashing failed." >&2; exit 1; }

upsert_dotenv "${CONTROL_ENV}" CONTROL_PASSWORD_HASH "${hash_b64}"
upsert_dotenv "${CONTROL_ENV}" CONTROL_SECRET_KEY "$(openssl rand -hex 32)"
chmod 600 "${CONTROL_ENV}"

if container_running "${CONTROL_CONTAINER}"; then
  control_compose up -d --force-recreate >/dev/null 2>&1
  wait_for_control || { echo "Password saved, but the control page did not come back. Check ./control/logs.sh" >&2; exit 1; }
fi
echo "Control page password updated. Every device has to sign in again."
