#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-record's step (bash 5.3, git, gpg 2.4,
# curl, jq), and a developer's Linux machine for its cases.
# crate-record's step, STEP `prepare` or `make` (action.yml says what each does). Every request to
# GitHub carries the job's token from a header file, never an argument; the project's releases are
# read with it, so a draft is seen.
# Environment: STEP, REPOSITORY, REPOSITORY_ID, REF, SHA (the run's), DIRECTORY, DIGEST, VERSION,
# CRATES; for prepare OBJECT, COMMIT, SIGNER and GIT_BASE; for make BUNDLE and UPLOADS; API,
# RUNNER_TEMP; the job's token on descriptor 3.
# prepare writes subjects and predicate.json into the new directory RUNNER_TEMP/crate-record.
# Exit 0 when done; 1 refused; 64 for an invocation it refuses; 69 for an absent tool; 75 when
# something could not be read or written.
# shellcheck disable=SC2153,SC2154 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

# A request of <method> to <url> with the body <data> (a file, or - for none) of <type>, its answer
# into <file>; the status printed, 000 when nothing answered.
send() {
  local method=$1 url=$2 data=$3 type=$4 file=$5 code
  local -a body=()
  [[ ${data} == - ]] || body=(--data-binary "@${data}")
  code=$(curl --silent --show-error --max-time 300 --user-agent "${AGENT}" --output "${file}" --write-out '%{http_code}' \
    --header @"${WORK}/authorization" --header 'Accept: application/vnd.github+json' \
    --header "Content-Type: ${type}" --request "${method}" "${body[@]}" "${url}") || code=000
  printf '%s' "${code}"
}

# Every release of the project whose tag is TAG, drafts included, as one JSON array.
releases_of_tag() {
  local page=1 code all='[]' count
  while :; do
    code=$(fetch "${API}/repos/${REPOSITORY}/releases?per_page=100&page=${page}" "${WORK}/releases" \
      --header @"${WORK}/authorization" --header 'Accept: application/vnd.github+json')
    [[ ${code} == 200 ]] || unreadable "GitHub answered ${code} for ${REPOSITORY}'s releases"
    all=$(jq -c --slurpfile more "${WORK}/releases" --arg t "${TAG}" '. + [$more[0][] | select(.tag_name == $t)]' <<<"${all}")
    count=$(jq 'length' "${WORK}/releases")
    ((count == 100)) || break
    page=$((page + 1))
  done
  printf '%s\n' "${all}"
}

# What stands for TAG among <releases>: `none`, `drafts`, or `equal` for a published release whose
# assets are the files SHA256SUMS names, SHA256SUMS and SHA256SUMS.asc, each of the digest held
# here, beside the attestation's bundle alone. Refused for anything else.
standing() {
  local releases=$1 expected published found
  published=$(jq -c '[.[] | select(.draft == false)]' <<<"${releases}")
  if jq -e 'length == 0' <<<"${published}" >/dev/null; then
    if jq -e 'length == 0' <<<"${releases}" >/dev/null; then printf 'none\n'; else printf 'drafts\n'; fi
    return 0
  fi
  jq -e 'length == 1' <<<"${published}" >/dev/null || die "${REPOSITORY} holds more than one release of ${TAG}"
  expected=$(cd -- "${DIRECTORY}" && {
    awk '{name = $2; sub(/^\*/, "", name); print name}' SHA256SUMS
    printf 'SHA256SUMS\nSHA256SUMS.asc\n'
  } | while IFS= read -r file; do
    found=$(cd -- "${DIRECTORY}" && sha256sum -- "${file}")
    jq -nc --arg n "${file}" --arg d "sha256:${found%% *}" '{name: $n, digest: $d}'
  done | jq -sc 'sort_by(.name)')
  jq -e --argjson want "${expected}" --arg bundle "${BUNDLE_NAME}" --arg pre "${PRERELEASE}" \
    '.[0] | ([.assets[] | select(.name != $bundle) | {name, digest}] | sort_by(.name)) == $want
      and ([.assets[] | select(.name == $bundle)] | length) == 1
      and .prerelease == ($pre == "true")' <<<"${published}" >/dev/null ||
    die "${REPOSITORY} holds a release of ${TAG} whose files are not this run's signed ones"
  printf 'equal\n'
}

