#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-publish's step (bash 5.3, curl, jq),
# and a developer's Linux machine for its cases.
# crate-publish's second step, the one that holds a crates.io token. It holds SHA256SUMS to DIGEST
# again, exchanges the job's OIDC token (audience crates.io) once for a crates.io token, registers
# both with the runner's mask before anything else is written, PUTs each body PUBLISH names, in
# order, each first checked against SHA256SUMS, waits for the index to hold each with its signed
# digest before the next, and revokes the token from its EXIT trap, so the token never leaves this
# step. Every token goes in a header file, never an argument.
# Environment: DIRECTORY, DIGEST, VERSION, PUBLISH (a JSON array of crate names), CRATES_IO, INDEX,
# RUNNER_TEMP and ACTIONS_ID_TOKEN_REQUEST_URL; the OIDC request token on descriptor 3. The index
# is read every ten seconds for ten minutes.
# Exit 0 when every crate is published; 1 refused, crates.io's refusal of a body (a 4xx other than
# 401, 403 or 429) included, which no re-run undoes; 64 for an invocation it refuses; 69 for an
# absent tool; 75 when crates.io or GitHub did not take a request and a re-run may, crates.io's
# refusal of the token (401 or 403) included: the token lives 30 minutes, the wait for the index
# after each crate can outlast it, and a re-run takes a new one and skips what is published.
# shellcheck disable=SC2153,SC2154 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

# A request of <method> to crates.io's <path> with the body <data> (a file, or - for none), the
# token's header from its file; its answer into <out>, the status printed.
crates_send() {
  local method=$1 path=$2 data=$3 out=$4 code
  local -a body=()
  [[ ${data} == - ]] || body=(--data-binary "@${data}")
  code=$(curl --silent --show-error --max-time 300 --user-agent "${AGENT}" --output "${out}" --write-out '%{http_code}' \
    --header @"${WORK}/token.header" --request "${method}" "${body[@]}" "${CRATES_IO}${path}") || code=000
  printf '%s' "${code}"
}

# What crates.io's answer <file> says: the detail of each of its errors, else its first 1000 bytes.
said() {
  local detail
  detail=$(jq -r '[.errors[]?.detail | strings] | join("; ")' "$1" 2>/dev/null) ||
    detail='' # an answer that is not crates.io's JSON is shown as it is, below
  [[ -n ${detail} ]] || detail=$(head -c 1000 -- "$1")
  printf '%s' "${detail//$'\n'/ }"
}

TOKEN=no

revoke() {
  local code
  [[ ${TOKEN} == yes ]] || return 0
  api_pace "${WORK}/clock"
  code=$(crates_send DELETE /api/v1/trusted_publishing/tokens - "${WORK}/revoked")
  date +%s%N >"${WORK}/clock"
  TOKEN=no
  if [[ ${code} == 204 ]]; then
    printf 'revoked the crates.io token\n'
  else
    printf '::warning::the crates.io token was not revoked (%s); it lapses within 30 minutes\n' "${code}"
  fi
}

