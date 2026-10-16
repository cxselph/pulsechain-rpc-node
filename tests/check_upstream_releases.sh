#!/usr/bin/env bash
# Report when PulseChain publishes a client release newer than our digest pins.
# Dependabot cannot follow these images (GitLab registry, defaults inside
# ${VAR:-...} interpolation), so the weekly workflow runs this instead.
# It only reports. Bumping a pin is a reviewed PR, preferably once the
# release has been public for about 14 days.
# Exit 0 = pins are current, 1 = a newer release exists, 2 = lookup failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
# shellcheck disable=SC1091
source "${ROOT}/common.sh"

# Prints "<tag> <released_at>" for the newest GitLab release of a project.
latest_release() {
  python3 - "$1" <<'PY'
import json, sys, urllib.parse, urllib.request

project = urllib.parse.quote(sys.argv[1], safe="")
url = f"https://gitlab.com/api/v4/projects/{project}/releases?per_page=1&order_by=released_at"
with urllib.request.urlopen(url, timeout=20) as r:
    releases = json.load(r)
if not releases:
    raise SystemExit("no releases")
print(releases[0]["tag_name"], releases[0]["released_at"][:10])
PY
}

# registry.gitlab.com/group/name:tag@sha256:... -> tag
pinned_tag() {
  local ref="${1%@*}"
  printf '%s\n' "${ref##*:}"
}

STATUS=0
check() {
  local label="$1" project="$2" pinned="$3"
  local out tag released tag_pinned
  tag_pinned="$(pinned_tag "${pinned}")"
  if ! out="$(latest_release "${project}")"; then
    echo "ERROR: could not read releases for ${project}" >&2
    STATUS=2
    return
  fi
  read -r tag released <<< "${out}"
  if [[ "${tag}" == "${tag_pinned}" ]]; then
    echo "OK: ${label} pinned to ${tag_pinned}, the newest release (${released})"
  else
    echo "UPDATE: ${label} ${tag} was released ${released}; we pin ${tag_pinned}."
    echo "        Read the release notes, then bump the digest pin in docker-compose.yml and common.sh in a PR."
    [[ "${STATUS}" -eq 0 ]] && STATUS=1
  fi
}

check go-pulse pulsechaincom/go-pulse "${GETH_IMAGE_PINNED}"
check prysm-pulse pulsechaincom/prysm-pulse "${BEACON_IMAGE_PINNED}"
exit "${STATUS}"
