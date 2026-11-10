#!/usr/bin/env bash
# The key-vault action's step, which action.yml starts under `env -i`. As the identity the job's
# environment federates to, it runs OPERATION on one Key Vault secret:
#   - get: the value into FILE, mode 600;
#   - set: FILE as a new version;
#   - absent: fails when the secret exists;
#   - token: the vault access token into FILE, mode 600.
# Every value it writes is registered with the runner's mask.
# Environment: OPERATION, TENANT_ID, CLIENT_ID, VAULT_URL, SECRET, FILE, RUNNER_TEMP and
# ACTIONS_ID_TOKEN_REQUEST_URL; the OIDC request token on descriptor 3, which token.sh takes as
# ACTIONS_ID_TOKEN_REQUEST_TOKEN.
# Exit 64 for an operation, vault URI or token it refuses; the scripts' own codes pass through.
# shellcheck disable=SC2154 # the variables above are action.yml's env
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
: "${OPERATION?}" "${TENANT_ID:?}" "${CLIENT_ID:?}" "${VAULT_URL:?}" "${SECRET?}" "${FILE?}" "${RUNNER_TEMP:?}"
case ${OPERATION} in
  get | set | absent | token) ;;
  *)
    printf '::error::operation is get, set, absent or token, not %s\n' "${OPERATION}" >&2
    exit 64
    ;;
esac
[[ ${VAULT_URL} =~ ^https://[a-z0-9-]+\.vault\.azure\.net/?$ ]] || {
  printf '::error::not a Key Vault URI: %s\n' "${VAULT_URL}" >&2
  exit 64
}
request=''
IFS= read -r -u 3 request || [[ -n ${request} ]] || {
  printf '::error::no OIDC request token on descriptor 3\n' >&2
  exit 64
}
exec 3<&-
[[ -n ${request} ]] || {
  printf '::error::the job needs permissions: id-token: write\n' >&2
  exit 64
}
export ACTIONS_ID_TOKEN_REQUEST_TOKEN="${request}"

token=$(mktemp -p "${RUNNER_TEMP}")
trap 'rm -f "${token}"' EXIT
"${here}/token.sh" "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  "${CLIENT_ID}" https://vault.azure.net/.default "${token}"
# A Key Vault value is no GitHub secret, so the runner masks nothing of it unasked: every line, and
# every string of a JSON value, is registered before any later step runs.
case ${OPERATION} in
  get)
    "${here}/get-secret.sh" "${VAULT_URL}" "${SECRET}" "${token}" "${FILE:?}"
    "${here}/mask.sh" "${FILE}"
    ;;
  set) "${here}/set-secret.sh" "${VAULT_URL}" "${SECRET}" "${token}" "${FILE:?}" ;;
  absent) "${here}/absent.sh" "${VAULT_URL}" "${SECRET}" "${token}" ;;
  token)
    install -m 600 "${token}" "${FILE:?}"
    "${here}/mask.sh" "${FILE}"
    ;;
  *) exit 64 ;; # refused above
esac
