#!/usr/bin/env bash
# Runs crate-sign's steps over a release made here (tests/crates.sh): the check step's hold on the
# run's pins and package's files, the keyservers' revocations, sqv's install, and the whole action
# signing through release-key's scripts against stand-ins for GitHub's OIDC, Entra and Key Vault.
# Usage: run.sh [--tree <directory>] [<case>...]; tests/crates.sh says the rest.
# Needs gpg, gpgconf, sqv in /usr/bin, git, jq, yq (mikefarah's), sha256sum and dpkg-deb.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
# shellcheck source=tests/step.sh
. "${HERE}/../step.sh"
# shellcheck source=tests/crates.sh
. "${HERE}/../crates.sh"
TOOLS=(/usr/bin/sqv dpkg-deb)

readonly SHA=1111111111111111111111111111111111111111
readonly API_FILE="https://api.github.com/repos/shuwariafrica/probe/contents/.github/workflows/release.yml?ref=${SHA}"

# A case's world: public-crates, a release in <case>/release from crate-package, the run's
# release.yml (edited by <edit>) as GitHub's API serves it, keyservers holding nothing.
world() {
  local d=$1 edit=${2:-.}
  catalogue_repo "${d}"
  release_dir "${d}/release"
  rm -- "${d}/release/SHA256SUMS.asc"
  release_yml "${d}/release.yml" "${edit}"
  route "${d}" GET "${API_FILE}" 200 "${d}/release.yml"
  keyservers "${d}" "${SIGNING_KEY}"
}

check() {
  local d=$1 path=${ACTION_PATH_OVER:-}
  [[ -n ${path} ]] || path=$(action_path crate-sign)
  run_script "${d}" crate-sign/check-step.sh REPOSITORY=shuwariafrica/probe REPOSITORY_ID="${ID}" REF=refs/tags/v0.1.0 \
    SHA="${SHA}" WORKFLOW_REF="${WORKFLOW_REF_OVER:-shuwariafrica/probe/.github/workflows/release.yml@refs/tags/v0.1.0}" \
    DIRECTORY="${d}/release" DIGEST="${DIGEST_OVER:-${DIGEST}}" API=https://api.github.com \
    GITHUB_ACTION_PATH="${path}" 3<<<job-token
}

case_the_runs_pins_and_files_admit_signing() {
  local d
  d=$(fresh admitted)
  world "${d}"
  check "${d}"
  expect "${d}" 0 "signing for shuwariafrica/probe with ${SIGNING_KEY}"
  out_is "${d}" fingerprint "${SIGNING_KEY}"
  grep -qxF 'Authorization: Bearer job-token' "${d}/stub/headers" || fail 'release.yml was not read with the job token'
  [[ $(grep -c job-token "${d}/stub/argv" || true) == 0 ]] || fail 'the job token is an argument'
}

case_a_dot_github_action_at_another_commit_is_refused() {
  local d
  d=$(fresh dot_github_other)
  world "${d}" ".jobs.package.steps[1].uses = \"shuwariafrica/.github/actions/crate-package@${COMMIT_OFF}\""
  check "${d}"
  expect "${d}" 1 "crate-package@${COMMIT_OFF} is not at ${OWN}"
  d=$(fresh dot_github_case)
  world "${d}" ".jobs.admit.steps[0].uses = \"ShuwariAfrica/.GitHub/actions/crate-admit@${COMMIT_OFF}\""
  check "${d}"
  expect "${d}" 1 "crate-admit@${COMMIT_OFF} is not at ${OWN}"
}

case_a_public_crates_action_off_gate_commit_is_refused() {
  local d
  d=$(fresh public_crates_other)
  world "${d}" ".jobs.verify.steps[0].uses = \"shuwariafrica/public-crates/.github/actions/checks@${COMMIT_OFF}\""
  check "${d}"
  expect "${d}" 1 "checks@${COMMIT_OFF} is not at ${GATE}, public-crates' gate-commit"
}

case_a_third_party_action_off_its_listed_commit_is_refused() {
  local d
  d=$(fresh third_party_other)
  world "${d}" ".jobs.package.steps[0].uses = \"actions/checkout@${COMMIT_OFF}\""
  check "${d}"
  expect "${d}" 1 "actions/checkout@${COMMIT_OFF} is not on shuwariafrica/.github's actions/third-party.tsv"
  d=$(fresh third_party_unlisted)
  world "${d}" '.jobs.verify.steps += [{"uses": "someone/evil@1234567890123456789012345678901234567890"}]'
  check "${d}"
  expect "${d}" 1 "someone/evil@1234567890123456789012345678901234567890 is not on"
}

