#!/usr/bin/env bash
# cert_check.sh — cert_problems, shared by proxy/lib.sh and the certificate receiver (cert-push-receive.sh, which
# runs as root from a root-owned copy). Needs only openssl, grep and sed.
# shellcheck shell=bash

# covers_host <hostname> <SAN lines>: true if a DNS name in the SAN list is exactly <hostname>, or a wildcard for its
# parent (*.home.example covers rpc.home.example, but not a.rpc.home.example or home.example).
covers_host() {
  local host="$1" sans="$2" parent
  grep -qixF "DNS:${host}" <<<"${sans}" && return 0
  [[ "${host}" == *.*.* ]] || return 1  # a wildcard needs at least two labels under it
  parent="${host#*.}"
  grep -qixF "DNS:*.${parent}" <<<"${sans}"
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
  if ! covers_host "${host}" "${sans}"; then
    echo "the certificate is not issued for ${host} (it covers: $(tr '\n' ' ' <<<"${sans}" | sed 's/X509v3 Subject Alternative Name: *//'))"
  fi
  if ! openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1; then
    echo "the certificate has expired ($(openssl x509 -in "${cert}" -noout -enddate | cut -d= -f2))"
  fi
}
