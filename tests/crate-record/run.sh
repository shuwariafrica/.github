#!/usr/bin/env bash
# Runs crate-record's two steps over a release made here (tests/crates.sh), against a stand-in for
# GitHub's releases API: prepare's refusals and the attest step's files, and make's release, an
# earlier attempt's draft replaced, an equal release accepted and any other refused.
# Usage: run.sh [--tree <directory>] [<case>...]; tests/crates.sh says the rest.
# Needs gpg, gpgconf, git, jq, yq (mikefarah's) and sha256sum.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
# shellcheck source=tests/step.sh
. "${HERE}/../step.sh"
# shellcheck source=tests/crates.sh
. "${HERE}/../crates.sh"
TOOLS=()

readonly SHA=1111111111111111111111111111111111111111
readonly OBJECT=2222222222222222222222222222222222222222
readonly API=https://api.github.com/repos/shuwariafrica/probe
readonly UPLOADS=https://uploads.github.com/repos/shuwariafrica/probe

# A case's world: public-crates, a release in <case>/release signed by <key>, the attest step's
# bundle, keyservers holding nothing, and the project's releases <releases json>.
world() {
  local d=$1 key=${2:-signing} releases=${3:-[]}
  catalogue_repo "${d}"
  release_dir "${d}/release" "${key}"
  keyservers "${d}" "${SIGNING_KEY}"
  printf '{"bundle": true}\n' >"${d}/bundle.json"
  printf '%s' "${releases}" >"${d}/releases.json"
  route "${d}" GET "${API}/releases?per_page=100&page=1" 200 "${d}/releases.json"
}

step_of() { # case, step, VAR=value...
  local d=$1 step=$2
  shift 2
  run_script "${d}" crate-record/record-step.sh STEP="${step}" REPOSITORY=shuwariafrica/probe REPOSITORY_ID="${ID}" \
    REF="${REF_OVER:-refs/tags/v0.1.0}" SHA="${SHA}" DIRECTORY="${d}/release" DIGEST="${DIGEST_OVER:-${DIGEST}}" \
    VERSION="${VERSION_OVER:-0.1.0}" CRATES='["probe-a","probe-b"]' OBJECT="${OBJECT}" COMMIT="${COMMIT_OVER:-${SHA}}" \
    SIGNER="${TAG_SUBKEY}" BUNDLE="${d}/bundle.json" API=https://api.github.com UPLOADS=https://uploads.github.com "$@" 3<<<job-token
}

# The project's release of v0.1.0 as GitHub lists it: <draft>, each file of the release with its
# digest, the bundle, and <changed> files' digests other.
listed() {
  local d=$1 draft=$2 changed=${3:-} file assets='[]' digest
  for file in "${d}"/release/*; do
    digest=$(sha256sum "${file}" | cut -d' ' -f1)
    [[ ${file##*/} != "${changed}" ]] || digest=$(printf '%064d' 5)
    assets=$(jq -c --arg n "${file##*/}" --arg d "sha256:${digest}" '. + [{name: $n, digest: $d}]' <<<"${assets}")
  done
  assets=$(jq -c '. + [{name: "attestation.sigstore.json", digest: "sha256:0"}]' <<<"${assets}")
  jq -nc --argjson a "${assets}" --argjson draft "${draft}" '[{id: 55, tag_name: "v0.1.0", draft: $draft, prerelease: false, assets: $a}]'
}

# GitHub's answers for making the release: the draft 77, each upload, publishing it.
making() {
  local d=$1 upload=${2:-201}
  printf '{"id": 77}' >"${d}/draft.json"
  route "${d}" POST "${API}/releases" 201 "${d}/draft.json"
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=probe-a-0.1.0.crate" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=probe-a-0.1.0.upload" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=probe-b-0.1.0.crate" "${upload}" /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=probe-b-0.1.0.upload" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=order" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=changelog.md" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=SHA256SUMS" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=SHA256SUMS.asc" 201 /dev/null
  route "${d}" POST "${UPLOADS}/releases/77/assets?name=attestation.sigstore.json" 201 /dev/null
  printf '{}' >"${d}/published.json"
  route "${d}" PATCH "${API}/releases/77" 200 "${d}/published.json"
  route "${d}" DELETE "${API}/releases/77" 204 /dev/null
  route "${d}" DELETE "${API}/releases/55" 204 /dev/null
}

