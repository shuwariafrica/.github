#!/usr/bin/env bash
# Imports C1's subkey-only export into a new GNUPGHOME and proves it is the published key: one
# secret key whose primary is a stub (no secret material), whose fingerprint is <fingerprint>,
# with exactly one usable signing subkey. Prints that subkey's fingerprint. A release job signs
# only after this succeeds, so a wrong or swapped export fails before any artefact is signed.
# Usage: import-key.sh <subkey export> <fingerprint> <gnupghome>
set -euo pipefail

[[ $# -eq 3 ]] || {
  printf 'usage: import-key.sh <subkey export> <fingerprint> <gnupghome>\n' >&2
  exit 64
}
export_file=$1 expected=${2^^} home=$3
[[ ${expected} =~ ^[0-9A-F]{40}$ ]] || {
  printf 'a v4 fingerprint is 40 hexadecimal digits: %s\n' "${expected}" >&2
  exit 64
}
for tool in gpg awk; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
[[ ! -e ${home} ]] || {
  printf '%s exists; a release key goes into a new home\n' "${home}" >&2
  exit 64
}
mkdir -m 700 "${home}"
gpg --homedir "${home}" --batch --quiet --import "${export_file}" 2>/dev/null
colons=$(gpg --homedir "${home}" --batch --with-colons --list-secret-keys)
# sec field 15 '#' is a stub; ssb field 12 the capabilities, field 2 the validity ('e' expired,
# 'r' revoked), field 15 '#' a subkey without its secret.
summary=$(awk -F: '
  $1 == "sec" { secs++; stub = ($15 == "#") }
  $1 == "fpr" && !primary { primary = $10 }
  $1 == "ssb" && $12 ~ /s/ && $2 != "e" && $2 != "r" && $15 != "#" { signers++; want = 1; next }
  $1 == "fpr" && want { subkey = $10; want = 0 }
  END { printf "%d %d %d %s %s\n", secs, stub, signers, primary, subkey }' <<<"${colons}")
read -r secs stub signers primary subkey <<<"${summary}"
if [[ ${secs} != 1 || ${stub} != 1 || ${signers} != 1 ]]; then
  printf 'the export is not one stub primary with one signing subkey (keys %s, stub %s, signing subkeys %s)\n' \
    "${secs}" "${stub}" "${signers}" >&2
  exit 65
fi
[[ ${primary} == "${expected}" ]] || {
  printf 'the export'"'"'s primary is %s, not the published %s\n' "${primary}" "${expected}" >&2
  exit 65
}
printf '%s\n' "${subkey}"
