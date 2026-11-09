#!/usr/bin/env bash
# host-report-receive.sh — forced command for the host-report SSH key
# (installed by host-report-setup.sh).
# The hypervisor pipes its read-only health report in; this stores it for the
# control page and does nothing else. sshd runs it for every connection with
# that key, whatever command the client asked for.
set -euo pipefail
DIR="${HOST_REPORT_DIR:-/var/lib/node-control/host-report}"
MAX_BYTES=262144

tmp="$(mktemp "${DIR}/.report.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
# Cap the size and drop control characters (terminal escapes included); keep
# tabs, newlines and UTF-8 text. The page also escapes it as HTML.
head -c "${MAX_BYTES}" | LC_ALL=C tr -d '\000-\010\013-\037\177' > "${tmp}"
if [[ ! -s "${tmp}" ]]; then
  echo "host-report: empty report, kept the previous one" >&2
  exit 1
fi
chmod 0644 "${tmp}"
mv -f "${tmp}" "${DIR}/report.txt"
trap - EXIT
echo "host-report: stored $(wc -c < "${DIR}/report.txt") bytes"