case_prepare_writes_the_attest_steps_files_from_package_and_admit() {
  local d predicate subjects
  d=$(fresh prepare)
  world "${d}"
  step_of "${d}" prepare
  expect "${d}" 0 'attesting'
  subjects=$(grep '\.crate$' "${d}/release/SHA256SUMS")
  [[ $(<"${d}/temp/crate-record/subjects") == "${subjects}" ]] ||
    fail "the subjects are $(<"${d}/temp/crate-record/subjects")"
  predicate=$(jq -c . "${d}/temp/crate-record/predicate.json")
  [[ ${predicate} == "{\"repository\":\"shuwariafrica/probe\",\"repository_id\":${ID},\"tag\":\"v0.1.0\",\"tag_object\":\"${OBJECT}\",\"commit\":\"${SHA}\",\"signer\":\"${TAG_SUBKEY}\",\"version\":\"0.1.0\"}" ]] ||
    fail "the predicate is ${predicate}"
  grep -qxF 'Authorization: Bearer job-token' "${d}/stub/headers" || fail 'the releases were not read with the job token'
}

case_the_steps_run_as_their_action_steps_run_them() {
  local d
  d=$(fresh wired)
  world "${d}"
  making "${d}"
  input=([step]=prepare [directory]="${d}/release" [digest]="${DIGEST}" [version]=0.1.0 [crates]='["probe-a","probe-b"]'
    [object]="${OBJECT}" [commit]="${SHA}" [signer]="${TAG_SUBKEY}" [bundle]='')
  over=([TOKEN]=job-token [REPOSITORY]=shuwariafrica/probe [REPOSITORY_ID]="${ID}" [REF]=refs/tags/v0.1.0 [SHA]="${SHA}"
    [GIT_BASE]="file://${d}/git")
  wired "${d}" crate-record 0
  expect "${d}" 0 'attesting'
  input[step]='make'
  input[bundle]=${d}/bundle.json
  wired "${d}" crate-record 0
  expect "${d}" 0 'recorded the release v0.1.0'
}

case_a_file_unlike_packages_output_or_not_in_sums_is_refused() {
  local d
  d=$(fresh digest)
  world "${d}"
  DIGEST_OVER=$(printf '%064d' 1) step_of "${d}" prepare
  expect "${d}" 1 'and package made'
  d=$(fresh extra)
  world "${d}"
  printf 'extra\n' >"${d}/release/extra-0.1.0.crate"
  step_of "${d}" prepare
  expect "${d}" 1 'extra-0.1.0.crate is not a file SHA256SUMS names'
  [[ ! -e ${d}/temp/crate-record ]] || fail "the attest step's files were written"
}

case_a_signature_not_by_signing_key_is_refused() {
  local d
  d=$(fresh other_signer)
  world "${d}" stranger
  step_of "${d}" prepare
  expect "${d}" 1 "not one good signature under the project's signing certificate"
}

# make verifies SHA256SUMS.asc again, since the attest step runs between the two steps: a signature
# not by the project's key is refused before anything is written.
case_make_refuses_a_signature_not_by_signing_key() {
  local d
  d=$(fresh make_other_signer)
  world "${d}" stranger
  making "${d}"
  step_of "${d}" make
  expect "${d}" 1 "not one good signature under the project's signing certificate"
  calls_are "${d}" $'\t(POST|PATCH|DELETE)\t' 0
}

case_a_commit_or_version_not_the_runs_is_refused() {
  local d
  d=$(fresh other_commit)
  world "${d}"
  COMMIT_OVER=$(printf '%040d' 3) step_of "${d}" prepare
  expect "${d}" 1 "is not this run's"
  d=$(fresh other_version)
  world "${d}"
  REF_OVER=refs/tags/v0.2.0 step_of "${d}" prepare
  expect "${d}" 1 "is not the tag v0.2.0's"
}

