#!/usr/bin/env bash
# Runs crate-sign's steps over a release made here (tests/crates.sh): the check step's hold on the
# run's pins and package's files, the keyservers' revocations, sqv's install, and the whole action
# signing through release-key's scripts against stand-ins for GitHub's OIDC, Entra and Key Vault.
# Usage: run.sh [--tree <directory>] [<case>...]; tests/crates.sh says the rest.
# Needs gpg, gpgconf, sqv in /usr/bin, git, jq, yq (mikefarah's), sha256sum, dpkg-deb and python3.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
# shellcheck source=tests/step.sh
. "${HERE}/../step.sh"
# shellcheck source=tests/crates.sh
. "${HERE}/../crates.sh"
TOOLS=(/usr/bin/sqv dpkg-deb python3)

readonly SHA=1111111111111111111111111111111111111111
readonly API_FILE="https://api.github.com/repos/shuwariafrica/probe/contents/.github/workflows/release.yml?ref=${SHA}"

# The certificate of the key home <home> as keys.openpgp.org serves one whose address is not
# verified, into <out>: its packets with each user id, and the signatures after it, dropped; with
# <drop> `subkeys`, each subkey and its signatures too.
uidless() {
  local home=$1 out=$2 drop=${3:-} fpr
  fpr=$(primary_of "${home}")
  g "${home}" --export "${fpr}" >"${out}.full"
  python3 -I - "${out}.full" "${out}" "${drop}" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
dropped = {13, 14} if sys.argv[3] == "subkeys" else {13}
out, i, dropping = bytearray(), 0, False
while i < len(data):
    start, b = i, data[i]
    if b & 0x40:
        tag, i = b & 0x3F, i + 1
        if data[i] < 192:
            n, i = data[i], i + 1
        elif data[i] < 224:
            n, i = ((data[i] - 192) << 8) + data[i + 1] + 192, i + 2
        else:
            n, i = int.from_bytes(data[i + 1:i + 5], "big"), i + 5
    else:
        tag, kind, i = (b >> 2) & 0x0F, b & 3, i + 1
        size = (1, 2, 4)[kind]
        n, i = int.from_bytes(data[i:i + size], "big"), i + size
    if tag in dropped:
        dropping = True
    elif tag != 2:
        dropping = False
    if not dropping:
        out += data[start:i + n]
    i += n
open(sys.argv[2], "wb").write(out)
PY
  ! grep -qF "${home} <" "${out}" || fail "the certificate served still holds its user id"
}

# keys.openpgp.org's answer for the project's key: <file>, or the signing key's certificate without
# its user id; keyserver.ubuntu.com's left as it is.
vks() {
  local d=$1 file=${2:-}
  if [[ -z ${file} ]]; then
    file=${d}/vks.pgp
    uidless signing "${file}"
  fi
  sed -i '/keys.openpgp.org/d' "${d}/stub/routes"
  route "${d}" GET "https://keys.openpgp.org/vks/v1/by-fingerprint/${SIGNING_KEY}" 200 "${file}"
}

# A case's world: public-crates, a release in <case>/release from crate-package, the run's
# release.yml (lifted from the template, edited by <edit>) as GitHub's API serves it,
# keyserver.ubuntu.com holding nothing and keys.openpgp.org the project's certificate.
world() {
  local d=$1 edit=${2:-.}
  catalogue_repo "${d}"
  release_dir "${d}/release"
  rm -- "${d}/release/SHA256SUMS.asc"
  release_yml "${d}/release.yml" "${edit}"
  route "${d}" GET "${API_FILE}" 200 "${d}/release.yml"
  keyservers "${d}" "${SIGNING_KEY}"
  vks "${d}"
}

