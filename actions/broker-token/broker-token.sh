#!/usr/bin/env bash
# The broker-token action's step: asks GitHub for this job's OIDC token addressed to the broker, then
# asks the broker for an installation token of APP, narrowed to PERMISSIONS when given, and writes it
# masked to the step's `token` output. The job needs `permissions: id-token: write` and an
# `environment:`; no token passes through an argument list. Exits 1 with the broker's refusal code,
# and 2 when curl or jq is missing.
set -euo pipefail

readonly AUDIENCE=urn:shuwariafrica:token-broker
# Each request's bound: a stalled endpoint fails the step instead of holding the job to its timeout.
readonly TIMEOUT_SECONDS=30

fail() {
  printf '::error title=broker-token::%s\n' "$1"
  exit 1
}

main() {
  local tool oidc status refusal token summary
  for tool in curl jq; do
    command -v "${tool}" >/dev/null 2>&1 || {
      printf '::error title=broker-token::%s is required\n' "${tool}"
      exit 2
    }
  done
  : "${APP:?the app input of the action}"
  [[ -n "${BROKER_URL:-}" ]] || fail "no broker URL: pass broker-url, the organisation variable vars.TOKEN_BROKER_URL"
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] ||
    fail "this job cannot request an OIDC token: it needs permissions: id-token: write"
  : "${GITHUB_OUTPUT:?the step output file of the runner}"

  work=$(mktemp -d)
  trap 'rm -rf -- "${work}"' EXIT
  umask 077

  printf 'Authorization: bearer %s\n' "${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" >"${work}/request-header"
  curl -fsS --max-time "${TIMEOUT_SECONDS}" -H @"${work}/request-header" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" >"${work}/oidc.json" ||
    fail "GitHub refused this job an OIDC token"
  oidc=$(jq -er '.value | select(type == "string" and length > 0)' "${work}/oidc.json") ||
    fail "GitHub answered with no OIDC token"
  printf '::add-mask::%s\n' "${oidc}"
  printf 'Authorization: Bearer %s\n' "${oidc}" >"${work}/broker-header"
  unset oidc

  if [[ -n "${PERMISSIONS:-}" ]]; then
    jq -cn --arg app "${APP}" --argjson permissions "${PERMISSIONS}" '{app: $app, permissions: $permissions}' >"${work}/request.json" ||
      fail "permissions is not a JSON object: ${PERMISSIONS}"
  else
    jq -cn --arg app "${APP}" '{app: $app}' >"${work}/request.json"
  fi

  curl -sS --max-time "${TIMEOUT_SECONDS}" -o "${work}/response.json" -w '%{http_code}' -X POST -H @"${work}/broker-header" \
    -H 'Content-Type: application/json' --data @"${work}/request.json" "${BROKER_URL}" >"${work}/status" ||
    fail "the broker at ${BROKER_URL} did not answer within ${TIMEOUT_SECONDS} s"
  status=$(<"${work}/status")
  if [[ "${status}" != 200 ]]; then
    refusal=$(jq -r '"\(.refused // "unknown"): \(.reason // "no reason given")"' "${work}/response.json" || printf 'unreadable')
    fail "refused, ${status} ${refusal}"
  fi

  token=$(jq -er '.token | select(type == "string" and length > 0)' "${work}/response.json") ||
    fail "the broker answered 200 with no token"
  printf '::add-mask::%s\n' "${token}"
  printf 'token=%s\n' "${token}" >>"${GITHUB_OUTPUT}"
  summary=$(jq -c '{permissions, repositories: (.repository_ids | length), expires_at}' "${work}/response.json")
  printf 'broker-token: %s for %s\n' "${APP}" "${summary}"
}

main "$@"
