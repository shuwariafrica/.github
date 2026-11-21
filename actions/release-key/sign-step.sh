#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu runners under release-key's and crate-sign's steps (bash 5.2 or
# later, gpg 2.4, sqv), and a developer's Linux machine for its cases.
# The release-key action's sign step, which action.yml starts under `env -i`: signs each file FILES
# names, one per line with blank lines skipped, through sign.sh, as the subkey SUBKEY in the home
# GNUPGHOME, each signature naming REPOSITORY_REF (<repository id>:<ref>).
# Exit 64 when FILES names no file; sign.sh's codes pass through.
# shellcheck disable=SC2154 # FILES, GNUPGHOME, SUBKEY and REPOSITORY_REF are action.yml's env
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

self=$(realpath -- "${BASH_SOURCE[0]}")
here=$(dirname -- "${self}")
readonly here
: "${FILES?}" "${GNUPGHOME:?}" "${SUBKEY:?}" "${REPOSITORY_REF:?}"
listed=$(printf '%s\n' "${FILES}" | sed '/^[[:space:]]*$/d')
[[ -n ${listed} ]] || {
  printf '::error::sign names no file\n' >&2
  exit 64
}
mapfile -t files <<<"${listed}"
"${here}/sign.sh" "${GNUPGHOME}" "${SUBKEY}" "${REPOSITORY_REF}" "${files[@]}"
