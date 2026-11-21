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

# A case's world: public-crates, the project at the run's commit RUN_SHA with its release.yml
# lifted from the template, a release in <case>/release signed by <key>, keyservers holding nothing
# for the project's key, and crates.io holding probe-a as signed and probe-b, bound to trusted
# publishing alone and owned by the project's owner, at an earlier version.
world() {
  local d=$1 key=${2:-signing} digest
  catalogue_repo "${d}"
  project_repo "${d}"
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
    REF=refs/tags/v0.1.0 SHA="${RUN_SHA}" \
    WORKFLOW_REF="${WORKFLOW_REF_OVER:-shuwariafrica/probe/.github/workflows/release.yml@refs/tags/v0.1.0}" \
    RUN_ID=4242 DIRECTORY="${d}/release" DIGEST="${DIGEST_OVER:-${DIGEST}}" VERSION=0.1.0 \
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
  over=([REPOSITORY]=shuwariafrica/probe [REPOSITORY_ID]="${ID}" [REF]=refs/tags/v0.1.0 [SHA]="${RUN_SHA}"
    [WORKFLOW_REF]=shuwariafrica/probe/.github/workflows/release.yml@refs/tags/v0.1.0 [RUN_ID]=4242
    [GIT_BASE]="file://${d}/git")
  wired "${d}" crate-publish 0
  expect "${d}" 0 'to publish: probe-b'
}

