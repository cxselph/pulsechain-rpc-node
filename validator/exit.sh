#!/usr/bin/env bash
# exit.sh — voluntary exit: permanently stop validating and have the whole balance
# paid to the withdrawal address. It can't be undone, and the keys can't be used again.
# Prysm lists the keys and asks you to type its confirmation phrase.
# Leave the validator running until the status reads Exited, then ./validator/disable.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root
[[ -t 0 ]] || { echo "Run this in a terminal: Prysm asks you to confirm." >&2; exit 1; }
[[ -s "${VAL_KEYSTORE}" ]] || { echo "No imported keys in ${VAL_DATA}/wallet." >&2; exit 1; }

cat <<MSG
A voluntary exit is PERMANENT. Before going on, check on the beacon explorer that each
validator's withdrawal credentials are 0x01 followed by YOUR withdrawal address:
the exited balance is paid there and nowhere else.
MSG
read -r -p "Type 'exit for good' to continue: " reply
[[ "${reply}" == "exit for good" ]] || { echo "Nothing changed."; exit 1; }

# Host network: the exit is signed here and sent to the local beacon's gRPC.
run_docker run --rm -it --network host -v "${VAL_DATA}:/validator-data" "${VALIDATOR_IMAGE_PINNED}" \
  accounts voluntary-exit --pulsechain \
  --wallet-dir=/validator-data/wallet --wallet-password-file=/validator-data/wallet-password.txt \
  --beacon-rpc-provider="127.0.0.1:${BEACON_GRPC_PORT}"
echo
echo "Exit submitted. Keep the validator running until its status reads Exited (Validator dashboard"
echo "or the explorer), then switch it off: sudo ./validator/disable.sh"
