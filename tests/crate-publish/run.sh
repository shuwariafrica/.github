#!/usr/bin/env bash
# Runs crate-publish's steps over a release made here (tests/crates.sh): its check step's
# refusals before any token, the publication step's token, and the owner's first-publication line.
# Usage: run.sh [--tree <directory>] [<case>...]; tests/crates.sh says the rest.
# Needs gpg, gpgconf, git, jq, yq (mikefarah's), sha256sum, od and cmp.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
# shellcheck source=tests/step.sh
. "${HERE}/../step.sh"
# shellcheck source=tests/crates.sh
. "${HERE}/../crates.sh"
TOOLS=(od cmp)

readonly OWNER_ALONE='{"users":[{"kind":"user","login":"arashi01","id":1}]}'

# A case's world: public-crates, a release in <case>/release signed by <key>, keyservers holding
# nothing for the project's key, and crates.io holding probe-a as signed and probe-b, bound to
# trusted publishing alone and owned by the project's owner, at an earlier version.
world() {
  local d=$1 key=${2:-signing} digest
  catalogue_repo "${d}"
  release_dir "${d}/release" "${key}"
  keyservers "${d}" "${SIGNING_KEY}"
  digest=$(awk '$2 == "probe-a-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  index "${d}" probe-a "0.1.0=${digest}"
  index "${d}" probe-b "0.0.9=0000"
  crate_page "${d}" probe-b true
  owners "${d}" probe-b "${OWNER_ALONE}"
}

# The sparse index's answer for <crate>: each <version>=<digest> a line.
index() {
  local d=$1 crate=$2 answer='' entry
  shift 2
  for entry in "$@"; do
    answer+=$(jq -nc --arg n "${crate}" --arg v "${entry%%=*}" --arg c "${entry#*=}" '{name: $n, vers: $v, cksum: $c}')$'\n'
  done
  printf '%s' "${answer}" >"${d}/index-${crate}"
  sed -i "\|^GET https://index.crates.io/pr/ob/${crate}\t|d" "${d}/stub/routes"
  route "${d}" GET "https://index.crates.io/pr/ob/${crate}" 200 "${d}/index-${crate}"
}

crate_page() { # case, crate, trustpub_only
  printf '{"crate":{"name":"%s","trustpub_only":%s}}' "$2" "$3" >"$1/page-$2"
  sed -i "\|^GET https://crates.io/api/v1/crates/$2\t|d" "$1/stub/routes"
  route "$1" GET "https://crates.io/api/v1/crates/$2" 200 "$1/page-$2"
}

owners() { # case, crate, answer
  printf '%s' "$3" >"$1/owners-$2"
  sed -i "\|^GET https://crates.io/api/v1/crates/$2/owners\t|d" "$1/stub/routes"
  route "$1" GET "https://crates.io/api/v1/crates/$2/owners" 200 "$1/owners-$2"
}

# The check step's script over the case's world, with CRATES and DIGEST as the case sets them.
check() {
  local d=$1 path
  path=$(action_path crate-publish)
  run_script "${d}" crate-publish/check-step.sh REPOSITORY=shuwariafrica/probe REPOSITORY_ID="${ID}" \
    REF=refs/tags/v0.1.0 RUN_ID=4242 DIRECTORY="${d}/release" DIGEST="${DIGEST_OVER:-${DIGEST}}" VERSION=0.1.0 \
    CRATES="${CRATES_OVER:-[\"probe-a\",\"probe-b\"]}" CRATES_IO=https://crates.io INDEX=https://index.crates.io \
    GITHUB_ACTION_PATH="${path}"
}

no_token() { # case: no token was asked for
  local n
  n=$(calls "$1" 'trusted_publishing|crates/new')
  [[ ${n} == 0 ]] || fail "${n} calls toward a token or an upload"
}

case_check_leaves_the_crates_crates_io_does_not_hold_as_signed() {
  local d
  d=$(fresh check_leaves)
  world "${d}"
  check "${d}"
  expect "${d}" 0 'to publish: probe-b'
  out_is "${d}" publish '["probe-b"]'
  no_token "${d}"
}

case_check_runs_as_its_action_step_runs_it() {
  local d
  d=$(fresh check_wired)
  world "${d}"
  input=([directory]="${d}/release" [digest]="${DIGEST}" [version]=0.1.0 [crates]='["probe-a","probe-b"]')
  over=([REPOSITORY]=shuwariafrica/probe [REPOSITORY_ID]="${ID}" [REF]=refs/tags/v0.1.0 [RUN_ID]=4242
    [GIT_BASE]="file://${d}/git")
  wired "${d}" crate-publish 0
  expect "${d}" 0 'to publish: probe-b'
}

case_sums_unlike_packages_output_are_refused() {
  local d
  d=$(fresh sums_unlike)
  world "${d}"
  DIGEST_OVER=$(printf '%064d' 1) check "${d}"
  expect "${d}" 1 'and package made'
  no_token "${d}"
}

case_a_file_sums_does_not_name_is_refused() {
  local d
  d=$(fresh file_unnamed)
  world "${d}"
  printf 'extra\n' >"${d}/release/extra"
  check "${d}"
  expect "${d}" 1 'extra is not a file SHA256SUMS names'
  no_token "${d}"
}

case_a_file_unlike_its_sum_is_refused() {
  local d
  d=$(fresh file_unlike)
  world "${d}"
  printf 'changed\n' >>"${d}/release/changelog.md"
  check "${d}"
  expect "${d}" 1 'is not the one SHA256SUMS names'
}

case_a_crate_outside_admits_is_refused() {
  local d
  d=$(fresh crate_outside)
  world "${d}"
  CRATES_OVER='["probe-a"]' check "${d}"
  expect "${d}" 1 "and the admitted crates' files are"
  d=$(fresh crate_outside_catalogue)
  world "${d}"
  catalogue_repo "${d}" '.crates = ["probe-a"]'
  check "${d}"
  expect "${d}" 1 "are not the project's"
}

case_a_signature_not_by_the_signing_key_is_refused() {
  local d
  d=$(fresh other_signer)
  world "${d}" stranger
  check "${d}"
  expect "${d}" 1 "not one good signature under the project's signing certificate"
  no_token "${d}"
}

case_a_certificate_whose_primary_is_not_signing_key_is_refused() {
  local d
  d=$(fresh other_certificate)
  world "${d}" stranger
  catalogue_repo "${d}" . stranger
  check "${d}"
  expect "${d}" 1 "not the project's signing_key ${SIGNING_KEY} alone"
}

case_two_signatures_both_by_the_signing_key_are_refused() {
  local d
  d=$(fresh two_signatures)
  world "${d}"
  g signing --yes --detach-sign --local-user "${SIGNING_SUBKEY}!" --output "${d}/one.sig" "${d}/release/SHA256SUMS"
  g signing --yes --detach-sign --digest-algo SHA512 --local-user "${SIGNING_SUBKEY}!" --output "${d}/two.sig" "${d}/release/SHA256SUMS"
  cat -- "${d}/one.sig" "${d}/two.sig" | g signing --enarmor | sed 's/ARMORED FILE-----$/SIGNATURE-----/' >"${d}/release/SHA256SUMS.asc"
  check "${d}"
  expect "${d}" 1 "not one good signature"
}

case_a_sha1_signature_is_refused() {
  local d
  d=$(fresh sha1)
  world "${d}"
  sign_sums "${d}/release" signing --digest-algo SHA1
  check "${d}"
  expect "${d}" 1 "not one good signature"
}

case_a_signing_key_not_yet_made_is_refused() {
  local d
  d=$(fresh no_key)
  world "${d}"
  catalogue_repo "${d}" '.signing_key = null'
  check "${d}"
  expect "${d}" 1 'holds no signing_key for shuwariafrica/probe'
}

case_a_subkey_the_keyservers_publish_as_revoked_is_refused() {
  local d home listing
  d=$(fresh revoked)
  home=$(own_key signing revoked)
  world "${d}" "${home}"
  catalogue_repo "${d}" . "${home}"
  revoke_subkey "${home}"
  listing=$(g "${home}" --with-colons --list-keys)
  [[ $'\n'${listing} == *$'\nsub:r:'* ]] || fail 'the subkey is not revoked'
  g "${home}" --armor --export "${SIGNING_KEY}" >"${d}/published.asc"
  sed -i '/keyserver.ubuntu.com\|keys.openpgp.org/d' "${d}/stub/routes"
  keyservers "${d}" "${SIGNING_KEY}" "${d}/published.asc"
  check "${d}"
  expect "${d}" 1 'which the keyservers publish as revoked'
  no_token "${d}"
}

case_a_keyserver_that_does_not_answer_refuses() {
  local d
  d=$(fresh silent)
  world "${d}"
  sed -i '/keys.openpgp.org/d' "${d}/stub/routes"
  route "${d}" GET "https://keys.openpgp.org/vks/v1/by-fingerprint/${SIGNING_KEY}" 000 /dev/null
  check "${d}"
  expect "${d}" 75 'the keyservers did not answer'
  no_token "${d}"
}

case_a_body_not_carrying_the_signed_crate_is_refused_before_any_token() {
  local d digest
  d=$(fresh body)
  world "${d}"
  printf 'another tarball\n' >"${d}/other.crate"
  body "${d}/other.crate" probe-b 0.1.0 "${d}/release/probe-b-0.1.0.upload"
  (cd -- "${d}/release" && sha256sum -- *.crate *.upload order changelog.md >SHA256SUMS)
  sign_sums "${d}/release" signing
  digest=$(sha256sum "${d}/release/SHA256SUMS")
  DIGEST_OVER=${digest%% *} check "${d}"
  expect "${d}" 1 'probe-b-0.1.0.upload does not carry the signed probe-b-0.1.0.crate'
  no_token "${d}"
}

case_an_index_digest_unlike_the_signed_one_fails() {
  local d
  d=$(fresh index_other)
  world "${d}"
  index "${d}" probe-a "0.1.0=$(printf '%064d' 9)"
  check "${d}"
  expect "${d}" 1 'crates.io holds probe-a 0.1.0 with'
  no_token "${d}"
}

case_an_unknown_crate_fails_the_job_naming_what_the_owners_act_takes() {
  local d summary
  d=$(fresh unknown)
  world "${d}"
  sed -i '\|crates.io/api/v1/crates/probe-b|d' "${d}/stub/routes"
  route "${d}" GET https://crates.io/api/v1/crates/probe-b 404 /dev/null
  index "${d}" probe-b
  check "${d}"
  expect "${d}" 1 'crates.io does not hold probe-b'
  summary=$(<"${d}/summary")
  [[ ${summary} == *"The owner's lines for a first publication are in his act"* ]] || fail 'the summary does not send the owner to his act'
  # shellcheck disable=SC2016
  # The summary's Markdown, quoted as it is written.
  [[ ${summary} == *'- the crate: `probe-b`'*'- the repository: `shuwariafrica/probe`'*'- the tag: `v0.1.0`'*'- this run: `4242`'*"crate-publish ran at: \`${OWN}\`"* ]] ||
    fail 'the summary does not name the crate, repository, tag, run and commit' "${summary}"
  # shellcheck disable=SC2016
  # As above.
  [[ ${summary} == *'repository `probe`, workflow `release.yml`, environment `release`'* ]] ||
    fail "the summary's publisher is not the project's release.yml in release"
  out_is "${d}" publish ''
  no_token "${d}"
}

# A run's page offers nothing to copy into a terminal: the owner runs his act's lines.
case_the_summary_holds_no_line_to_run() {
  local d summary found
  d=$(fresh no_line)
  world "${d}"
  sed -i '\|crates.io/api/v1/crates/probe-b|d' "${d}/stub/routes"
  route "${d}" GET https://crates.io/api/v1/crates/probe-b 404 /dev/null
  index "${d}" probe-b
  check "${d}"
  expect "${d}" 1 'crates.io does not hold probe-b'
  summary=$(<"${d}/summary")
  [[ -n ${summary} ]] || fail 'the summary is empty'
  found=$(grep -nE 'curl|git -C|bash|read -r' <<<"${summary}" || true) # none is the answer
  [[ -z ${found} ]] || fail "the summary holds a line to run: ${found}"
}

case_trustpub_only_false_fails() {
  local d
  d=$(fresh trustpub)
  world "${d}"
  crate_page "${d}" probe-b false
  check "${d}"
  expect "${d}" 1 'trustpub_only is not set'
  no_token "${d}"
}

case_owners_other_than_the_projects_fail() {
  local d list n=0
  for list in '{"users":[{"kind":"user","login":"arashi01"},{"kind":"user","login":"someone"}]}' \
    '{"users":[{"kind":"user","login":"arashi01"},{"kind":"team","login":"github:shuwariafrica:core"}]}' \
    '{"users":[{"kind":"user","login":"someone"}]}'; do
    n=$((n + 1))
    d=$(fresh "owners_${n}")
    world "${d}"
    owners "${d}" probe-b "${list}"
    check "${d}"
    expect "${d}" 1 "owners on crates.io are"
    no_token "${d}"
  done
}

case_crates_ios_api_is_read_a_second_apart_with_the_release_agent() {
  local d gaps
  d=$(fresh pace)
  world "${d}"
  check "${d}"
  expect "${d}" 0 'to publish: probe-b'
  gaps=$(awk -F'\t' '$3 ~ /^https:\/\/crates\.io\/api/ {if (last) print int(($1 - last) / 1000000); last = $1}' "${d}/stub/calls")
  [[ -n ${gaps} ]] || fail 'crates.io was read once'
  ! awk '$1 < 1000 {found = 1} END {exit !found}' <<<"${gaps}" || fail "gaps of [${gaps//$'\n'/ }] ms"
}

# The publication step over the case's release, crates.io's exchange answering 200 and its upload
# <status>; the OIDC request token on descriptor 3.
publish_step() {
  local d=$1 status=$2 digest
  printf '{"value":"oidc-jwt-value"}' >"${d}/oidc"
  route "${d}" GET 'https://oidc.example/token?x=1&audience=crates.io' 200 "${d}/oidc"
  printf '{"token":"cio_tp_secretsecretsecret"}' >"${d}/exchange"
  route "${d}" POST https://crates.io/api/v1/trusted_publishing/tokens 200 "${d}/exchange"
  printf '{}' >"${d}/put"
  route "${d}" PUT https://crates.io/api/v1/crates/new "${status}" "${d}/put"
  route "${d}" DELETE https://crates.io/api/v1/trusted_publishing/tokens 204 /dev/null
  digest=$(awk '$2 == "probe-b-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  index "${d}" probe-b "0.1.0=${digest}"
  run_script "${d}" crate-publish/publish-step.sh DIRECTORY="${d}/release" DIGEST="${DIGEST}" VERSION=0.1.0 \
    PUBLISH='["probe-b"]' CRATES_IO=https://crates.io INDEX=https://index.crates.io \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example/token?x=1' 3<<<request-token
}

case_the_token_is_masked_first_revoked_and_never_an_argument() {
  local d first n masked left
  d=$(fresh token_failure)
  world "${d}"
  publish_step "${d}" 500
  expect "${d}" 75 'crates.io refused probe-b 0.1.0 (500)'
  first=$(grep -n cio_tp_secretsecretsecret "${d}/stdout" "${d}/stderr" | head -n1)
  masked=$(cut -d: -f3- <<<"${first}")
  [[ ${masked} == '::add-mask::cio_tp_secretsecretsecret' ]] || fail "the token is first written as [${first}]"
  n=$(grep -v '^::add-mask::' "${d}/stdout" "${d}/stderr" | grep -c cio_tp_secretsecretsecret || true)
  [[ ${n} == 0 ]] || fail 'the token is written outside its mask'
  n=$(grep -c 'oidc-jwt-value\|cio_tp_secret\|request-token' "${d}/stub/argv" || true)
  [[ ${n} == 0 ]] || fail 'a token is an argument'
  calls_are "${d}" $'\tDELETE\thttps://crates.io/api/v1/trusted_publishing/tokens' 1
  left=$(find "${d}/temp" -mindepth 1)
  [[ -z ${left} ]] || fail "the step left ${left}"
  d=$(fresh token_success)
  world "${d}"
  publish_step "${d}" 200
  expect "${d}" 0 'published probe-b 0.1.0'
  calls_are "${d}" $'\tDELETE\thttps://crates.io/api/v1/trusted_publishing/tokens' 1
  n=$(grep -n $'\tPUT\t' "${d}/stub/calls" | cut -d: -f1)
  cmp -s "${d}/stub/sent.${n}" "${d}/release/probe-b-0.1.0.upload" || fail 'the body sent is not the signed one'
  grep -qxF 'Authorization: cio_tp_secretsecretsecret' "${d}/stub/headers" || fail 'the upload carried no token header'
}

case_the_publication_step_runs_as_its_action_step_runs_it() {
  local d digest
  d=$(fresh publish_wired)
  world "${d}"
  printf '{"value":"oidc-jwt-value"}' >"${d}/oidc"
  route "${d}" GET 'https://oidc.example/token?x=1&audience=crates.io' 200 "${d}/oidc"
  printf '{"token":"cio_tp_secretsecretsecret"}' >"${d}/exchange"
  route "${d}" POST https://crates.io/api/v1/trusted_publishing/tokens 200 "${d}/exchange"
  printf '{}' >"${d}/put"
  route "${d}" PUT https://crates.io/api/v1/crates/new 200 "${d}/put"
  route "${d}" DELETE https://crates.io/api/v1/trusted_publishing/tokens 204 /dev/null
  digest=$(awk '$2 == "probe-b-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  index "${d}" probe-b "0.1.0=${digest}"
  input=([directory]="${d}/release" [digest]="${DIGEST}" [version]=0.1.0)
  over=([PUBLISH]='["probe-b"]')
  caller+=(ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token 'ACTIONS_ID_TOKEN_REQUEST_URL=https://oidc.example/token?x=1')
  wired "${d}" crate-publish 1
  expect "${d}" 0 'published probe-b 0.1.0'
}

# A fresh clone of shuwariafrica/.github in <case>/clone, from an origin whose main holds this tree's
# owner-publish.sh, crate-publish's lib.sh and release-key's published.sh, each lib.sh touching a
# marker in the case when sourced: lib-main on main's commit (OWN_COMMIT), lib-side on a commit of
# the branch side alone (SIDE_COMMIT).
dot_github() {
  local d=$1 origin=$1/origin
  mkdir -p -- "${origin}/actions/crate-publish" "${origin}/actions/release-key"
  cp -- "${TREE}/actions/crate-publish/owner-publish.sh" "${origin}/actions/crate-publish/"
  cp -- "${TREE}/actions/release-key/published.sh" "${origin}/actions/release-key/"
  { cat -- "${TREE}/actions/crate-publish/lib.sh" && printf ': >%q\n' "${d}/lib-main"; } >"${origin}/actions/crate-publish/lib.sh"
  git init --quiet -b main -- "${origin}"
  git -C "${origin}" add -A
  git -C "${origin}" -c user.name=t -c user.email=t@example.invalid commit --quiet --no-gpg-sign -m main
  OWN_COMMIT=$(git -C "${origin}" rev-parse HEAD)
  git -C "${origin}" checkout --quiet -b side
  printf ': >%q\n' "${d}/lib-side" >>"${origin}/actions/crate-publish/lib.sh"
  git -C "${origin}" -c user.name=t -c user.email=t@example.invalid commit --quiet --no-gpg-sign -am side
  SIDE_COMMIT=$(git -C "${origin}" rev-parse HEAD)
  git -C "${origin}" checkout --quiet main
  git clone --quiet -- "${origin}" "${d}/clone"
}

# The owner's line over the case's world, as the act runs it: the script taken from the clone at
# <own> (OWN_COMMIT by default) and run by bash from its standard input, the token on descriptor 3;
# the run 4242's artefacts as gh downloads them.
owner_line() {
  local d=$1 token=$2 crate=${3:-probe-b} own=${4:-} status=0
  mkdir -p -- "${d}/stub/artifacts/4242/package" "${d}/stub/artifacts/4242/signature"
  find "${d}/release" -maxdepth 1 -type f ! -name SHA256SUMS.asc -exec cp -- {} "${d}/stub/artifacts/4242/package/" \;
  cp -- "${d}/release/SHA256SUMS.asc" "${d}/stub/artifacts/4242/signature/"
  printf '%s\n' "${ID}" >"${d}/stub/repository-id"
  printf '{}' >"${d}/put"
  route "${d}" PUT https://crates.io/api/v1/crates/new 200 "${d}/put"
  [[ -d ${d}/clone ]] || dot_github "${d}"
  [[ -n ${own} ]] || own=${OWN_COMMIT}
  git -C "${d}/clone" show "${own}:actions/crate-publish/owner-publish.sh" |
    env -i PATH="${d}/bin:/usr/bin:/bin" HOME="${WORK}" GIT_BASE="file://${d}/git" \
      bash -s -- "${d}/clone" "${own}" shuwariafrica/probe v0.1.0 4242 "${crate}" 3<<<"${token}" \
      >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
}

# A crates.io token's shape (cio and 32 characters, owner-publish.sh), assembled here so the tree holds
# no literal a secret scanner reads as one.
readonly OWNER_TOKEN="cio$(printf '%032d' 0)"

# .github's helpers as raw.githubusercontent.com would serve them at OWN_COMMIT, so a script that
# fetched them would run as well, and only the marker and the recorded calls tell.
served() {
  local d=$1
  route "${d}" GET "https://raw.githubusercontent.com/shuwariafrica/.github/${OWN_COMMIT}/actions/crate-publish/lib.sh" 200 \
    "${TREE}/actions/crate-publish/lib.sh"
  route "${d}" GET "https://raw.githubusercontent.com/shuwariafrica/.github/${OWN_COMMIT}/actions/release-key/published.sh" 200 \
    "${TREE}/actions/release-key/published.sh"
}

case_the_owners_line_reads_its_helpers_from_the_clone() {
  local d
  d=$(fresh owner_clone)
  world "${d}"
  dot_github "${d}"
  served "${d}"
  owner_line "${d}" "${OWNER_TOKEN}"
  expect "${d}" 0 'crates.io took probe-b 0.1.0'
  [[ -e ${d}/lib-main ]] || fail "lib.sh was not read from the clone at ${OWN_COMMIT}"
  [[ ! -e ${d}/lib-side ]] || fail 'lib.sh was read at another commit'
}

case_the_owners_line_refuses_a_commit_not_on_main_before_reading_any_helper() {
  local d
  d=$(fresh owner_side)
  world "${d}"
  dot_github "${d}"
  owner_line "${d}" "${OWNER_TOKEN}" probe-b "${SIDE_COMMIT}"
  expect "${d}" 1 "${SIDE_COMMIT} is not on shuwariafrica/.github's main"
  [[ ! -e ${d}/lib-side && ! -e ${d}/lib-main ]] || fail 'a helper was read'
  [[ ! -s ${d}/stub/gh ]] || fail 'the artefacts were downloaded'
  calls_are "${d}" . 0
}

case_the_owners_line_fetches_no_dot_github_code() {
  local d
  d=$(fresh owner_no_fetch)
  world "${d}"
  dot_github "${d}"
  served "${d}"
  owner_line "${d}" "${OWNER_TOKEN}"
  expect "${d}" 0 'crates.io took probe-b 0.1.0'
  calls_are "${d}" 'githubusercontent|shuwariafrica/\.github' 0
}

case_the_owners_line_verifies_the_runs_artefacts_and_sends_the_token_to_curl_on_standard_input() {
  local d token=${OWNER_TOKEN} n
  d=$(fresh owner)
  world "${d}"
  owner_line "${d}" "${token}"
  expect "${d}" 0 'crates.io took probe-b 0.1.0'
  n=$(grep -c "${token}" "${d}/stub/argv" || true)
  [[ ${n} == 0 ]] || fail 'the token is an argument'
  [[ $(<"${d}/stub/stdin") == "Authorization: ${token}" ]] || fail "curl's standard input is $(<"${d}/stub/stdin")"
  n=$(grep -n $'\tPUT\t' "${d}/stub/calls" | cut -d: -f1)
  cmp -s "${d}/stub/sent.${n}" "${d}/release/probe-b-0.1.0.upload" || fail 'the body sent is not the signed one'
  grep -q '^run download 4242 --repo shuwariafrica/probe --name package' "${d}/stub/gh" || fail 'the package artefact was not downloaded'
  n=$(calls "${d}" 'releases/download')
  [[ ${n} == 0 ]] || fail 'the release was read'
}

case_the_owners_line_sends_nothing_unverified() {
  local d token=${OWNER_TOKEN} home
  d=$(fresh owner_changed)
  world "${d}"
  printf 'changed\n' >>"${d}/release/probe-b-0.1.0.upload"
  owner_line "${d}" "${token}"
  expect "${d}" 1 'is not the file SHA256SUMS signed: nothing is sent'
  calls_are "${d}" $'\tPUT\t' 0
  d=$(fresh owner_other_signer)
  world "${d}" stranger
  owner_line "${d}" "${token}"
  expect "${d}" 1 'not one good signature'
  calls_are "${d}" $'\tPUT\t' 0
  d=$(fresh owner_revoked)
  home=$(own_key signing owner)
  world "${d}" "${home}"
  catalogue_repo "${d}" . "${home}"
  revoke_subkey "${home}"
  g "${home}" --armor --export "${SIGNING_KEY}" >"${d}/published.asc"
  sed -i '/keyserver.ubuntu.com\|keys.openpgp.org/d' "${d}/stub/routes"
  keyservers "${d}" "${SIGNING_KEY}" "${d}/published.asc"
  owner_line "${d}" "${token}"
  expect "${d}" 1 'which the keyservers publish as revoked'
  calls_are "${d}" $'\tPUT\t' 0
  d=$(fresh owner_short)
  world "${d}"
  owner_line "${d}" short
  expect "${d}" 1 'that is not a crates.io token'
  calls_are "${d}" . 0
}

crates_main "$@"
