#!/usr/bin/env bash
# Exit 0 when a Key Vault secret does not exist (Get Secret answers 404), 1 when it does, and 75
# for any other answer, so a job that must create a secret once refuses a second run.
# Usage: absent.sh <vault url> <secret name> <token file>
set -euo pipefail

[[ $# -eq 3 ]] || {
  printf 'usage: absent.sh <vault url> <secret name> <token file>\n' >&2
  exit 64
}
vault=$1 name=$2 token=$3
[[ ${name} =~ ^[0-9a-zA-Z-]+$ ]] || {
  printf 'a secret name is letters, digits and hyphens: %s\n' "${name}" >&2
  exit 64
}
command -v curl >/dev/null 2>&1 || {
  printf 'curl not found\n' >&2
  exit 69
}
work=$(mktemp -d)
readonly work
trap 'rm -rf "${work}"' EXIT
umask 077
access=$(<"${token}")
printf 'Authorization: Bearer %s\n' "${access}" >"${work}/header"
status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --header @"${work}/header" \
  "${vault%/}/secrets/${name}?api-version=2025-07-01")
case "${status}" in
  404) exit 0 ;;
  200)
    printf '%s already exists in %s\n' "${name}" "${vault}" >&2
    exit 1
    ;;
  *)
    printf 'Key Vault answered %s reading %s\n' "${status}" "${name}" >&2
    exit 75
    ;;
esac