# The run is release.yml's, and release.yml at the run's commit is the template lifted, before any
# token: a step the template does not hold is refused.
case_a_release_yml_holding_anything_the_template_does_not_is_refused_before_any_token() {
  local d
  d=$(fresh run_step)
  world "${d}"
  release_yml "${d}/release.yml"
  sed -i 's|^\(      - uses: shuwariafrica/.github/actions/crate-publish@.*\)$|      - run: printenv\n\1|' "${d}/release.yml"
  grep -qx '      - run: printenv' "${d}/release.yml" || fail 'the step was not added'
  project_repo "${d}" "${d}/release.yml"
  check "${d}"
  expect "${d}" 1 "release.yml is not public-crates' template at its gate-commit ${GATE}"
  expect "${d}" 1 'is [      - run: printenv], and the template makes it [      - uses: shuwariafrica/.github/actions/crate-publish@'
  no_token "${d}"
  calls_are "${d}" 'crates.io' 0
  d=$(fresh other_workflow)
  world "${d}"
  WORKFLOW_REF_OVER=shuwariafrica/probe/.github/workflows/other.yml@refs/tags/v0.1.0 check "${d}"
  expect "${d}" 1 "not shuwariafrica/probe's release.yml"
  no_token "${d}"
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

# Two crates crates.io does not hold: the summary says the signed order binds the owner's lines,
# and gives each crate's lines in that order.
case_the_summary_binds_the_owners_lines_to_the_signed_order() {
  local d summary
  d=$(fresh order_binds)
  world "${d}"
  index "${d}" probe-a
  index "${d}" probe-b
  sed -i '\|crates.io/api/v1/crates/probe-|d' "${d}/stub/routes"
  route "${d}" GET https://crates.io/api/v1/crates/probe-a 404 /dev/null
  route "${d}" GET https://crates.io/api/v1/crates/probe-b 404 /dev/null
  check "${d}"
  expect "${d}" 1 'crates.io does not hold probe-a probe-b: the owner publishes each first, in the order this run'"'"'s summary lists them'
  summary=$(<"${d}/summary")
  # shellcheck disable=SC2016
  # The summary's Markdown, quoted as it is written.
  [[ ${summary} == *'## crates.io does not hold `probe-a`, `probe-b`: the owner publishes them in this order'* ]] ||
    fail 'the summary does not give the order' "${summary}"
  [[ ${summary} == *"it binds the owner's lines"*'a new crate that depends on another new crate of this release is published after that one'* ]] ||
    fail 'the summary does not say the order binds' "${summary}"
  [[ ${summary} == *'## probe-a 0.1.0 is new'*'## probe-b 0.1.0 is new'* ]] || fail "the crates' lines are not in the signed order"
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
# <status> with the answer <file> (`{}` by default), PUBLISH_OVER (probe-b alone by default) to
# publish, DIGEST_OVER for package's digest; the index holds probe-b as signed; the OIDC request
# token on descriptor 3.
publish_step() {
  local d=$1 status=$2 answer=${3:-} digest
  printf '{"value":"oidc-jwt-value"}' >"${d}/oidc"
  route "${d}" GET 'https://oidc.example/token?x=1&audience=crates.io' 200 "${d}/oidc"
  printf '{"token":"cio_tp_secretsecretsecret"}' >"${d}/exchange"
  route "${d}" POST https://crates.io/api/v1/trusted_publishing/tokens 200 "${d}/exchange"
  if [[ -z ${answer} ]]; then
    answer=${d}/put
    printf '{}' >"${answer}"
  fi
  route "${d}" PUT https://crates.io/api/v1/crates/new "${status}" "${answer}"
  route "${d}" DELETE https://crates.io/api/v1/trusted_publishing/tokens 204 /dev/null
  digest=$(awk '$2 == "probe-b-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  index "${d}" probe-b "0.1.0=${digest}"
  run_script "${d}" crate-publish/publish-step.sh DIRECTORY="${d}/release" DIGEST="${DIGEST_OVER:-${DIGEST}}" VERSION=0.1.0 \
    PUBLISH="${PUBLISH_OVER:-[\"probe-b\"]}" CRATES_IO=https://crates.io INDEX=https://index.crates.io \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example/token?x=1' 3<<<request-token
}

# No token is on the argument list of any process the step starts: curl's (the stand-in's record),
# and every other's (record_processes), jq's among them.
case_the_token_is_masked_first_revoked_and_never_an_argument() {
  local d first n masked left
  d=$(fresh token_failure)
  world "${d}"
  record_processes "${d}"
  publish_step "${d}" 500
  expect "${d}" 75 'probe-b 0.1.0 (500): {}'
  grep -q '^jq ' "${d}/stub/processes" || fail 'no jq the step ran was recorded'
  grep -q '^bash .*publish-step.sh' "${d}/stub/processes" || fail 'the step itself was not recorded'
  left=$(grep 'oidc-jwt-value\|cio_tp_secret\|request-token' "${d}/stub/processes" || true) # none is the answer
  [[ -z ${left} ]] || fail 'an argument list carries a token:' "${left}"
  first=$(grep -n cio_tp_secretsecretsecret "${d}/stdout" "${d}/stderr" | head -n1 || true) # none is answered below
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

# The step holds SHA256SUMS to package's digest again before it asks for any token.
case_the_publication_step_holds_sums_to_packages_digest_before_any_token() {
  local d
  d=$(fresh step_digest)
  world "${d}"
  DIGEST_OVER=$(printf '%064d' 1) publish_step "${d}" 200
  expect "${d}" 1 "SHA256SUMS is ${DIGEST}, and package made $(printf '%064d' 1)"
  calls_are "${d}" . 0
}

# Each body is held to SHA256SUMS before its PUT: one changed after the check step is not sent.
case_the_publication_step_sends_no_body_unlike_its_sum() {
  local d
  d=$(fresh step_body)
  world "${d}"
  printf 'changed\n' >>"${d}/release/probe-b-0.1.0.upload"
  publish_step "${d}" 200
  expect "${d}" 1 'probe-b-0.1.0.upload is not the body SHA256SUMS signed'
  calls_are "${d}" $'\tPUT\t' 0
  calls_are "${d}" $'\tDELETE\thttps://crates.io/api/v1/trusted_publishing/tokens' 1
}

# Two crates in one step: each body goes out in the signed order, the second only once the index
# shows the first at its signed digest, read again ten seconds after it did not.
case_two_crates_go_out_in_order_each_after_the_index_shows_the_one_before() {
  local d a b sequence want n found
  d=$(fresh two_crates)
  world "${d}"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q/stub/sleeps\n' "${d}" >"${d}/bin/sleep"
  chmod 755 -- "${d}/bin/sleep"
  found=$(PATH=${d}/bin:/usr/bin:/bin type -P sleep)
  [[ ${found} == "${d}/bin/sleep" ]] || fail 'sleep does not resolve to the stand-in'
  a=$(awk '$2 == "probe-a-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  b=$(awk '$2 == "probe-b-0.1.0.crate" {print $1}' "${d}/release/SHA256SUMS")
  sed -i '\|^GET https://index.crates.io/pr/ob/probe-a\t|d' "${d}/stub/routes"
  jq -nc '{name: "probe-a", vers: "0.0.9", cksum: "0000"}' >"${d}/index-a-before"
  jq -nc --arg c "${a}" '{name: "probe-a", vers: "0.0.9", cksum: "0000"}, {name: "probe-a", vers: "0.1.0", cksum: $c}' >"${d}/index-a-after"
  route "${d}" GET https://index.crates.io/pr/ob/probe-a 200 "${d}/index-a-before" once
  route "${d}" GET https://index.crates.io/pr/ob/probe-a 200 "${d}/index-a-after"
  PUBLISH_OVER='["probe-a","probe-b"]' publish_step "${d}" 200
  expect "${d}" 0 'published probe-b 0.1.0'
  sequence=$(awk -F'\t' '$3 ~ /crates\/new$|index\.crates\.io/ {print $2, $3}' "${d}/stub/calls")
  want='PUT https://crates.io/api/v1/crates/new
GET https://index.crates.io/pr/ob/probe-a
GET https://index.crates.io/pr/ob/probe-a
PUT https://crates.io/api/v1/crates/new
GET https://index.crates.io/pr/ob/probe-b'
  [[ ${sequence} == "${want}" ]] || fail 'the calls are not each PUT, then the index until it shows that crate:' "${sequence}"
  grep -qx 10 "${d}/stub/sleeps" || fail "the step did not wait ten seconds for the index: $(<"${d}/stub/sleeps")"
  n=$(grep -n $'\tPUT\t' "${d}/stub/calls" | cut -d: -f1 | paste -sd' ')
  read -r a b <<<"${n}"
  cmp -s "${d}/stub/sent.${a}" "${d}/release/probe-a-0.1.0.upload" || fail 'the first body sent is not probe-a'"'"'s'
  cmp -s "${d}/stub/sent.${b}" "${d}/release/probe-b-0.1.0.upload" || fail 'the second body sent is not probe-b'"'"'s'
}

# crates.io's refusal of a body (a 4xx other than 401, 403 or 429) fails the step with crates.io's
# own words, as no re-run is taken; a 429, like a 5xx, leaves it to a re-run.
case_a_body_crates_io_refuses_fails_and_one_it_defers_is_left_to_a_re_run() {
  local d
  d=$(fresh refused)
  world "${d}"
  printf '{"errors":[{"detail":"missing or empty metadata fields: description"}]}' >"${d}/refusal"
  publish_step "${d}" 400 "${d}/refusal"
  expect "${d}" 1 'crates.io refused probe-b 0.1.0 (400): missing or empty metadata fields: description: a re-run is refused the same way, and only a new version completes the release'
  calls_are "${d}" $'\tDELETE\thttps://crates.io/api/v1/trusted_publishing/tokens' 1
  d=$(fresh unprocessable)
  world "${d}"
  printf '{"errors":[{"detail":"unprocessable"}]}' >"${d}/refusal"
  publish_step "${d}" 422 "${d}/refusal"
  expect "${d}" 1 'crates.io refused probe-b 0.1.0 (422): unprocessable: a re-run is refused the same way, and only a new version completes the release'
  d=$(fresh busy)
  world "${d}"
  printf '{"errors":[{"detail":"You have published too many new crates in a short period of time."}]}' >"${d}/busy"
  publish_step "${d}" 429 "${d}/busy"
  expect "${d}" 75 'crates.io did not take probe-b 0.1.0 (429): You have published too many new crates'
}

# crates.io's refusal of the token (403 for one lapsed or unknown, 401 for a header it cannot read)
# is the token's, never the body's: the step leaves it to a re-run, which takes a new token.
case_a_token_crates_io_refuses_is_left_to_a_re_run_with_a_new_one() {
  local d status detail
  for status in 403 401; do
    detail='Invalid authentication token'
    [[ ${status} == 403 ]] || detail="Missing \`Authorization\` header"
    d=$(fresh "token_refused_${status}")
    world "${d}"
    jq -nc --arg d "${detail}" '{errors: [{detail: $d}]}' >"${d}/refusal"
    publish_step "${d}" "${status}" "${d}/refusal"
    expect "${d}" 75 "crates.io refused the token for probe-b 0.1.0 (${status}): ${detail}: a re-run takes a new token and skips the crates already published"
    calls_are "${d}" $'\tDELETE\thttps://crates.io/api/v1/trusted_publishing/tokens' 1
  done
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
# <own> (OWN_COMMIT by default) and run by bash from its standard input, the token on descriptor 3,
# with OWNER_ENV's further variables; the run 4242's artefacts as gh downloads them. The script
# reads public-crates at github.com alone, and sets git's configuration aside but for its command
# line, so a git first on the line's PATH runs the real one with github.com rewritten to the case.
owner_line() {
  local d=$1 token=$2 crate=${3:-probe-b} own=${4:-} status=0 found
  mkdir -p -- "${d}/stub/artifacts/4242/package" "${d}/stub/artifacts/4242/signature"
  find "${d}/release" -maxdepth 1 -type f ! -name SHA256SUMS.asc -exec cp -- {} "${d}/stub/artifacts/4242/package/" \;
  cp -- "${d}/release/SHA256SUMS.asc" "${d}/stub/artifacts/4242/signature/"
  printf '%s\n' "${ID}" >"${d}/stub/repository-id"
  printf '{}' >"${d}/put"
  route "${d}" PUT https://crates.io/api/v1/crates/new 200 "${d}/put"
  [[ -d ${d}/clone ]] || dot_github "${d}"
  [[ -n ${own} ]] || own=${OWN_COMMIT}
  printf '#!/usr/bin/env bash\nexec /usr/bin/git -c url.%q.insteadOf=https://github.com/ "$@"\n' "file://${d}/git/" >"${d}/bin/git"
  chmod 755 -- "${d}/bin/git"
  found=$(PATH=${d}/bin:/usr/bin:/bin type -P git)
  [[ ${found} == "${d}/bin/git" ]] || fail 'git does not resolve to the stand-in'
  git -C "${d}/clone" show "${own}:actions/crate-publish/owner-publish.sh" |
    env -i PATH="${d}/bin:/usr/bin:/bin" HOME="${WORK}" "${OWNER_ENV[@]}" \
      bash -s -- "${d}/clone" "${own}" shuwariafrica/probe v0.1.0 4242 "${crate}" 3<<<"${token}" \
      >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
}

# A crates.io token's shape (cio and 32 characters, owner-publish.sh), assembled here so the tree holds
# no literal a secret scanner reads as one.
readonly OWNER_TOKEN="cio$(printf '%032d' 0)"
OWNER_ENV=()

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

# A GIT_BASE in the owner's environment chooses no public-crates of its own.
case_the_owners_line_reads_public_crates_at_github_whatever_its_environment_names() {
  local d
  d=$(fresh owner_git_base)
  world "${d}"
  OWNER_ENV=("GIT_BASE=file://${d}/elsewhere")
  owner_line "${d}" "${OWNER_TOKEN}"
  expect "${d}" 0 'crates.io took probe-b 0.1.0'
}

# git's variables in the owner's environment choose nothing for the line: neither git configuration,
# which git takes as its own command line's (here a rewrite of public-crates' address to a
# repository elsewhere), nor another repository, nor another transport program.
case_the_owners_line_reads_public_crates_at_github_whatever_its_git_environment_names() {
  local d
  d=$(fresh owner_git_environment)
  world "${d}"
  git init --quiet --bare -- "${d}/elsewhere.git"
  OWNER_ENV=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.file://${d}/elsewhere/shuwariafrica/public-crates.insteadOf"
    GIT_CONFIG_VALUE_0=https://github.com/shuwariafrica/public-crates
    "GIT_CONFIG_PARAMETERS='url.file://${d}/elsewhere/shuwariafrica/public-crates.insteadof'='https://github.com/shuwariafrica/public-crates'"
    "GIT_DIR=${d}/elsewhere.git" GIT_SSH_COMMAND=false)
  owner_line "${d}" "${OWNER_TOKEN}"
  expect "${d}" 0 'crates.io took probe-b 0.1.0'
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
