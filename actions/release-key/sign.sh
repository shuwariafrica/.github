#!/usr/bin/env bash
# Signs each file with C1's signing subkey (a detached, armoured <file>.asc) carrying the notation
# repository-ref@shuwari.africa=<notation>, the repository id and ref of the run that signs, so that
# no signature C1 makes for one run verifies as another's. Then verifies every signature through
# verify.sh before the job publishes anything. Exit 0 only when gpg and sqv both verify every
# signature. Usage: sign.sh <gnupghome> <subkey fingerprint> <repository id>:<ref> <file>...
set -euo pipefail

[[ $# -ge 4 ]] || {
  printf 'usage: sign.sh <gnupghome> <subkey fingerprint> <repository id>:<ref> <file>...\n' >&2
  exit 64
}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
home=$1 subkey=$2 notation=$3
shift 3
[[ ${notation} =~ ^[1-9][0-9]*:refs/(tags|heads)/[^[:space:]]+$ ]] || {
  printf 'not a repository id and ref: %s\n' "${notation}" >&2
  exit 64
}
command -v gpg >/dev/null 2>&1 || {
  printf 'gpg not found\n' >&2
  exit 69
}
for file in "$@"; do
  gpg --homedir "${home}" --batch --yes --pinentry-mode loopback --passphrase '' \
    --sig-notation "repository-ref@shuwari.africa=${notation}" \
    --local-user "${subkey}!" --armor --detach-sign --output "${file}.asc" "${file}"
done
"${here}/verify.sh" home "${home}" "${subkey}" "${notation}" "$@"
printf 'signed: %d files\n' "$#"