# The job's OIDC token for audience crates.io, exchanged once for a crates.io token whose header
# goes to WORK/token.header.
exchange() {
  local request=$1 code oidc token
  (
    umask 077
    printf 'Authorization: bearer %s\n' "${request}" >"${WORK}/request.header"
  )
  code=$(fetch "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=crates.io" "${WORK}/oidc" --header @"${WORK}/request.header")
  rm -f -- "${WORK}/request.header"
  [[ ${code} == 200 ]] || unreadable "GitHub gave no OIDC token (${code})"
  oidc=$(jq -er '.value' "${WORK}/oidc")
  rm -f -- "${WORK}/oidc"
  printf '::add-mask::%s\n' "${oidc}"
  (
    umask 077
    jq -Rc '{jwt: .}' <<<"${oidc}" >"${WORK}/exchange.json"
  )
  api_pace "${WORK}/clock"
  code=$(curl --silent --show-error --max-time 60 --user-agent "${AGENT}" --output "${WORK}/exchanged" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' --data-binary "@${WORK}/exchange.json" \
    "${CRATES_IO}/api/v1/trusted_publishing/tokens") || code=000
  date +%s%N >"${WORK}/clock"
  rm -f -- "${WORK}/exchange.json"
  [[ ${code} == 200 ]] || {
    rm -f -- "${WORK}/exchanged"
    unreadable "crates.io refused the exchange (${code})"
  }
  token=$(jq -er '.token' "${WORK}/exchanged")
  rm -f -- "${WORK}/exchanged"
  printf '::add-mask::%s\n' "${token}"
  (
    umask 077
    printf 'Authorization: %s\n' "${token}" >"${WORK}/token.header"
  )
  TOKEN=yes
}

main() {
  local self here request crates crate body digest line found held wait code message
  local -a names
  : "${DIRECTORY:?}" "${DIGEST:?}" "${VERSION:?}" "${PUBLISH:?}" "${CRATES_IO:?}" "${INDEX:?}" "${RUNNER_TEMP:?}"
  self=$(realpath -- "${BASH_SOURCE[0]}")
  here=$(dirname -- "${self}")
  # shellcheck source=actions/crate-publish/lib.sh
  source "${here}/lib.sh"
  tools curl jq awk head sha256sum realpath mktemp date sleep
  request=''
  IFS= read -r -u 3 request || [[ -n ${request} ]] || {
    printf '::error::no OIDC request token on descriptor 3\n' >&2
    exit 64
  }
  exec 3<&-
  [[ -n ${request} && -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]] || {
    printf '::error::the job needs permissions: id-token: write\n' >&2
    exit 64
  }
  crates=$(jq -r '.[]' <<<"${PUBLISH}")
  mapfile -t names <<<"${crates}"
  [[ -n ${crates} ]] || die "nothing to publish"
  found=$(sha256sum -- "${DIRECTORY}/SHA256SUMS")
  [[ ${found%% *} == "${DIGEST}" ]] || die "SHA256SUMS is ${found%% *}, and package made ${DIGEST}"
  WORK=$(mktemp -d -p "${RUNNER_TEMP}")
  trap '((BASHPID == '"${BASHPID}"')) && revoke; rm -rf -- "'"${WORK}"'"' EXIT
  exchange "${request}"
  request=''
  for crate in "${names[@]}"; do
    body=${crate}-${VERSION}.upload
    line=$(awk -v f="${body}" '{name = $2; sub(/^\*/, "", name); if (name == f) print $1 "  " name}' "${DIRECTORY}/SHA256SUMS")
    [[ -n ${line} ]] || die "SHA256SUMS names no ${body}"
    (cd -- "${DIRECTORY}" && sha256sum --check --strict --quiet <<<"${line}") || die "${body} is not the body SHA256SUMS signed"
    api_pace "${WORK}/clock"
    code=$(crates_send PUT /api/v1/crates/new "${DIRECTORY}/${body}" "${WORK}/answer")
    date +%s%N >"${WORK}/clock"
    [[ ${code} == 200 ]] || message=$(said "${WORK}/answer")
    case ${code} in
      200) ;;
      429 | 000 | 5??) unreadable "crates.io did not take ${crate} ${VERSION} (${code}): ${message}" ;;
      401 | 403) unreadable "crates.io refused the token for ${crate} ${VERSION} (${code}): ${message}: a re-run takes a new token and skips the crates already published" ;;
      4??) die "crates.io refused ${crate} ${VERSION} (${code}): ${message}: a re-run is refused the same way, and only a new version completes the release" ;;
      *) unreadable "crates.io answered ${code} for ${crate} ${VERSION}: ${message}" ;;
    esac
    digest=$(awk -v f="${crate}-${VERSION}.crate" '{name = $2; sub(/^\*/, "", name); if (name == f) print $1}' "${DIRECTORY}/SHA256SUMS")
    wait=0
    held=$(index_digest "${crate}" "${VERSION}" "${WORK}")
    while [[ ${held} != "${digest}" ]]; do
      ((wait < 600)) || unreadable "the index does not show ${crate} ${VERSION} after ${wait} seconds"
      sleep 10
      wait=$((wait + 10))
      held=$(index_digest "${crate}" "${VERSION}" "${WORK}")
    done
    printf 'published %s %s\n' "${crate}" "${VERSION}"
  done
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