prepare_step() {
  local catalogue project crates_lines releases
  [[ ${OBJECT} =~ ^[0-9a-f]{40}$ && ${COMMIT} =~ ^[0-9a-f]{40}$ ]] || die "the tag object or the commit is not 40 hexadecimal digits"
  [[ ${SIGNER} =~ ^[0-9A-F]{40}$ ]] || die "the signer ${SIGNER} is not a v4 fingerprint"
  [[ ${COMMIT} == "${SHA}" ]] || die "admit's commit ${COMMIT} is not this run's ${SHA}"
  catalogue=${WORK}/public-crates
  catalogue "${catalogue}" >/dev/null
  project=$(project_of "${catalogue}" "${REPOSITORY}" "${REPOSITORY_ID}")
  verify_release "${DIRECTORY}" "${catalogue}" "${project}" "${WORK}"
  releases=$(releases_of_tag)
  standing "${releases}" >/dev/null
  OUT=${RUNNER_TEMP}/crate-record
  mkdir -- "${OUT}" || die "${OUT} exists; the attest step's files go into a new directory"
  crates_lines=$(awk '{name = $2; sub(/^\*/, "", name); if (name ~ /\.crate$/) print $1 "  " name}' "${DIRECTORY}/SHA256SUMS")
  printf '%s\n' "${crates_lines}" >"${OUT}/subjects"
  jq -n --arg repository "${REPOSITORY}" --argjson id "${REPOSITORY_ID}" --arg tag "${TAG}" --arg object "${OBJECT}" \
    --arg commit "${COMMIT}" --arg signer "${SIGNER}" --arg version "${VERSION}" \
    '{repository: $repository, repository_id: $id, tag: $tag, tag_object: $object, commit: $commit, signer: $signer, version: $version}' \
    >"${OUT}/predicate.json"
  printf 'the files are package'"'"'s and signed by the project'"'"'s key; attesting %s\n' "${crates_lines//$'\n'/, }"
}

DRAFT=''

# A draft this step made and did not publish is deleted, so a re-run finds none of its making.
drop_draft() {
  local code
  [[ -n ${DRAFT} ]] || return 0
  code=$(send DELETE "${API}/repos/${REPOSITORY}/releases/${DRAFT}" - application/json "${WORK}/answer")
  [[ ${code} == 204 ]] || printf '::warning::the draft release %s could not be deleted (%s)\n' "${DRAFT}" "${code}" >&2
}

