#!/usr/bin/env bash
# Checks for the optional validator client (validator/): pin, flags, that it is
# off by default, the start checks, and that the node's scripts and watchdog
# leave it alone.
# shellcheck disable=SC2015,SC2016  # pass() never fails; '${VAR}' patterns are literal compose text
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAL="${ROOT}/validator"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }
in_ci() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

compose="${VAL}/docker-compose.yml"
VAL_DATA="${TMP}/data"
VAL_ENV="${TMP}/val.env"
# shellcheck source=../validator/lib.sh
source "${VAL}/lib.sh"

# --- Image: pinned, same digest in compose and lib.sh, matches the registry ---
image="$(grep -E '^\s+image:' "${compose}" | awk '{print $2}')"
[[ "${image}" == "${VALIDATOR_IMAGE_PINNED}" ]] && pass "compose image matches VALIDATOR_IMAGE_PINNED" \
  || fail "compose image '${image}' != VALIDATOR_IMAGE_PINNED '${VALIDATOR_IMAGE_PINNED}'"
[[ "${image}" =~ ^registry\.gitlab\.com/pulsechaincom/prysm-pulse/validator:v[0-9.]+@sha256:[0-9a-f]{64}$ ]] \
  && pass "validator image pinned by tag + digest" || fail "validator image not pinned by tag + digest: ${image}"
# Same release as the beacon, so the two never drift apart.
beacon_tag="$(grep -oE 'beacon-chain:v[0-9.]+' "${ROOT}/docker-compose.yml" | head -n1)"
[[ "${image}" == *"validator:${beacon_tag#beacon-chain:}@"* ]] && pass "validator and beacon are the same release (${beacon_tag#beacon-chain:})" \
  || fail "validator image ${image%%@*} is not the beacon's release ${beacon_tag}"
tag="${image%%@*}"; tag="${tag##*:}"; want="${image##*@}"
if got="$(python3 - "pulsechaincom/prysm-pulse/validator" "${tag}" <<'PY' 2>/dev/null
import json, sys, time, urllib.parse, urllib.request
repo, tag = sys.argv[1], sys.argv[2]
def lookup():
    auth = "https://gitlab.com/jwt/auth?service=container_registry&scope=" + urllib.parse.quote(f"repository:{repo}:pull")
    token = json.load(urllib.request.urlopen(auth, timeout=20))["token"]
    req = urllib.request.Request(f"https://registry.gitlab.com/v2/{repo}/manifests/{tag}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"})
    return urllib.request.urlopen(req, timeout=20).headers["Docker-Content-Digest"]
for attempt in range(4):  # the registry sometimes answers 5xx for a moment
    try:
        print(lookup()); break
    except Exception:
        if attempt == 3: raise
        time.sleep(5 * (attempt + 1))
PY
)"; then
  [[ "${got}" == "${want}" ]] && pass "registry digest matches validator:${tag}" || fail "validator:${tag} registry digest ${got} != pin ${want}"
elif in_ci; then
  fail "could not read registry digest for validator:${tag}"
else
  echo "SKIP: registry digest for validator:${tag} (offline?)"
fi

# --- Flags and binds ----------------------------------------------------------
for flag in '--pulsechain' '--enable-doppelganger' '--monitoring-host=127.0.0.1' \
            '--datadir=/validator-data/db' '--wallet-dir=/validator-data/wallet' \
            '--wallet-password-file=/validator-data/wallet-password.txt' \
            '--suggested-fee-recipient=${FEE_RECIPIENT:?'; do
  grep -qF -- "- ${flag}" "${compose}" && pass "flag ${flag}" || fail "validator compose is missing ${flag}"
done
if grep -qE '0\.0\.0\.0|ports:|--web|--rpc$|--grpc-gateway-host' "${compose}"; then
  fail "validator compose must not publish ports or open its web UI / API"
else
  pass "no published ports, web UI or API on the validator"