case_an_action_behind_an_alias_or_in_a_parallel_group_is_held() {
  local d
  d=$(fresh alias)
  world "${d}"
  sed -i 's|^permissions: {}$|permissions: {}\nx-evil: \&evil\n  uses: someone/evil@1234567890123456789012345678901234567890|' "${d}/release.yml"
  yq -i '.jobs.admit.steps += [{"name": "behind an alias"}] | .jobs.admit.steps[-1] alias = "evil"' "${d}/release.yml"
  grep -q '\*evil' "${d}/release.yml" || fail 'the alias was not written'
  check "${d}"
  expect "${d}" 1 'someone/evil@1234567890123456789012345678901234567890 is not on'
  d=$(fresh parallel)
  world "${d}" '.jobs.admit.steps += [{"parallel": [{"uses": "someone/evil@1234567890123456789012345678901234567890"}]}]'
  check "${d}"
  expect "${d}" 1 'someone/evil@1234567890123456789012345678901234567890 is not on'
  d=$(fresh reusable)
  world "${d}" '.jobs.other = {"uses": "someone/evil/.github/workflows/x.yml@1234567890123456789012345678901234567890"}'
  check "${d}"
  expect "${d}" 1 'someone/evil/.github/workflows/x.yml@1234567890123456789012345678901234567890 is not on'
}

case_another_workflow_or_an_action_at_no_commit_is_refused() {
  local d
  d=$(fresh other_workflow)
  world "${d}"
  WORKFLOW_REF_OVER=shuwariafrica/probe/.github/workflows/other.yml@refs/tags/v0.1.0 check "${d}"
  expect "${d}" 1 "not shuwariafrica/probe's release.yml on a v tag"
  d=$(fresh action_at_main)
  world "${d}"
  ACTION_PATH_OVER=${WORK}/_actions/shuwariafrica/.github/main/actions/crate-sign check "${d}"
  expect "${d}" 1 'this action runs at main, not at a full commit'
}

case_sums_unlike_packages_output_are_refused() {
  local d
  d=$(fresh sums_unlike)
  world "${d}"
  DIGEST_OVER=$(printf '%064d' 1) check "${d}"
  expect "${d}" 1 'and package made'
  d=$(fresh file_unlike)
  world "${d}"
  printf 'changed\n' >>"${d}/release/order"
  check "${d}"
  expect "${d}" 1 'is not the one SHA256SUMS names'
}

case_a_primary_the_keyservers_publish_as_revoked_is_refused() {
  local d home
  d=$(fresh primary_revoked)
  home=$(own_key signing primary)
  world "${d}"
  printf 'y\n1\nretired\n\ny\n' | gpg --homedir "${WORK}/keys/${home}" --no-tty --pinentry-mode loopback --passphrase '' \
    --command-fd 0 --output "${d}/primary.rev" --gen-revoke "${SIGNING_KEY}" 2>>"${WORK}/gpg.log"
  g "${home}" --import "${d}/primary.rev"
  g "${home}" --armor --export "${SIGNING_KEY}" >"${d}/published.asc"
  sed -i '/keyserver.ubuntu.com\|keys.openpgp.org/d' "${d}/stub/routes"
  keyservers "${d}" "${SIGNING_KEY}" "${d}/published.asc"
  check "${d}"
  expect "${d}" 1 "the keyservers publish the project's key ${SIGNING_KEY} as revoked"
}

case_a_subkey_the_keyservers_publish_as_revoked_is_refused_before_signing() {
  local d home revoked
  d=$(fresh subkey_revoked)
  home=$(own_key signing subkey)
  world "${d}"
  revoke_subkey "${home}"
  g "${home}" --armor --export "${SIGNING_KEY}" >"${d}/published.asc"
  sed -i '/keyserver.ubuntu.com\|keys.openpgp.org/d' "${d}/stub/routes"
  keyservers "${d}" "${SIGNING_KEY}" "${d}/published.asc"
  check "${d}"
  expect "${d}" 0 'signing for'
  revoked=$(output_of "${d}" revoked)
  [[ ${revoked} == "${SIGNING_SUBKEY}" ]] || fail "revoked is [${revoked}]"
  run_script "${d}" crate-sign/standing.sh SUBKEY="${SIGNING_SUBKEY}" REVOKED="${revoked}"
  expect "${d}" 1 "publish the signing subkey ${SIGNING_SUBKEY} as revoked"
  run_script "${d}" crate-sign/standing.sh SUBKEY="${SIGNING_SUBKEY}" REVOKED="${STRANGER_KEY}"
  expect "${d}" 0 'is not revoked'
}

