#!/usr/bin/env bash
# Reads the latest version of a Key Vault secret (Get Secret, api-version 2025-07-01) with the
# access token in <token file>, and writes its value to <out>, mode 600. The value passes
# through a pipe alone, never an argument or the log.
# Usage: get-secret.sh <vault url> <secret name> <token file> <out>
#   e.g. get-secret.sh https://shuwari-release-signing.vault.azure.net c1-subkey ...
set -euo pipefail

[[ $# -eq 4 ]] || {
  printf 'usage: get-secret.sh <vault url> <secret name> <token file> <out>\n' >&2
  exit 64
}
vault=$1 name=$2 token=$3 out=$4
[[ ${name} =~ ^[0-9a-zA-Z-]+$ ]] || {
  printf 'a secret name is letters, digits and hyphens: %s\n' "${name}" >&2
  exit 64
}
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
access=$(<"${token}")
printf 'Authorization: Bearer %s\n' "${access}" >"${work}/header"
curl --fail-with-body --silent --show-error --header @"${work}/header" \
  "${vault%/}/secrets/${name}?api-version=2025-07-01" |
  jq --exit-status --join-output .value >"${work}/value"
install -m 600 "${work}/value" "${out}"