fi
# The image's binary is /validator, so data must be mounted elsewhere.
grep -qF -- '/validator:/validator-data' "${compose}" && ! grep -qE ':/validator$' "${compose}" \
  && pass "data mounted at /validator-data (not over the /validator binary)" || fail "data must mount at /validator-data"
if grep -qE '^\s+validator:' "${ROOT}/docker-compose.yml"; then
  fail "the node's docker-compose.yml must not contain the validator (start.sh would start it)"
else
  pass "validator is not part of the node's compose project"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if out="$(docker compose --env-file /dev/null -f "${compose}" config 2>&1)"; then
    fail "compose config must fail without FEE_RECIPIENT"
  else
    [[ "${out}" == *"FEE_RECIPIENT"* ]] && pass "compose refuses to render without FEE_RECIPIENT" || fail "unexpected compose error: ${out}"
  fi
  cfg="$(FEE_RECIPIENT=0x000000000000000000000000000000000000dEaD DATA_DIR=/mnt/chain BEACON_GRPC_PORT=14000 \
    docker compose --env-file /dev/null -f "${compose}" config 2>&1)" || { fail "compose config failed: ${cfg}"; cfg=""; }
  if [[ -n "${cfg}" ]]; then
    [[ "${cfg}" == *"--suggested-fee-recipient=0x000000000000000000000000000000000000dEaD"* ]] && pass "FEE_RECIPIENT interpolates" || fail "FEE_RECIPIENT did not interpolate"
    [[ "${cfg}" == *"source: /mnt/chain/validator"* ]] && pass "data dir follows DATA_DIR" || fail "DATA_DIR did not interpolate into the volume"
    [[ "${cfg}" == *"--beacon-rpc-provider=127.0.0.1:14000"* ]] && pass "beacon gRPC port follows BEACON_GRPC_PORT" || fail "BEACON_GRPC_PORT did not interpolate"
    [[ "${cfg}" == *"name: pulse-validator"* ]] && pass "own compose project (pulse-validator)" || fail "compose project should be pulse-validator"
  fi
else
  in_ci && fail "docker compose is needed for the compose checks" || echo "SKIP: docker compose not available"
fi

# --- Fee recipient ------------------------------------------------------------
for good in 0x000000000000000000000000000000000000dEaD 0xAbCdEf0123456789abcdef0123456789ABCDEF01; do
  fee_recipient_is_valid "${good}" && pass "valid fee recipient ${good}" || fail "should accept ${good}"
done
for bad in "" 0x0000000000000000000000000000000000000000 0x00000000000000000000000000000000000000 \
           000000000000000000000000000000000000dEaD00 0x000000000000000000000000000000000000dEaG "0x000000000000000000000000000000000000dEaD "; do
  fee_recipient_is_valid "${bad}" && fail "should reject '${bad}'" || pass "rejects fee recipient '${bad}'"
done

# --- Start checks against a temp data dir ---------------------------------------
problems() { val_preflight_problems; }
count() { local n; n="$(problems | grep -c . || true)"; printf '%s' "${n}"; }
# Not "problems | grep -q": grep exits early and pipefail turns that into a failure.
has() { [[ "$(problems)" == *"$1"* ]]; }
[[ "$(count)" -eq 4 ]] && pass "empty setup: 4 problems (off, no fee recipient, no keys, no password)" \
  || { fail "empty setup should report 4 problems, got:"; problems >&2; }
has 'switched off' && pass "reports switched off" || fail "should report that the validator is switched off"

mkdir -p "${TMP}/data"
val_make_dirs
[[ "$(file_mode "${TMP}/data/wallet")" == 700 && "$(file_mode "${TMP}/data/db")" == 700 && "$(file_mode "${TMP}/data")" == 755 ]] \
  && pass "wallet and db are 700, top level 755 (ENABLED stays visible)" || fail "unexpected modes from val_make_dirs"