case_a_keyserver_that_does_not_answer_refuses() {
  local d
  d=$(fresh silent)
  world "${d}"
  sed -i '/keyserver.ubuntu.com/d' "${d}/stub/routes"
  route "${d}" GET "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${SIGNING_KEY}" 000 /dev/null
  check "${d}"
  expect "${d}" 75 'the keyservers did not answer'
}

# A Debian package holding ./usr/bin/sqv, a script that prints a version, into <file>.
fake_sqv() {
  local d=$1 file=$2
  mkdir -p -- "${d}/deb/usr/bin" "${d}/deb/DEBIAN"
  printf 'Package: sqv\nVersion: 1.3.0-3ubuntu1\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: t\n' >"${d}/deb/DEBIAN/control"
  printf '#!/bin/sh\necho "sqv 1.3.0 (stand-in)"\n' >"${d}/deb/usr/bin/sqv"
  chmod 755 "${d}/deb/usr/bin/sqv"
  dpkg-deb --build --root-owner-group "${d}/deb" "${file}" >/dev/null
}

case_sqv_is_installed_from_the_package_its_digest_names_alone() {
  local d digest status=0 mode
  d=$(fresh sqv)
  fake_sqv "${d}" "${d}/sqv.deb"
  route "${d}" GET https://archive.example/sqv.deb 200 "${d}/sqv.deb"
  digest=$(sha256sum "${d}/sqv.deb" | cut -d' ' -f1)
  run_script "${d}" crate-sign/sqv.sh
  [[ $(<"${d}/status") == 64 ]] || fail 'no arguments were taken'
  env -i PATH="${d}/bin:/usr/bin:/bin" bash --noprofile --norc "${TREE}/actions/crate-sign/sqv.sh" \
    "${d}/temp/sqv" https://archive.example/sqv.deb "$(printf '%064d' 3)" "${d}/installed" >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
  expect "${d}" 65 'is not the one this action fixes'
  [[ ! -e ${d}/installed ]] || fail 'a package of another digest was installed'
  status=0
  env -i PATH="${d}/bin:/usr/bin:/bin" bash --noprofile --norc "${TREE}/actions/crate-sign/sqv.sh" \
    "${d}/temp/sqv2" https://archive.example/sqv.deb "${digest}" "${d}/installed" >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
  expect "${d}" 0 'sqv 1.3.0 (stand-in), installed as'
  cmp -s "${d}/installed" "${d}/deb/usr/bin/sqv" || fail 'the installed sqv is not the package'"'"'s'
  mode=$(stat -c %a "${d}/installed")
  [[ ${mode} == 755 ]] || fail "the installed sqv's mode is ${mode}"
  grep -q "^-n install -m 755 -- .*/package/usr/bin/sqv ${d}/installed\$" "${d}/stub/sudo" || fail "sudo ran $(<"${d}/stub/sudo")"
}

# The vault's stand-ins: the OIDC request, Entra's grant and Key Vault's secret `subkey` of the
# project's vault, holding the export of the key home <key>'s subkey.
vault() {
  local d=$1 key=$2
  printf '{"value":"oidc-assertion"}' >"${d}/assertion"
  route "${d}" GET https://token.example/request 200 "${d}/assertion"
  printf '{"access_token":"vault-token"}' >"${d}/access"
  route "${d}" POST https://login.microsoftonline.com/tenant/oauth2/v2.0/token 200 "${d}/access"
  g "${key}" --armor --export-secret-subkeys >"${d}/export.asc"
  jq -Rs '{value: .}' "${d}/export.asc" >"${d}/secret.json"
  route "${d}" GET "https://shuwari-cr-${ID}.vault.azure.net/secrets/subkey?api-version=2025-07-01" 200 "${d}/secret.json"
}

