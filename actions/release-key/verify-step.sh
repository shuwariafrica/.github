#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu runners under release-key/verify's step (bash 5.2 or later, gpg
# 2.4, sqv), and a developer's Linux machine for its cases.
# The release-key/verify action's step, which verify/action.yml starts under `env -i`: verifies every
# <file>.asc under DIRECTORY through verify.sh.
#   - With RELEASE_HOME, the home form: against that home's key, by SUBKEY, each signature naming
#     REPOSITORY_REF, or carrying no notation when REPOSITORY_REF is empty.
#   - Without it, the certificate form: against C1's certificate at this commit's
#     signing/c1-public.asc, merged with what published.sh fetches for it, each signature naming
#     REPOSITORY_REF (<repository id>:<ref>).
# Environment: RELEASE_HOME, SUBKEY, DIRECTORY, REPOSITORY_REF and RUNNER_TEMP.
# Exit 66 when DIRECTORY holds no signature; 64 for a REPOSITORY_REF the certificate form refuses;
# verify.sh's and published.sh's codes pass through.
# shellcheck disable=SC2154 # the variables above are verify/action.yml's env
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
: "${RELEASE_HOME?}" "${SUBKEY?}" "${DIRECTORY:?}" "${REPOSITORY_REF?}" "${RUNNER_TEMP:?}"
work=$(mktemp -d -p "${RUNNER_TEMP}")
readonly work
trap 'rm -rf -- "${work}"' EXIT
find "${DIRECTORY}" -type f -name '*.asc' -print0 >"${work}/signatures"
mapfile -d '' -t signatures <"${work}/signatures"
((${#signatures[@]} > 0)) || {
  printf '::error::no signature under %s\n' "${DIRECTORY}" >&2
  exit 66
}
if [[ -n ${RELEASE_HOME} ]]; then
  : "${SUBKEY:?the home form takes the subkey too}"
  "${here}/verify.sh" home "${RELEASE_HOME}" "${SUBKEY}" "${REPOSITORY_REF:--}" "${signatures[@]%.asc}"
else
  [[ ${REPOSITORY_REF} =~ ^[1-9][0-9]*:refs/(tags|heads)/[^[:space:]]+$ ]] || {
    printf '::error::the certificate form takes the <repository id>:<ref> each signature names, not [%s]\n' "${REPOSITORY_REF}" >&2
    exit 64
  }
  # This commit's root of .github: actions/release-key is two directories below it.
  certificate="${here}/../../signing/c1-public.asc"
  mkdir "${work}/published"
  "${here}/published.sh" "${certificate}" "${work}/published"
  "${here}/verify.sh" certificate "${certificate}" "${work}/published" "${REPOSITORY_REF}" "${signatures[@]%.asc}"
fi
