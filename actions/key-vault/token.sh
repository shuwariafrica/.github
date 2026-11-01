#!/usr/bin/env bash
# Exchanges this job's GitHub OIDC token for an Entra access token through an identity's
# federated credential (Entra's client-credentials grant with a federated assertion,
# v2-oauth2-client-creds-grant-flow), and writes the access token to <out>, mode 600.
# The job needs `permissions: id-token: write`, which sets ACTIONS_ID_TOKEN_REQUEST_URL and
# ACTIONS_ID_TOKEN_REQUEST_TOKEN. No token or assertion is ever an argument of a command.
# Usage: token.sh <token endpoint> <client id> <scope> <out>
#   e.g. token.sh "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token" \
#          "${client_id}" https://vault.azure.net/.default "${RUNNER_TEMP}/vault.token"
set -euo pipefail

[[ $# -eq 4 ]] || {
  printf 'usage: token.sh <token endpoint> <client id> <scope> <out>\n' >&2
  exit 64
}
endpoint=$1 client_id=$2 scope=$3 out=$4
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?the job needs permissions: id-token: write}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?the job needs permissions: id-token: write}"
for tool in curl jq mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done

work=$(mktemp -d)
readonly work
trap 'rm -rf "${work}"' EXIT
umask 077

# Microsoft's audience for a federated credential (workload-identity-federation-considerations).
printf 'Authorization: bearer %s\n' "${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" >"${work}/request.header"
curl --fail-with-body --silent --show-error --get --header @"${work}/request.header" \
  --data-urlencode audience=api://AzureADTokenExchange "${ACTIONS_ID_TOKEN_REQUEST_URL}" |
  jq --exit-status --join-output .value >"${work}/assertion"

printf '%s' "${client_id}" >"${work}/client_id"
printf '%s' "${scope}" >"${work}/scope"
curl --fail-with-body --silent --show-error --request POST \
  --data-urlencode client_id@"${work}/client_id" \
  --data-urlencode scope@"${work}/scope" \
  --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode client_assertion@"${work}/assertion" \
  --data-urlencode grant_type=client_credentials \
  "${endpoint}" | jq --exit-status --join-output .access_token >"${work}/access"
install -m 600 "${work}/access" "${out}"
