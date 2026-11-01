#!/usr/bin/env bash
# Writes <value file> as a new version of a Key Vault secret (Set Secret, api-version
# 2025-07-01), with the access token in <token file>. The writer holds only
# `secrets/setSecret/action` on the vault, so it reads nothing back; the response, which echoes
# the value, is discarded. Exit 0 when the vault answers 200.
# Usage: set-secret.sh <vault url> <secret name> <token file> <value file> [<content type>]
set -euo pipefail

[[ $# -eq 4 || $# -eq 5 ]] || {
  printf 'usage: set-secret.sh <vault url> <secret name> <token file> <value file> [<content type>]\n' >&2
  exit 64
}
vault=$1 name=$2 token=$3 value=$4 content_type=${5:-application/pgp-keys}
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
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "${access}" >"${work}/header"
jq --raw-input --slurp --arg type "${content_type}" '{value: ., contentType: $type}' <"${value}" >"${work}/body"
status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --request PUT \
  --header @"${work}/header" --data-binary @"${work}/body" \
  "${vault%/}/secrets/${name}?api-version=2025-07-01")
[[ ${status} == 200 ]] || {
  printf 'Key Vault answered %s writing %s\n' "${status}" "${name}" >&2
  exit 75
}
