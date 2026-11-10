#!/usr/bin/env bash
# The release-key action's sign step, which action.yml starts under `env -i`: signs each file FILES
# names, one per line with blank lines skipped, through sign.sh, as the subkey SUBKEY in the home
# GNUPGHOME, each signature naming REPOSITORY_REF (<repository id>:<ref>).
# Exit 64 when FILES names no file; sign.sh's codes pass through.
# shellcheck disable=SC2154 # FILES, GNUPGHOME, SUBKEY and REPOSITORY_REF are action.yml's env
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
: "${FILES?}" "${GNUPGHOME:?}" "${SUBKEY:?}" "${REPOSITORY_REF:?}"
listed=$(printf '%s\n' "${FILES}" | sed '/^[[:space:]]*$/d')
[[ -n ${listed} ]] || {
  printf '::error::sign names no file\n' >&2
  exit 64
}
mapfile -t files <<<"${listed}"
"${here}/sign.sh" "${GNUPGHOME}" "${SUBKEY}" "${REPOSITORY_REF}" "${files[@]}"