# The action's steps as the runner runs them, in order, sqv's install aside, which the case
# before this one runs; stops at the first that fails.
sign_steps() {
  local d=$1 subkey revoked home
  input=(["tenant-id"]=tenant ["client-id"]=client ["vault-url"]="https://shuwari-cr-${ID}.vault.azure.net"
    [directory]="${d}/release" [digest]="${DIGEST}")
  caller+=(ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/request)
  over=([TOKEN]=job-token [REPOSITORY]=shuwariafrica/probe [REPOSITORY_ID]="${ID}" [REF]=refs/tags/v0.1.0 [SHA]="${SHA}"
    [WORKFLOW_REF]=shuwariafrica/probe/.github/workflows/release.yml@refs/tags/v0.1.0 [GIT_BASE]="file://${d}/git")
  wired "${d}" crate-sign 0
  [[ $(<"${d}/status") == 0 ]] || return 0
  over=([FINGERPRINT]="$(output_of "${d}" fingerprint)")
  wired "${d}" crate-sign 2
  cp -- "${d}/stdout" "${d}/import.stdout"
  [[ $(<"${d}/status") == 0 ]] || return 0
  subkey=$(output_of "${d}" subkey)
  revoked=$(output_of "${d}" revoked)
  over=([SUBKEY]="${subkey}" [REVOKED]="${revoked}")
  wired "${d}" crate-sign 3
  [[ $(<"${d}/status") == 0 ]] || return 0
  home=$(output_of "${d}" gnupghome)
  over=([GNUPGHOME]="${home}" [SUBKEY]="${subkey}"
    [REPOSITORY_REF]="${ID}:refs/tags/v0.1.0")
  wired "${d}" crate-sign 4
}

case_the_action_signs_with_the_projects_key_from_its_own_vault_and_leaves_no_key() {
  local d line status left
  d=$(fresh signs)
  world "${d}"
  vault "${d}" signing
  sign_steps "${d}"
  expect "${d}" 0 'verified under gpg and sqv: 1 signatures'
  grep -q 'release key: subkey' "${d}/import.stdout" || fail 'the import named no project key'
  while IFS= read -r line; do
    [[ -n ${line//[[:space:]]/} ]] || continue
    grep -qxF -- "::add-mask::${line}" "${d}/import.stdout" || fail "a line of the export is not masked: ${line:0:20}"
  done <"${d}/export.asc"
  calls_are "${d}" "secrets/subkey\\?" 1
  status=$(GNUPGHOME=$(mktemp -d) && gpg --homedir "${GNUPGHOME}" --batch --quiet --import "${d}/git/shuwariafrica/public-crates/signing-keys/probe.asc" 2>/dev/null &&
    gpg --homedir "${GNUPGHOME}" --batch --status-fd 1 --verify "${d}/release/SHA256SUMS.asc" "${d}/release/SHA256SUMS" 2>/dev/null)
  [[ ${status} == *" ${SIGNING_KEY}"* && ${status} == *GOODSIG* ]] || fail 'SHA256SUMS.asc is not a good signature by the signing key'
  [[ -d ${d}/temp/release-gnupg ]] || fail 'no home to remove'
  wired "${d}" crate-sign 5
  expect "${d}" 0 "the signing key's home is gone"
  [[ ! -e ${d}/temp/release-gnupg ]] || fail 'the home is still there'
  left=$(grep -rls 'PRIVATE KEY' "${d}/temp" || true) # none is the answer
  [[ -z ${left} ]] || fail "a file of the key is left: ${left}"
}

case_a_key_whose_primary_is_not_signing_key_is_refused() {
  local d
  d=$(fresh other_key)
  world "${d}"
  vault "${d}" stranger
  sign_steps "${d}"
  expect "${d}" 65 "not the published ${SIGNING_KEY}"
  [[ ! -e ${d}/release/SHA256SUMS.asc ]] || fail 'SHA256SUMS was signed'
}

case_the_home_is_removed_however_the_steps_before_ended() {
  local d condition
  d=$(fresh remove_after_failure)
  mkdir -p -- "${d}/temp/release-gnupg"
  : >"${d}/temp/release-gnupg/private-keys"
  wired "${d}" crate-sign 5
  expect "${d}" 0 "the signing key's home is gone"
  [[ ! -e ${d}/temp/release-gnupg ]] || fail 'the home is still there'
  condition=$(yq '.runs.steps[5].if' "${TREE}/actions/crate-sign/action.yml")
  [[ ${condition} == 'always()' ]] || fail "the removal runs on ${condition}"
}

crates_main "$@"
