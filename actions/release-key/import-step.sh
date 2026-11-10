#!/usr/bin/env bash
# The release-key action's import step, which action.yml starts under `env -i`. It reads C1's
# subkey-only export from Key Vault as the identity `release` federates to, registers every line of
# it with the runner's mask before any later step runs, imports it into RUNNER_TEMP/release-gnupg
# through import-key.sh, and writes `gnupghome` and `subkey` to GITHUB_OUTPUT.
# Environment: TENANT_ID, CLIENT_ID, VAULT_URL, FINGERPRINT, RUNNER_TEMP, GITHUB_OUTPUT and
# ACTIONS_ID_TOKEN_REQUEST_URL; the OIDC request token on descriptor 3, which token.sh takes as
# ACTIONS_ID_TOKEN_REQUEST_TOKEN.
# Exit 64 for a vault URI or token it refuses; the key-vault scripts' and import-key.sh's codes pass
# through.
# shellcheck disable=SC2154 # the variables above are action.yml's env
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${VAULT_URL:?}" "${FINGERPRINT:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}"
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

kv="${here}/../key-vault"
token=$(mktemp -p "${RUNNER_TEMP}")
export_file=$(mktemp -p "${RUNNER_TEMP}")
trap 'rm -f "${token}" "${export_file}"' EXIT
"${kv}/token.sh" "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  "${CLIENT_ID}" https://vault.azure.net/.default "${token}"
"${kv}/get-secret.sh" "${VAULT_URL}" c1-subkey "${token}" "${export_file}"
# A Key Vault value is no GitHub secret, so the runner masks nothing of it unasked: every line of the
# export is registered before any later step runs.
"${kv}/mask.sh" "${export_file}"
home="${RUNNER_TEMP}/release-gnupg"
subkey=$("${here}/import-key.sh" "${export_file}" "${FINGERPRINT}" "${home}")
printf 'gnupghome=%s\nsubkey=%s\n' "${home}" "${subkey}" >>"${GITHUB_OUTPUT}"
printf 'release key: C1 %s, signing subkey %s\n' "${FINGERPRINT}" "${subkey}"