printf 'FEE_RECIPIENT=0x0000000000000000000000000000000000000000\n' > "${TMP}/val.env"
has 'not a valid address' && pass "zero-address fee recipient is refused" || fail "zero address should be refused"
printf 'FEE_RECIPIENT="0x000000000000000000000000000000000000dEaD"\n' > "${TMP}/val.env"
mkdir -p "${TMP}/data/wallet/direct/accounts"
echo '{}' > "${VAL_KEYSTORE}"
printf 'secret' > "${VAL_PASSWORD_FILE}"; chmod 644 "${VAL_PASSWORD_FILE}"
has 'has mode 644' && pass "readable password file is refused" || fail "password file with mode 644 should be refused"
chmod 600 "${VAL_PASSWORD_FILE}"
[[ "$(count)" -eq 1 ]] && has 'switched off' && pass "only 'switched off' left once the setup is complete" \
  || { fail "expected only the switched-off problem, got:"; problems >&2; }
date -u +%Y-%m-%dT%H:%M:%SZ > "${VAL_ENABLED}"
[[ -z "$(problems)" ]] && pass "switched on + complete setup: no problems" || { fail "expected no problems, got:"; problems >&2; }

# --- Scripts -----------------------------------------------------------------------
for s in start restart enable disable import-keys export-slashing import-slashing exit; do
  if out="$(bash "${VAL}/${s}.sh" 2>&1)"; then
    [[ "${EUID}" -eq 0 ]] && pass "${s}.sh (running as root, skipped)" || fail "${s}.sh should refuse without root"
  else
    [[ "${out}" == *"sudo"* ]] && pass "${s}.sh refuses without root" || fail "${s}.sh failed without mentioning sudo: ${out}"
  fi
done
grep -q '^val_stop$' "${ROOT}/stop.sh" && pass "stop.sh stops the validator before the node" || fail "stop.sh should call val_stop"
awk '/val_stop/{v=NR} /run_compose down/{d=NR} END{exit !(v && d && v < d)}' "${ROOT}/stop.sh" \
  && pass "stop.sh: validator first, then the node" || fail "stop.sh must stop the validator before compose down"
grep -q 'touch "${VAL_RESUME_FILE}"' "${ROOT}/stop.sh" && grep -q 'val_resume' "${ROOT}/start.sh" \
  && pass "start.sh brings back a validator that stop.sh stopped" || fail "stop.sh should mark a running validator and start.sh resume it"
grep -q 'rm -f "${VAL_RESUME_FILE}"' "${VAL}/stop.sh" && pass "validator/stop.sh keeps it down across node restarts" \
  || fail "validator/stop.sh should clear the resume marker"
grep -q '"pulse-validator")' "${ROOT}/control/node-control.py" && pass "watchdog never restarts the validator" \
  || fail "pulse-validator should be in the watchdog's NODE_CLIENTS"
grep -qx '\.env' "${ROOT}/.gitignore" && pass "validator/.env is gitignored" || fail ".env should be gitignored"

