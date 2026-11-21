#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-publish's step (bash 5.3, git, gpg 2.4,
# curl, jq), and a developer's Linux machine for its cases.
# crate-publish's first step, before any token: the run's files in DIRECTORY are crate-package's
# (DIGEST) for the admitted CRATES at VERSION, which are the project's; SHA256SUMS.asc verifies
# against the project's key (lib.sh's verify_release); each upload body carries its signed
# `.crate`. Then each crate, in the signed order, on crates.io: held at VERSION with the signed
# digest, skipped; with another, refused; unknown to crates.io, what the owner's act for a first
# publication takes goes to the run's summary and the job fails; with trustpub_only false, or
# owners other than the project's crates_io_owners as user logins with no team, refused.
# Environment: REPOSITORY, REPOSITORY_ID, REF, RUN_ID (the run's), DIRECTORY, DIGEST, VERSION,
# CRATES, GIT_BASE, CRATES_IO, INDEX, RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY,
# GITHUB_ACTION_PATH.
# Writes publish, the crates left to publish in order as a JSON array, to GITHUB_OUTPUT.
# Exit 0 when the crates left may be published; 1 refused, or waiting on the owner; 69 for an
# absent tool; 75 when something could not be read.
# shellcheck disable=SC2153,SC2154 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

# The owner's first publication of <crate> (2.5 of the release's design), for the run's summary. It
# names what the owner's act needs and holds no line to run: the act's own lines run it, so nothing
# on a run's page is a command to copy.
owner_lines() {
  local crate=$1 own=$2
  cat <<LINES
## ${crate} ${VERSION} is new to crates.io: the owner publishes it first

crates.io gives a trusted-publishing token for no crate it does not hold. Every file of ${TAG} is signed, and recorded in the release [${TAG}](https://github.com/${REPOSITORY}/releases/tag/${TAG}). Nothing was published by this run.

The owner's lines for a first publication are in his act, not here. They take:

- the crate: \`${crate}\`
- the repository: \`${REPOSITORY}\`
- the tag: \`${TAG}\`
- this run: \`${RUN_ID}\`
- the commit of shuwariafrica/.github its crate-publish ran at: \`${own}\`

Once crates.io holds the crate, with its trusted publisher (repository owner \`shuwariafrica\`, repository \`${REPOSITORY#*/}\`, workflow \`release.yml\`, environment \`release\`) and trusted publishing only, "Re-run failed jobs" on this run publishes the rest.

LINES
}

main() {
  local self here own catalogue project names wanted work crate held signed page trusted owners want list
  local -a order unknown=() publish=()
  : "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${REF:?}" "${RUN_ID:?}" "${DIRECTORY:?}" "${DIGEST:?}" "${VERSION:?}" "${CRATES:?}"
  : "${GIT_BASE:?}" "${CRATES_IO:?}" "${INDEX:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
  : "${GITHUB_ACTION_PATH:?}"
  self=$(realpath -- "${BASH_SOURCE[0]}")
  here=$(dirname -- "${self}")
  # shellcheck source=actions/crate-publish/lib.sh
  source "${here}/lib.sh"
  # shellcheck source=actions/crate-sign/pins.sh
  source "${here}/../crate-sign/pins.sh"
  tools git gpg gpgconf curl jq awk sha256sum od dd cmp stat realpath mktemp
  WORK=$(mktemp -d -p "${RUNNER_TEMP}")
  trap '((BASHPID == '"${BASHPID}"')) && stop_homes "'"${WORK}"'" && rm -rf -- "'"${WORK}"'"' EXIT
  [[ ${REF} == refs/tags/v* ]] || die "a release is published on a v tag, and this run is on ${REF}"
  TAG=${REF#refs/tags/}
  [[ ${VERSION} == "${TAG#v}" ]] || die "admit's version ${VERSION} is not the tag ${TAG}'s"
  [[ ${DIGEST} =~ ^[0-9a-f]{64}$ ]] || die "package's digest is not 64 hexadecimal digits"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,63}$"))' <<<"${CRATES}" >/dev/null ||
    die "admit's crates are not a list of crate names"
  own=$(own_commit "${GITHUB_ACTION_PATH}" crate-publish)

  check_files "${DIRECTORY}" "${DIGEST}" "${CRATES}" "${VERSION}"
  catalogue=${WORK}/public-crates
  catalogue "${catalogue}" >/dev/null
  project=$(project_of "${catalogue}" "${REPOSITORY}" "${REPOSITORY_ID}")
  names=$(jq -c 'sort' <<<"${CRATES}")
  wanted=$(jq -c '.crates | sort' <<<"${project}")
  [[ ${names} == "${wanted}" ]] || die "admit's crates ${names} are not the project's ${wanted}"
  verify_release "${DIRECTORY}" "${catalogue}" "${project}" "${WORK}"
  mapfile -t order <"${DIRECTORY}/order"
  for crate in "${order[@]}"; do
    # shellcheck disable=SC2310
    # body_carries's status is its answer.
    body_carries "${DIRECTORY}/${crate}-${VERSION}.upload" "${DIRECTORY}/${crate}-${VERSION}.crate" "${crate}" "${VERSION}" ||
      die "${crate}-${VERSION}.upload does not carry the signed ${crate}-${VERSION}.crate"
  done

  work=${WORK}/crates-io
  mkdir -- "${work}"
  want=$(jq -c '.crates_io_owners' <<<"${project}")
  for crate in "${order[@]}"; do
    held=$(index_digest "${crate}" "${VERSION}" "${work}")
    signed=$(awk -v f="${crate}-${VERSION}.crate" '{name = $2; sub(/^\*/, "", name); if (name == f) print $1}' "${DIRECTORY}/SHA256SUMS")
    if [[ -n ${held} ]]; then
      [[ ${held} == "${signed}" ]] || die "crates.io holds ${crate} ${VERSION} with ${held}, and the release signed ${signed}"
      printf '%s %s: on crates.io as signed\n' "${crate}" "${VERSION}"
      continue
    fi
    page=$(crates_io "${crate}" '' "${work}")
    if [[ ${page} == null ]]; then
      unknown+=("${crate}")
      continue
    fi
    trusted=$(jq -r '.crate.trustpub_only' <<<"${page}")
    [[ ${trusted} == true ]] || die "${crate} takes token publication on crates.io: trustpub_only is not set"
    owners=$(crates_io "${crate}" /owners "${work}")
    # shellcheck disable=SC2310 # owners_match's status is its one jq's, the answer here
    if ! owners_match "${owners}" "${want}"; then
      list=$(jq -c '[.users[] | "\(.kind) \(.login)"]' <<<"${owners}")
      die "${crate}'s owners on crates.io are ${list}, and the project's are ${want}, users alone"
    fi
    publish+=("${crate}")
  done
  if ((${#unknown[@]} > 0)); then
    for crate in "${unknown[@]}"; do
      owner_lines "${crate}" "${own}" >>"${GITHUB_STEP_SUMMARY}"
    done
    die "crates.io does not hold ${unknown[*]}: the owner publishes each first, by the lines in this run's summary, then re-runs this job"
  fi
  list=$(jq -nc '$ARGS.positional' --args "${publish[@]}")
  printf 'publish=%s\n' "${list}" >>"${GITHUB_OUTPUT}"
  if ((${#publish[@]} > 0)); then
    printf 'to publish: %s\n' "${publish[*]}"
  else
    printf 'every crate is on crates.io as signed\n'
  fi
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