# public-crates' main in the case <dir> moved on by one commit, its files changed by the command
# <change>... run in the repository.
catalogue_moves() {
  local repo=$1/git/shuwariafrica/public-crates
  shift
  (cd -- "${repo}" && "$@")
  git -C "${repo}" add -A
  git -C "${repo}" -c user.name=t -c user.email=t@example.invalid commit --quiet --no-gpg-sign -m moved
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

# The run's release.yml is the template lifted, and nothing else: a step the template does not hold,
# a comment it does not hold, a placeholder left as it is, each refused before the key is read.
case_a_release_yml_holding_anything_the_template_does_not_is_refused_before_the_key() {
  local d
  d=$(fresh run_step)
  world "${d}"
  sed -i 's|^\(      - uses: actions/checkout@.*\)$|\1\n      - run: printenv|' "${d}/release.yml"
  grep -qx '      - run: printenv' "${d}/release.yml" || fail 'the step was not added'
  check "${d}"
  expect "${d}" 1 "release.yml is not public-crates' template at its gate-commit ${GATE}"
  expect "${d}" 1 'line 20 is [      - run: printenv], and the template makes it [      - uses: shuwariafrica/.github/actions/crate-package@'
  calls_are "${d}" 'vault|keys.openpgp.org|keyserver' 0
  d=$(fresh comment)
  world "${d}"
  sed -i '1a # a line the template does not hold' "${d}/release.yml"
  check "${d}"
  expect "${d}" 1 'line 2 is [# a line the template does not hold], and the template makes it []'
  d=$(fresh placeholder)
  world "${d}"
  sed -i "3s/${OWN}/${PLACEHOLDER_OWN}/" "${d}/release.yml"
  grep -q "^# Lifted from public-crates' template/: ${PLACEHOLDER_OWN}" "${d}/release.yml" || fail 'the placeholder was not put back'
  check "${d}"
  expect "${d}" 1 "line 3 is [# Lifted from public-crates' template/: ${PLACEHOLDER_OWN}"
}

# crate-admit, crate-sign and crate-publish hold release.yml through one definition, lib.sh's, so
# the rule cannot differ between them: each function is defined once under actions/, in
# crate-publish/lib.sh, and each step script sources that file and calls release_yml_holds. That
# the call holds is each action's own hold case.
case_the_three_holds_of_release_yml_are_lib_shs_one_definition() {
  local name found entry script source
  for name in lifted_release_yml release_yml_holds; do
    found=$(grep -rlE "^[[:space:]]*(function[[:space:]]+)?${name}[[:space:]]*\\(\\)" "${TREE}/actions" || true) # none is answered below
    [[ ${found} == "${TREE}/actions/crate-publish/lib.sh" ]] || fail "${name} is defined in [${found//$'\n'/ }], not in lib.sh alone"
  done
  # shellcheck disable=SC2016
  # Each script's source line, as text.
  for entry in 'crate-admit/admit-step.sh ${HERE}/../crate-publish/lib.sh' \
    'crate-sign/check-step.sh ${here}/../crate-publish/lib.sh' 'crate-publish/check-step.sh ${here}/lib.sh'; do
    read -r script source <<<"${entry}"
    grep -qxF "  source \"${source}\"" "${TREE}/actions/${script}" || fail "${script} does not source ${source}"
    grep -qE '^  release_yml_holds "' "${TREE}/actions/${script}" || fail "${script} does not call release_yml_holds"
  done
}

# The template is gate-commit's, not main's: a release.yml lifted from main's template, once main
# has moved on, is refused, and one lifted from gate-commit's still signs.
case_release_yml_is_held_to_the_template_at_gate_commit() {
  local d
  d=$(fresh template_at_gate)
  world "${d}"
  catalogue_moves "${d}" tee -a template/.github/workflows/release.yml <<<'# main has moved on' >/dev/null
  check "${d}"
  expect "${d}" 0 "signing for shuwariafrica/probe with ${SIGNING_KEY}"
  d=$(fresh template_at_main)
  world "${d}"
  catalogue_moves "${d}" tee -a template/.github/workflows/release.yml <<<'# main has moved on' >/dev/null
  printf '# main has moved on\n' >>"${d}/release.yml"
  check "${d}"
  expect "${d}" 1 "release.yml is not public-crates' template at its gate-commit ${GATE}"
}

# verify's list is one entry per platform of the project, in projects.json's order, each with
# platforms.json's runner.
case_verify_lists_the_projects_platforms_in_their_order() {
  local d both='          - platform: windows-x64\n            runner: windows-2025-vs2026\n          - platform: linux-x64'
  d=$(fresh platforms_in_order)
  world "${d}"
  catalogue_repo "${d}" '.platforms = ["windows-x64", "linux-x64"]'
  sed -i "s|^          - platform: linux-x64\$|${both}|" "${d}/release.yml"
  grep -qx '          - platform: windows-x64' "${d}/release.yml" || fail 'the platforms were not written'
  check "${d}"
  expect "${d}" 0 'signing for'
  d=$(fresh platforms_other_order)
  world "${d}"
  catalogue_repo "${d}" '.platforms = ["linux-x64", "windows-x64"]'
  sed -i "s|^          - platform: linux-x64\$|${both}|" "${d}/release.yml"
  check "${d}"
  expect "${d}" 1 'line 27 is [          - platform: windows-x64], and the template makes it [          - platform: linux-x64]'
  d=$(fresh platforms_template)
  world "${d}"
  catalogue_repo "${d}" '.platforms = ["windows-x64", "linux-x64"]'
  check "${d}"
  expect "${d}" 1 'line 27 is [          - platform: linux-x64], and the template makes it [          - platform: windows-x64]'
}

# keys.openpgp.org, where a user's check fetches the certificate (the release's design, 2.8), serves
# it by its fingerprint, or nothing is signed.
case_a_key_keys_openpgp_org_does_not_serve_is_refused() {
  local d
  d=$(fresh vks_none)
  world "${d}"
  sed -i '/keys.openpgp.org/d' "${d}/stub/routes"
  route "${d}" GET "https://keys.openpgp.org/vks/v1/by-fingerprint/${SIGNING_KEY}" 404 /dev/null
  check "${d}"
  expect "${d}" 1 "keys.openpgp.org serves no certificate for the project's key ${SIGNING_KEY}"
  d=$(fresh vks_other)
  world "${d}"
  g stranger --export "${STRANGER_KEY}" >"${d}/stranger.pgp"
  vks "${d}" "${d}/stranger.pgp"
  check "${d}"
  expect "${d}" 1 "keys.openpgp.org serves [${STRANGER_KEY}] for the project's key ${SIGNING_KEY}"
}

# A signing key's certificate in a new key home <name>, for an attacker, armored into <out>: no user
# id, so gpg's import skips it, and a direct-key signature (made by adding the signing key as
# designated revoker), which binds it for a reader that takes the file whole, as sqv does. The
# armor is a public key block, the only header gpg reads a second block under.
hidden_certificate() {
  local name=$1 out=$2 fpr
  make_key "${name}" cert never subkey
  fpr=$(primary_of "${name}")
  g signing --export "${SIGNING_KEY}" | g "${name}" --import
  printf 'addrevoker\n%s\ny\nsave\n' "${SIGNING_KEY}" | g "${name}" --command-fd 0 --edit-key "${fpr}"
  uidless "${name}" "${out}.bin"
  g "${name}" --enarmor <"${out}.bin" | sed -e 's/ARMORED FILE/PUBLIC KEY BLOCK/' -e '/^Comment:/d' >"${out}"
}

# signing-keys/<name>.asc is read as a user's sqv reads it, whole: a second primary after the
# project's, one gpg's import skips for want of a user id, is refused, naming both primaries.
case_a_hidden_second_primary_in_the_certificate_file_is_refused() {
  local d hidden imported listed
  d=$(fresh hidden_primary)
  world "${d}"
  hidden_certificate hidden "${d}/hidden.asc"
  hidden=$(primary_of hidden)
  catalogue_moves "${d}" tee -a signing-keys/probe.asc <"${d}/hidden.asc" >/dev/null
  mkdir -m 700 -- "${WORK}/keys/hidden_import"
  g hidden_import --import "${d}/git/shuwariafrica/public-crates/signing-keys/probe.asc"
  imported=$(g hidden_import --with-colons --list-keys | awk -F: '$1 == "pub" {n++} END {print n + 0}')
  listed=$(g hidden_import --with-colons --show-keys "${d}/git/shuwariafrica/public-crates/signing-keys/probe.asc" |
    awk -F: '$1 == "pub" {n++} END {print n + 0}')
  [[ ${imported} == 1 && ${listed} == 2 ]] || fail "gpg's import holds ${imported} primaries and the file ${listed}, not 1 and 2"
  check "${d}"
  expect "${d}" 1 "signing-keys/probe.asc holds [${SIGNING_KEY} ${hidden}], not the project's signing_key ${SIGNING_KEY} alone"
}

# keys.openpgp.org's copy is merged by a user's sqv only where it holds the signing subkey the
# project's certificate does, so a copy without it is refused, naming the subkey; the copy as
# keys.openpgp.org serves a key (the primary and its signing subkey, no user id) is admitted.
case_a_served_copy_without_the_signing_subkey_is_refused() {
  local d
  d=$(fresh vks_no_subkey)
  world "${d}"
  uidless signing "${d}/primary-alone.pgp" subkeys
  vks "${d}" "${d}/primary-alone.pgp"
  check "${d}"
  expect "${d}" 1 "keys.openpgp.org serves the project's key ${SIGNING_KEY} without its signing subkey ${SIGNING_SUBKEY}"
  d=$(fresh vks_with_subkey)
  world "${d}"
  check "${d}"
  expect "${d}" 0 "signing for shuwariafrica/probe with ${SIGNING_KEY}"
}

# A release.yml the pins' second read of it cannot read is refused, not taken as holding no
# action: a yq that answers the first read and fails the second.
case_a_release_yml_that_does_not_read_again_is_refused() {
  local d found
  d=$(fresh second_read)
  world "${d}"
  # shellcheck disable=SC2016
  # The stand-in's own text, expanded when it runs.
  printf '#!/usr/bin/env bash\ncase $2 in *unique*) exec /usr/bin/yq "$@" ;; *) echo "yq: killed" >&2; exit 1 ;; esac\n' >"${d}/bin/yq"
  chmod 755 -- "${d}/bin/yq"
  found=$(PATH=${d}/bin:/usr/bin:/bin type -P yq)
  [[ ${found} == "${d}/bin/yq" ]] || fail 'yq does not resolve to the stand-in'
  check "${d}"
  expect "${d}" 1 'release.yml does not read as YAML: yq: killed'
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