case_make_records_the_release_with_its_files_and_notes() {
  local d n sent
  d=$(fresh make)
  world "${d}"
  making "${d}"
  step_of "${d}" make
  expect "${d}" 0 'recorded the release v0.1.0'
  n=$(grep -n $'\tPOST\thttps://api.github.com/repos/shuwariafrica/probe/releases$' "${d}/stub/calls" | cut -d: -f1)
  sent=$(jq -c '{tag_name, target_commitish, name, draft, prerelease, make_latest, body}' "${d}/stub/sent.${n}")
  [[ ${sent} == "{\"tag_name\":\"v0.1.0\",\"target_commitish\":\"${SHA}\",\"name\":\"v0.1.0\",\"draft\":true,\"prerelease\":false,\"make_latest\":\"legacy\",\"body\":\"## 0.1.0\\n\\nThe first.\\n\"}" ]] ||
    fail "the draft sent is ${sent}"
  calls_are "${d}" $'\tPOST\thttps://uploads.github.com/' 9
  calls_are "${d}" $'\tPATCH\t' 1
  calls_are "${d}" $'\tDELETE\t' 0
}

case_a_pre_release_version_is_recorded_as_a_pre_release() {
  local d n digest sent
  d=$(fresh prerelease)
  world "${d}"
  for n in a b; do
    printf 'the tarball of probe-%s\n' "${n}" >"${d}/release/probe-${n}-0.1.0-alpha.1.crate"
    body "${d}/release/probe-${n}-0.1.0-alpha.1.crate" "probe-${n}" 0.1.0-alpha.1 "${d}/release/probe-${n}-0.1.0-alpha.1.upload"
  done
  rm -- "${d}"/release/*-0.1.0.*
  (cd -- "${d}/release" && sha256sum -- *.crate *.upload order changelog.md >SHA256SUMS)
  sign_sums "${d}/release" signing
  making "${d}"
  sed -i 's/0\.1\.0\.crate/0.1.0-alpha.1.crate/; s/0\.1\.0\.upload/0.1.0-alpha.1.upload/' "${d}/stub/routes"
  for n in probe-a-0.1.0-alpha.1.crate probe-a-0.1.0-alpha.1.upload probe-b-0.1.0-alpha.1.crate probe-b-0.1.0-alpha.1.upload; do
    route "${d}" POST "${UPLOADS}/releases/77/assets?name=${n}" 201 /dev/null
  done
  route "${d}" GET "${API}/releases?per_page=100&page=1" 200 "${d}/releases.json"
  digest=$(sha256sum "${d}/release/SHA256SUMS")
  DIGEST_OVER=${digest%% *} REF_OVER=refs/tags/v0.1.0-alpha.1 VERSION_OVER=0.1.0-alpha.1 \
    step_of "${d}" make
  expect "${d}" 0 'recorded the release v0.1.0-alpha.1'
  n=$(grep -n $'\tPOST\thttps://api.github.com/repos/shuwariafrica/probe/releases$' "${d}/stub/calls" | cut -d: -f1)
  sent=$(jq -c '[.prerelease, .make_latest]' "${d}/stub/sent.${n}")
  [[ ${sent} == '[true,"false"]' ]] || fail "the draft sent gives [prerelease, make_latest] ${sent}"
}

case_an_earlier_attempts_draft_is_deleted_and_made_again() {
  local d
  d=$(fresh draft)
  world "${d}"
  listed "${d}" true probe-a-0.1.0.crate >"${d}/releases.json"
  making "${d}"
  step_of "${d}" prepare
  expect "${d}" 0 'attesting'
  step_of "${d}" make
  expect "${d}" 0 'recorded the release v0.1.0'
  calls_are "${d}" $'\tDELETE\thttps://api.github.com/repos/shuwariafrica/probe/releases/55$' 1
  calls_are "${d}" $'\tPATCH\t' 1
}

case_an_equal_release_is_accepted_so_a_rerun_completes() {
  local d
  d=$(fresh equal)
  world "${d}"
  listed "${d}" false >"${d}/releases.json"
  making "${d}"
  step_of "${d}" prepare
  expect "${d}" 0 'attesting'
  step_of "${d}" make
  expect "${d}" 0 'the release v0.1.0 already holds these files; it stands'
  calls_are "${d}" $'\t(POST|PATCH|DELETE)\t' 0
}

case_any_other_release_of_the_tag_is_refused() {
  local d
  d=$(fresh other_release)
  world "${d}"
  listed "${d}" false probe-b-0.1.0.upload >"${d}/releases.json"
  making "${d}"
  step_of "${d}" prepare
  expect "${d}" 1 "holds a release of v0.1.0 whose files are not this run's signed ones"
  [[ ! -e ${d}/temp/crate-record ]] || fail "the attest step's files were written"
  step_of "${d}" make
  expect "${d}" 1 "holds a release of v0.1.0 whose files are not this run's signed ones"
  calls_are "${d}" $'\t(POST|PATCH|DELETE)\t' 0
}

case_a_draft_this_step_made_is_deleted_when_it_stops_short() {
  local d
  d=$(fresh stops_short)
  world "${d}"
  making "${d}" 502
  step_of "${d}" make
  expect "${d}" 75 'GitHub answered 502 for the asset probe-b-0.1.0.crate'
  calls_are "${d}" $'\tDELETE\thttps://api.github.com/repos/shuwariafrica/probe/releases/77$' 1
  calls_are "${d}" $'\tPATCH\t' 0
}

# GitHub's answers when its answer to the publication was <status>: the release 77 read back by id
# as <read status> with <draft> (`true`, `false`, or none for no body).
publish_unanswered() {
  local d=$1 status=$2 read=$3 draft=${4:-}
  sed -i '/^PATCH /d' "${d}/stub/routes"
  route "${d}" PATCH "${API}/releases/77" "${status}" /dev/null
  if [[ -n ${draft} ]]; then
    printf '{"id": 77, "tag_name": "v0.1.0", "draft": %s}' "${draft}" >"${d}/read-back.json"
  else
    printf '{}' >"${d}/read-back.json"
  fi
  route "${d}" GET "${API}/releases/77" "${read}" "${d}/read-back.json"
}

# A publication GitHub did not answer with 200 is read back by id, and nothing is deleted in that
# run, even a release that reads back as a draft: GitHub can still commit the publication, and a
# published release is immutable, its tag never reusable once deleted.
case_no_release_is_deleted_after_an_unanswered_publication() {
  local d
  d=$(fresh unanswered_draft)
  world "${d}"
  making "${d}"
  publish_unanswered "${d}" 502 200 true
  step_of "${d}" make
  expect "${d}" 75 'GitHub answered 502 publishing v0.1.0, and the release reads back as a draft: it is left as it is'
  calls_are "${d}" $'\tGET\thttps://api.github.com/repos/shuwariafrica/probe/releases/77$' 1
  calls_are "${d}" $'\tDELETE\t' 0
  d=$(fresh unanswered_published)
  world "${d}"
  making "${d}"
  publish_unanswered "${d}" 000 200 false
  step_of "${d}" make
  expect "${d}" 0 'recorded the release v0.1.0'
  grep -qF 'GitHub answered 000 publishing v0.1.0, and the release reads back as published' "${d}/stdout" ||
    fail 'the step does not say how it knows the release is published'
  calls_are "${d}" $'\tDELETE\t' 0
  d=$(fresh unanswered_unread)
  world "${d}"
  making "${d}"
  publish_unanswered "${d}" 504 503
  step_of "${d}" make
  expect "${d}" 75 'GitHub answered 504 publishing v0.1.0, and 503 reading the release back: it is left as it is'
  calls_are "${d}" $'\tDELETE\t' 0
}

crates_main "$@"