make_step() {
  local releases state id code file body make_latest list
  local -a drafts uploads
  [[ -f ${BUNDLE} ]] || die "the attestation's bundle ${BUNDLE} is absent"
  releases=$(releases_of_tag)
  state=$(standing "${releases}")
  if [[ ${state} == equal ]]; then
    printf 'the release %s already holds these files; it stands\n' "${TAG}"
    return 0
  fi
  list=$(jq -r '.[] | select(.draft) | .id' <<<"${releases}")
  mapfile -t drafts <<<"${list}"
  for id in "${drafts[@]}"; do
    [[ -n ${id} ]] || continue
    code=$(send DELETE "${API}/repos/${REPOSITORY}/releases/${id}" - application/json "${WORK}/answer")
    [[ ${code} == 204 ]] || unreadable "GitHub answered ${code} deleting the earlier draft ${id} of ${TAG}"
    printf 'deleted the draft %s an earlier attempt left\n' "${id}"
  done
  make_latest=legacy
  [[ ${PRERELEASE} == false ]] || make_latest=false
  jq -n --arg tag "${TAG}" --arg sha "${SHA}" --rawfile notes "${DIRECTORY}/changelog.md" --argjson pre "${PRERELEASE}" \
    --arg latest "${make_latest}" \
    '{tag_name: $tag, target_commitish: $sha, name: $tag, body: $notes, draft: true, prerelease: $pre, make_latest: $latest}' \
    >"${WORK}/release.json"
  code=$(send POST "${API}/repos/${REPOSITORY}/releases" "${WORK}/release.json" application/json "${WORK}/answer")
  [[ ${code} == 201 ]] || unreadable "GitHub answered ${code} making the draft of ${TAG}: $(<"${WORK}/answer")"
  DRAFT=$(jq -er '.id' "${WORK}/answer")
  list=$(awk '{name = $2; sub(/^\*/, "", name); print name}' "${DIRECTORY}/SHA256SUMS")
  mapfile -t uploads <<<"${list}"
  uploads+=(SHA256SUMS SHA256SUMS.asc)
  for file in "${uploads[@]}"; do
    code=$(send POST "${UPLOADS}/repos/${REPOSITORY}/releases/${DRAFT}/assets?name=${file}" "${DIRECTORY}/${file}" \
      application/octet-stream "${WORK}/answer")
    [[ ${code} == 201 ]] || unreadable "GitHub answered ${code} for the asset ${file}"
  done
  code=$(send POST "${UPLOADS}/repos/${REPOSITORY}/releases/${DRAFT}/assets?name=${BUNDLE_NAME}" "${BUNDLE}" \
    application/json "${WORK}/answer")
  [[ ${code} == 201 ]] || unreadable "GitHub answered ${code} for the attestation's bundle"
  body=${WORK}/publish.json
  printf '{"draft":false}' >"${body}"
  code=$(send PATCH "${API}/repos/${REPOSITORY}/releases/${DRAFT}" "${body}" application/json "${WORK}/answer")
  [[ ${code} == 200 ]] || unreadable "GitHub answered ${code} publishing ${TAG}: $(<"${WORK}/answer")"
  DRAFT=''
  printf 'recorded the release %s\n' "${TAG}"
}

main() {
  local self here request
  : "${STEP:?}" "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${REF:?}" "${SHA:?}" "${DIRECTORY:?}" "${DIGEST:?}"
  : "${VERSION:?}" "${CRATES:?}" "${API:?}" "${RUNNER_TEMP:?}"
  self=$(realpath -- "${BASH_SOURCE[0]}")
  here=$(dirname -- "${self}")
  # shellcheck source=actions/crate-publish/lib.sh
  source "${here}/../crate-publish/lib.sh"
  tools git gpg gpgconf curl jq awk sha256sum realpath mktemp
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
  trap '((BASHPID == '"${BASHPID}"')) && drop_draft && stop_homes "'"${WORK}"'" && rm -rf -- "'"${WORK}"'"' EXIT
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "${request}" >"${WORK}/authorization"
  )
  request=''
  [[ ${REF} == refs/tags/v* ]] || die "a release is recorded on a v tag, and this run is on ${REF}"
  TAG=${REF#refs/tags/}
  [[ ${VERSION} == "${TAG#v}" ]] || die "admit's version ${VERSION} is not the tag ${TAG}'s"
  [[ ${DIGEST} =~ ^[0-9a-f]{64}$ ]] || die "package's digest is not 64 hexadecimal digits"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,63}$"))' <<<"${CRATES}" >/dev/null ||
    die "admit's crates are not a list of crate names"
  PRERELEASE=false
  [[ ${VERSION%%+*} != *-* ]] || PRERELEASE=true
  BUNDLE_NAME=attestation.sigstore.json
  check_files "${DIRECTORY}" "${DIGEST}" "${CRATES}" "${VERSION}"
  case ${STEP} in
    prepare)
      : "${OBJECT:?}" "${COMMIT:?}" "${SIGNER:?}" "${GIT_BASE:?}"
      prepare_step
      ;;
    make)
      : "${BUNDLE:?}" "${UPLOADS:?}"
      make_step
      ;;
    *)
      printf '::error::step is prepare or make, not %s\n' "${STEP}" >&2
      exit 64
      ;;
  esac
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
