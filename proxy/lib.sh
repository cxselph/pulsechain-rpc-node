#!/usr/bin/env bash
# lib.sh — shared helpers for the HTTPS front end scripts
# shellcheck shell=bash

PROXY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${PROXY_DIR}/../common.sh"

# shellcheck disable=SC2034  # used by the scripts that source this file
{
PROXY_ENV="${PROXY_DIR}/.env"
PROXY_TLS_DIR=/etc/pulse-proxy/tls
CADDY_CONTAINER=pulse-caddy
}

proxy_compose() {
  run_docker compose -f "${PROXY_DIR}/docker-compose.yml" --project-directory "${PROXY_DIR}" "$@"
}

# PUBLIC_HOSTNAME from proxy/.env (empty if unset). Does not execute the file.
proxy_hostname() {
  local line
  [[ -f "${PROXY_ENV}" ]] || return 0
  line="$(grep -E '^[[:space:]]*PUBLIC_HOSTNAME[[:space:]]*=' "${PROXY_ENV}" | tail -n 1 || true)"
  line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
  _trim "${line}"
}

# cert_problems <cert> <key> <hostname>: prints one line per problem, nothing if the
# pair is usable (parses, matches, covers the hostname, not expired).
cert_problems() {
  local cert="$1" key="$2" host="$3" sans
  if ! openssl x509 -in "${cert}" -noout 2>/dev/null; then
    echo "certificate ${cert} is not a PEM certificate"
    return 0
  fi
  if ! openssl pkey -in "${key}" -noout 2>/dev/null; then
    echo "key ${key} is not a PEM private key"
    return 0
  fi
  if [[ "$(openssl x509 -in "${cert}" -noout -pubkey)" != "$(openssl pkey -in "${key}" -pubout)" ]]; then
    echo "the key does not belong to the certificate"
  fi
  sans="$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//')"
  if ! grep -qxF "DNS:${host}" <<<"${sans}"; then
    echo "the certificate is not issued for ${host} (it covers: $(tr '\n' ' ' <<<"${sans}" | sed 's/X509v3 Subject Alternative Name: *//'))"
  fi
  if ! openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1; then
    echo "the certificate has expired ($(openssl x509 -in "${cert}" -noout -enddate | cut -d= -f2))"
  fi
}

# proxy_checks <hostname>: exercise every route through 127.0.0.1:443 and print
# one "ok|FAIL|skip <what>" line each. Returns 1 if anything failed.
proxy_checks() {
  local host="$1" failed=0 code body served installed
  local base="https://${host}"
  local -a c=(curl -sS -m 10 -k --resolve "${host}:443:127.0.0.1")
  # -k: the CA lives on your own devices, not here. The served certificate is
  # compared with the installed one by fingerprint instead.
  served="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "${host}" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
  installed="$(openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -fingerprint -sha256 2>/dev/null || ${SUDO:-} openssl x509 -in "${PROXY_TLS_DIR}/cert.pem" -noout -fingerprint -sha256 2>/dev/null || true)"
  if [[ -n "${served}" && "${served}" == "${installed}" ]]; then
    echo "ok   serves the installed certificate for ${host}"
  else
    echo "FAIL serving a different (or no) certificate for ${host}"; failed=1
  fi

  body="$("${c[@]}" -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "${base}/" || true)"
  if [[ "${body}" == *'"result":"0x171"'* ]]; then
    echo "ok   wallet RPC  POST ${base}  -> chain 369"
  else
    echo "FAIL wallet RPC  POST ${base}  -> ${body:-no answer}"; failed=1
  fi

  code="$("${c[@]}" -o /dev/null -w '%{http_code}' --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --max-time 3 "${base}/" 2>/dev/null || true)"
  if [[ "${code}" == 101* ]]; then
    echo "ok   wallet WebSocket wss://${host} -> 101 Switching Protocols"
  else
    echo "FAIL wallet WebSocket wss://${host} -> HTTP ${code:-none}"; failed=1
  fi

  body="$("${c[@]}" "${base}/" || true)"
  if [[ "${body}" == *"https://${host}"* ]]; then
    echo "ok   landing page ${base}/"
  else
    echo "FAIL landing page ${base}/"; failed=1
  fi

  if curl -fsS -m 3 http://127.0.0.1:3000/grafana/api/health >/dev/null 2>&1; then
    code="$("${c[@]}" -o /dev/null -w '%{http_code}' "${base}/grafana/api/health" || true)"
    if [[ "${code}" == "200" ]]; then
      echo "ok   Grafana ${base}/grafana/"
    else
      echo "FAIL Grafana ${base}/grafana/ -> HTTP ${code}"; failed=1
    fi
  else
    echo "skip Grafana (monitoring not running)"
  fi

  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "${host}:80:127.0.0.1" "http://${host}/x?y=1" || true)"
  if [[ "${code}" == "308 https://${host}/x?y=1" ]]; then
    echo "ok   http://${host} redirects to https"
  else
    echo "FAIL http://${host} redirect -> ${code}"; failed=1
  fi
  return "${failed}"
}
