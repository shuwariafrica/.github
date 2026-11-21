#!/usr/bin/env bash
# crate-sign's step between importing the key and signing: refuses the imported signing subkey
# SUBKEY when it is among REVOKED, the keys the check step read as revoked from the keyservers,
# separated by spaces.
# Exit 0 when it is not; 1 when it is; 64 when SUBKEY is not a fingerprint.
# shellcheck disable=SC2154 # SUBKEY and REVOKED are action.yml's env
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

: "${SUBKEY?}" "${REVOKED?}"
[[ ${SUBKEY} =~ ^[0-9A-F]{40}$ ]] || {
  printf '::error::the imported subkey is not a fingerprint: [%s]\n' "${SUBKEY}" >&2
  exit 64
}
read -ra revoked <<<"${REVOKED}"
for key in "${revoked[@]}"; do
  [[ ${key} != "${SUBKEY}" ]] || {
    printf '::error::the keyservers publish the signing subkey %s as revoked\n' "${SUBKEY}" >&2
    exit 1
  }
done
printf 'the signing subkey %s is not revoked\n' "${SUBKEY}"
