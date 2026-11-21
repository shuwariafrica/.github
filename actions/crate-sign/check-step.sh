#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-sign's step (bash 5.3, git, gpg 2.4,
# curl, jq, yq), and a developer's Linux machine for its cases.
# crate-sign's first step, before any key is read. The run is release.yml's on the tag's push; that
# file at the run's commit, read through the API as data, runs only actions at commits the release
# holds them to (pins.sh), judged against this action's own commit and public-crates' gate-commit
# at main's head, and is the project's lifted template exactly (lib.sh's release_yml_holds, the rule
# action.yml states); SHA256SUMS in DIRECTORY is crate-package's, by DIGEST, and every file it names
# matches; the project of projects.json has a signing key, whose certificate in signing-keys/ is
# held to it, whose primary no keyserver publishes as revoked, and which keys.openpgp.org serves.
# Environment: REPOSITORY, REPOSITORY_ID, REF, SHA, WORKFLOW_REF (the run's), DIRECTORY, DIGEST,
# API, GIT_BASE, RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_ACTION_PATH; the job's token on descriptor 3.
# Writes fingerprint (the signing key's primary) and revoked (the keys the keyservers publish as
# revoked, separated by spaces) to GITHUB_OUTPUT.
# Exit 0 when the release may be signed; 1 refused; 64 for a token it refuses; 69 for an absent
# tool; 75 when something could not be read.
# shellcheck disable=SC2153,SC2154 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

# release.yml at the run's commit into <out>, read through the API with the job's token.
workflow_file() {
  local out=$1 code
  code=$(fetch "${API}/repos/${REPOSITORY}/contents/.github/workflows/release.yml?ref=${SHA}" "${out}" \
    --header @"${WORK}/authorization" --header 'Accept: application/vnd.github.raw+json')
  [[ ${code} == 200 ]] || unreadable "GitHub answered ${code} for release.yml at ${SHA}"
}

main() {
  local self here request own gate project fingerprint name revoked departures rc=0 found
  : "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${REF:?}" "${SHA:?}" "${WORKFLOW_REF:?}" "${DIRECTORY:?}" "${DIGEST:?}"
  : "${API:?}" "${GIT_BASE:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_ACTION_PATH:?}"
  self=$(realpath -- "${BASH_SOURCE[0]}")
  here=$(dirname -- "${self}")
  # shellcheck source=actions/crate-publish/lib.sh
  source "${here}/../crate-publish/lib.sh"
  # shellcheck source=actions/crate-sign/pins.sh
  source "${here}/pins.sh"
  tools git gpg gpgconf curl jq yq awk sed cmp sha256sum realpath
  request=''
  IFS= read -r -u 3 request || [[ -n ${request} ]] || {
    printf '::error::no token on descriptor 3\n' >&2
    exit 64
  }
  exec 3<&-
  [[ -n ${request} ]] || {
    printf '::error::the job has no token\n' >&2
    exit 64
  }
  WORK=$(mktemp -d -p "${RUNNER_TEMP}")
  trap '((BASHPID == '"${BASHPID}"')) && stop_homes "'"${WORK}"'" && rm -rf -- "'"${WORK}"'"' EXIT
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "${request}" >"${WORK}/authorization"
  )
  request=''

  [[ ${WORKFLOW_REF} == "${REPOSITORY}/.github/workflows/release.yml@${REF}" && ${REF} == refs/tags/v* ]] ||
    die "this run is ${WORKFLOW_REF}, not ${REPOSITORY}'s release.yml on a v tag"
  [[ ${SHA} =~ ^[0-9a-f]{40}$ && ${DIGEST} =~ ^[0-9a-f]{64}$ ]] || die "the run's commit or package's digest is malformed"
  own=$(own_commit "${GITHUB_ACTION_PATH}" crate-sign)
  workflow_file "${WORK}/release.yml"
  catalogue "${WORK}/public-crates" >/dev/null
  project=$(project_of "${WORK}/public-crates" "${REPOSITORY}" "${REPOSITORY_ID}")
  gate=$(catalogue_file "${WORK}/public-crates" gate-commit)
  gate=${gate//[[:space:]]/}
  [[ ${gate} =~ ^[0-9a-f]{40}$ ]] || die "public-crates' gate-commit names no full commit"
  # shellcheck disable=SC2310
  # pins_hold's status is its answer, and it dies on what it cannot read.
  departures=$(pins_hold "${WORK}/release.yml" "${own}" "${gate}" "${here}/../third-party.tsv") || rc=$?
  ((rc == 0)) || die "release.yml runs what the release does not hold: ${departures//$'\n'/; }"
  release_yml_holds "${WORK}/release.yml" "${WORK}/public-crates" "${gate}" "${own}" "${project}" "${WORK}/lifted.yml"

  [[ -f ${DIRECTORY}/SHA256SUMS ]] || die "${DIRECTORY} holds no SHA256SUMS"
  found=$(sha256sum -- "${DIRECTORY}/SHA256SUMS")
  [[ ${found%% *} == "${DIGEST}" ]] || die "SHA256SUMS is ${found%% *}, and package made ${DIGEST}"
  (cd -- "${DIRECTORY}" && sha256sum --check --strict --quiet SHA256SUMS) ||
    die "a file in ${DIRECTORY} is not the one SHA256SUMS names"

  fingerprint=$(jq -r '.signing_key' <<<"${project}")
  name=$(jq -r '.name' <<<"${project}")
  certificate_of "${WORK}/public-crates" "${name}" "${WORK}/signing.asc" "${fingerprint}" "${WORK}/certificate"
  revoked=$(revoked_keys "${WORK}/signing.asc" "${WORK}/revocations")
  ! grep -qxF -- "${fingerprint}" <<<"${revoked}" || die "the keyservers publish the project's key ${fingerprint} as revoked"
  vks_serves "${WORK}/revocations.published" "${fingerprint}" "${WORK}/served" "${WORK}/signing.asc"
  printf 'fingerprint=%s\nrevoked=%s\n' "${fingerprint}" "${revoked//$'\n'/ }" >>"${GITHUB_OUTPUT}"
  printf 'the run'"'"'s pins and package'"'"'s files hold; signing for %s with %s\n' "${REPOSITORY}" "${fingerprint}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