# Every script is documented, and the runbook covers the procedures that can go wrong.
for f in "${VAL}"/*.sh; do
  s="$(basename "${f}")"; [[ "${s}" == lib.sh ]] && continue
  grep -qF "validator/${s}" "${ROOT}/README.md" "${VAL}/RUNBOOK.md" && pass "documented: ${s}" || fail "validator/${s} is not mentioned in README.md or RUNBOOK.md"
done
for h in "First switch-on" "Moving the validator" "Restoring the VM" "Voluntary exit" "double-signing"; do
  grep -q "^## .*${h}" "${VAL}/RUNBOOK.md" && pass "runbook section: ${h}" || fail "RUNBOOK.md lacks a section on ${h}"
done
grep -qF 'validator/RUNBOOK.md' "${ROOT}/README.md" && pass "README links the runbook" || fail "README should link validator/RUNBOOK.md"

# --- Node stop/start and the validator, against a fake docker ---------------------
fake="${TMP}/fakebin"; dstate="${TMP}/docker"; mkdir -p "${fake}" "${dstate}"
cat > "${fake}/docker" <<'FAKE'
#!/usr/bin/env bash
D="${FAKE_DOCKER_STATE}"
name="${*: -1}"
case "$1" in
  info) exit 0 ;;
  inspect)
    if [[ "$2" == "-f" ]]; then cat "${D}/running-${name}" 2>/dev/null || echo false
    else [[ -e "${D}/exists-${name}" ]] && echo '[{}]' || exit 1; fi ;;
  stop) echo false > "${D}/running-${name}"; echo "stop ${name}" >> "${D}/calls" ;;
  start) echo true > "${D}/running-${name}"; echo "start ${name}" >> "${D}/calls" ;;
  compose) echo "compose ${*:2}" >> "${D}/calls" ;;
esac
FAKE
chmod +x "${fake}/docker"
node() {  # node() <script>: run a node script with the fake docker and temp validator paths
  PATH="${fake}:${PATH}" FAKE_DOCKER_STATE="${dstate}" VAL_DATA="${TMP}/data" \
    VAL_RESUME_FILE="${TMP}/resume" bash "$@" >/dev/null 2>&1
}
calls() { cat "${dstate}/calls" 2>/dev/null || true; }
: > "${dstate}/calls"; touch "${dstate}/exists-pulse-validator"; echo true > "${dstate}/running-pulse-validator"
node "${ROOT}/stop.sh"
[[ -e "${TMP}/resume" && "$(calls)" == "stop pulse-validator"$'\n'"compose down" ]] \
  && pass "stop.sh: validator stopped first and marked to come back" || fail "stop.sh order/marker wrong: $(calls | tr '\n' ';')"
: > "${dstate}/calls"; node "${ROOT}/start.sh"
[[ ! -e "${TMP}/resume" && "$(calls)" == *"start pulse-validator"* ]] \
  && pass "start.sh brings the validator back" || fail "start.sh should resume the validator: $(calls | tr '\n' ';')"
node "${VAL}/stop.sh"; node "${ROOT}/stop.sh"; : > "${dstate}/calls"; node "${ROOT}/start.sh"
[[ "$(calls)" != *"start pulse-validator"* ]] \
  && pass "a validator stopped on purpose stays down across a node stop/start" || fail "start.sh resumed a validator stopped on purpose"
: > "${dstate}/calls"; node "${VAL}/resume.sh"
[[ "$(calls)" == "start pulse-validator" ]] && pass "validator/resume.sh starts it again (no sudo)" || fail "resume.sh should start it: $(calls | tr '\n' ';')"
rm -f "${VAL_ENABLED}"; node "${ROOT}/stop.sh"; rm -f "${dstate}/exists-pulse-validator"; : > "${dstate}/calls"
if node "${VAL}/resume.sh"; then fail "resume.sh should refuse a switched-off validator"; else
  [[ -z "$(calls)" ]] && pass "resume.sh refuses a switched-off validator" || fail "resume.sh touched docker: $(calls)"; fi

# --- The pinned image accepts every flag we pass ------------------------------------
if [[ -n "${VALIDATOR_TEST_IMAGE:-}${CI:-}" ]] && command -v docker >/dev/null 2>&1; then
  if help="$(docker run --rm --platform linux/amd64 --network none "${VALIDATOR_IMAGE_PINNED}" --help 2>&1)"; then
    while read -r flag; do
      grep -qE -- "^\s+${flag}( |,)" <<<"${help}" && pass "image knows ${flag}" || fail "pinned image has no ${flag}"
    done < <(grep -oE -- '- --[a-z-]+' "${compose}" | awk '{print $2}' | sort -u)
  else
    fail "could not run the validator image: ${help}"
  fi
else
  echo "SKIP: flag check against the image (set VALIDATOR_TEST_IMAGE=1; always runs in CI)"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "One or more validator checks failed." >&2
  exit 1
fi
echo "All validator checks passed."
