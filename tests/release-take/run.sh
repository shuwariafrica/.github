#!/usr/bin/env bash
# Runs the release-take action's step against stand-in releases, as the runner runs it: action.yml's
# shell, its `run` and its step env written over the caller's environment. Nothing leaves the
# machine: gh is the stand-in beside this script, installed by the take's own tools.sh from a file://
# archive; sqv is this machine's, packaged as Ubuntu's is; both keyservers are one http.server on
# 127.0.0.1; every key is made here. Only the tool and keyserver variables of the step env are
# replaced, by these stand-ins'.
# Usage: run.sh [--tree <directory>] [--fixtures <directory>] [<case>...]
#   --tree      a tree holding actions/release-take and actions/release-key; this repository's by
#               default, a mutated copy from mutants.sh;
#   --fixtures  where the keys and stand-in tools are made once and reused; a new directory by default.
# Prints `ok` or `FAIL` per case and the counts. Exit 0 when every case named (all by default)
# passed; 1 when one failed; 64 for usage; 69 for an absent tool.
# Needs gpg, gpgconf, sqv, dpkg-deb, python3, yq (mikefarah's), jq, curl, sha256sum and GNU tar.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
tree=$(cd -- "${here}/../.." && pwd)
fixtures=''
cases=()
while (($# > 0)); do
  case $1 in
    --tree)
      tree=$(cd -- "$2" && pwd)
      shift 2
      ;;
    --fixtures)
      mkdir -p -- "$2"
      fixtures=$(cd -- "$2" && pwd)
      shift 2
      ;;
    -*)
      printf 'usage: run.sh [--tree <directory>] [--fixtures <directory>] [<case>...]\n' >&2
      exit 64
      ;;
    *)
      cases+=("$1")
      shift
      ;;
  esac
done
for tool in gpg gpgconf sqv dpkg-deb python3 yq jq curl sha256sum tar mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
yq_version=$(yq --version)
[[ ${yq_version} == *mikefarah* ]] || {
  printf 'yq is not mikefarah'"'"'s: %s\n' "${yq_version}" >&2
  exit 69
}

readonly ID=1295027104 REPOSITORY=shuwariafrica/azkaban TAG=v1.2.3 WORKFLOW=.github/workflows/gate.yml
readonly COMMIT=3f786850e387550fdab836ed7e6dc881de23001b OBJECT=89e6c98d92887913cadf06b2adb97f26cde4849b
readonly TOKEN=take-token
# shellcheck disable=SC2016 # the opening of a GitHub expression, as text
readonly EXPRESSION='${{'
readonly ACTION="${tree}/actions/release-take/action.yml"

owned=''
[[ -n ${fixtures} ]] || {
  fixtures=$(mktemp -d)
  owned=${fixtures}
}
readonly fixtures
server=''
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  local home sqv
  [[ -z ${server} ]] || kill "${server}" 2>/dev/null || true # it may have ended on its own
  for home in "${fixtures}"/keys/*/; do
    gpgconf --homedir "${home}" --kill all 2>/dev/null || true # its agent may never start
  done
  [[ -z ${owned} ]] || rm -rf -- "${owned}"
}
trap cleanup EXIT

g() { # home, gpg argument...
  local home=$1
  shift
  gpg --homedir "${fixtures}/keys/${home}" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"
}

fingerprint() { # home: the primary's fingerprint
  g "$1" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}'
}

subkey() { # home: the signing subkey's fingerprint
  g "$1" --with-colons --list-keys | awk -F: '$1 == "sub" && $12 ~ /s/ {want = 1; next} $1 == "fpr" && want {print $10; exit}'
}

key() { # home, user id, usage of the primary, signing subkey (yes or no), gpg option...
  local home=$1 uid=$2 usage=$3 sub=$4 primary
  shift 4
  mkdir -m 700 "${fixtures}/keys/${home}"
  g "${home}" "$@" --quick-gen-key "${uid}" ed25519 "${usage}" 2y
  if [[ ${sub} == yes ]]; then
    primary=$(fingerprint "${home}")
    g "${home}" "$@" --quick-add-key "${primary}" ed25519 sign 2y
  fi
}

revoked() { # home, file: its public key with its revocation, exported from a home of its own
  local primary
  primary=$(fingerprint "$1")
  mkdir -m 700 "${fixtures}/keys/$1-revoked"
  g "$1" --export | g "$1-revoked" --import
  sed 's/^:-----BEGIN/-----BEGIN/' "${fixtures}/keys/$1/openpgp-revocs.d/${primary}.rev" | g "$1-revoked" --import
  g "$1-revoked" --armor --export >"$2"
}

# The keys and the stand-in tools, made once per fixtures directory.
make_fixtures() {
  local home sqv
  [[ ! -f ${fixtures}/ready ]] || return 0
  rm -rf -- "${fixtures:?}"/*
  mkdir -p "${fixtures}/keys" "${fixtures}/public" "${fixtures}/tools/gh_2.103.3_linux_amd64/bin" \
    "${fixtures}/tools/sqv/DEBIAN" "${fixtures}/tools/sqv/usr/bin"
  key c1 'C1 <c1@shuwari.africa>' cert yes
  key impostor 'C1 <c1@shuwari.africa>' cert yes
  key alice 'Alice <alice@shuwari.africa>' cert yes
  key bob 'Bob <bob@shuwari.africa>' sign,cert no
  key carol 'Carol <carol@shuwari.africa>' sign,cert no
  key dave 'Dave <dave@shuwari.africa>' sign,cert no
  key mallory 'Mallory <mallory@example.com>' sign,cert no
  mkdir -m 700 "${fixtures}/keys/erin"
  g erin --faked-system-time 20200101T000000! --quick-gen-key 'Erin <erin@shuwari.africa>' ed25519 sign,cert 1d
  for home in c1 impostor alice bob dave mallory; do
    g "${home}" --armor --export >"${fixtures}/public/${home}.asc"
  done
  g erin --armor --export >"${fixtures}/public/erin.asc"
  # Carol's admitted copy holds her revocation; Dave's is published by the keyservers alone. Each
  # is revoked in a home of its own, so the signing homes still sign.
  revoked carol "${fixtures}/public/carol.asc"
  cp -- "${fixtures}/public/dave.asc" "${fixtures}/public/dave-unrevoked.asc"
  revoked dave "${fixtures}/public/dave-revoked.asc"

  sed "s|@DATA@|${fixtures}/current/github|" "${here}/gh" >"${fixtures}/tools/gh_2.103.3_linux_amd64/bin/gh"
  chmod 755 "${fixtures}/tools/gh_2.103.3_linux_amd64/bin/gh"
  tar --create --gzip --file "${fixtures}/tools/gh.tar.gz" --directory "${fixtures}/tools" gh_2.103.3_linux_amd64
  sqv=$(command -v sqv)
  cp -- "${sqv}" "${fixtures}/tools/sqv/usr/bin/sqv"
  printf 'Package: sqv\nVersion: 1.3.0-0test\nArchitecture: amd64\nMaintainer: tests\nDescription: stand-in\n' \
    >"${fixtures}/tools/sqv/DEBIAN/control"
  dpkg-deb --root-owner-group --build "${fixtures}/tools/sqv" "${fixtures}/tools/sqv.deb" >/dev/null
  : >"${fixtures}/ready"
}

digest() { # file
  local sum
  sum=$(sha256sum -- "$1")
  printf '%s\n' "${sum%% *}"
}

# The tag object's payload naming <commit> and <tag>, signed by <home>'s primary or signing subkey.
sign_tag() { # case directory, home, primary or subkey, commit, tag, gpg option...
  local directory=$1 home=$2 commit=$4 tag=$5 signer
  if [[ $3 == primary ]]; then
    signer=$(fingerprint "${home}")
  else
    signer=$(subkey "${home}")
  fi
  shift 5
  printf 'object %s\ntype commit\ntag %s\ntagger Release <core@shuwari.africa> 1762700000 +0000\n\nRelease %s\n' \
    "${commit}" "${tag}" "${tag}" >"${directory}/payload"
  rm -f -- "${directory}/signature"
  g "${home}" "$@" --armor --detach-sign --local-user "${signer}!" --output "${directory}/signature" "${directory}/payload"
}

tag_document() { # case directory: the API's answers for the ref and the tag object
  local directory=$1 api="$1/github/api/repos/${REPOSITORY}/git"
  mkdir -p "${api}/ref/tags" "${api}/tags"
  jq -n --arg tag "${TAG}" --arg object "${OBJECT}" '{ref: ("refs/tags/" + $tag), object: {type: "tag", sha: $object}}' \
    >"${api}/ref/tags/${TAG}.json"
  jq -n --arg tag "${TAG}" --arg object "${OBJECT}" --arg commit "${COMMIT}" \
    --rawfile payload "${directory}/payload" --rawfile signature "${directory}/signature" \
    '{sha: $object, tag: $tag, object: {type: "commit", sha: $commit}, verification: {verified: true, payload: $payload, signature: $signature}}' \
    >"${api}/tags/${OBJECT}.json"
}

release_dir() { # case directory
  printf '%s/github/releases/%s/%s\n' "$1" "${REPOSITORY}" "${TAG}"
}

# SHA256SUMS over every file of the release but itself and its signature, signed by <home> through
# release-key's sign.sh as C1's release job signs it.
sign_sums() { # case directory, home, notation
  local release sub
  release=$(release_dir "$1")
  sub=$(subkey "$2")
  (cd "${release}" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%P\0' | sort -z | xargs -0 sha256sum --) >"${release}/SHA256SUMS"
  rm -f -- "${release}/SHA256SUMS.asc"
  "${tree}/actions/release-key/sign.sh" "${fixtures}/keys/$2" "${sub}" "$3" "${release}/SHA256SUMS" >/dev/null
}

# A stand-in bundle line for <file>, as a Fulcio certificate of <workflow> at the tag would show it;
# a jq <edit> changes it.
attest() { # case directory, file name, jq edit
  local release sum
  release=$(release_dir "$1")
  sum=$(digest "${release}/$2")
  mkdir -p "$1/github/attestations/${REPOSITORY}"
  jq -n -c --arg name "$2" --arg digest "${sum}" --arg id "${ID}" --arg repository "${REPOSITORY}" \
    --arg workflow "${WORKFLOW}" --arg tag "${TAG}" --arg commit "${COMMIT}" '{
      certificate: {
        issuer: "https://token.actions.githubusercontent.com",
        subjectAlternativeName: ("https://github.com/" + $repository + "/" + $workflow + "@refs/tags/" + $tag),
        sourceRepositoryURI: ("https://github.com/" + $repository),
        sourceRepositoryIdentifier: $id,
        sourceRepositoryOwnerURI: "https://github.com/shuwariafrica",
        sourceRepositoryOwnerIdentifier: "93454356",
        sourceRepositoryRef: ("refs/tags/" + $tag),
        sourceRepositoryDigest: $commit,
        runnerEnvironment: "github-hosted"},
      statement: {predicateType: "https://slsa.dev/provenance/v1", subject: [{name: $name, digest: {sha256: $digest}}]}
    } | '"${3:-.}" >>"$1/github/attestations/${REPOSITORY}/${sum}.jsonl"
}

attest_all() { # case directory
  local release name
  release=$(release_dir "$1")
  for name in "${release}"/*; do
    name=${name##*/}
    [[ ${name} == SHA256SUMS* ]] || attest "$1" "${name}"
  done
}

# A coherent release: the action's tree with its roots, the API's answers, the release signed and
# attested, an empty keyserver, workspace and runner temp. Each case changes one thing of it.
world() { # case name: prints the case directory
  local directory="${fixtures}/cases/$1" release name
  rm -rf -- "${directory}"
  mkdir -p "${directory}/tree/signing/core-keys" "${directory}/github/api/repositories" "${directory}/keyserver" \
    "${directory}/workspace" "${directory}/temp" "${directory}/planted"
  cp -R -- "${tree}/actions" "${directory}/tree/"
  cp -- "${fixtures}/public/c1.asc" "${directory}/tree/signing/c1-public.asc"
  for name in alice bob carol erin; do
    cp -- "${fixtures}/public/${name}.asc" "${directory}/tree/signing/core-keys/${name}.asc"
  done
  cp -- "${fixtures}/public/dave-unrevoked.asc" "${directory}/tree/signing/core-keys/dave.asc"
  jq -n --argjson id "${ID}" --arg name "${REPOSITORY}" '{id: $id, owner: {id: 93454356}, full_name: $name}' \
    >"${directory}/github/api/repositories/${ID}.json"
  sign_tag "${directory}" bob primary "${COMMIT}" "${TAG}"
  tag_document "${directory}"
  release=$(release_dir "${directory}")
  mkdir -p "${release}"
  head -c 4096 /dev/urandom >"${release}/azkaban_1.2.3_amd64.deb"
  printf 'notes\n' >"${release}/notes.txt"
  sign_sums "${directory}" c1 "${ID}:refs/tags/${TAG}"
  attest_all "${directory}"
  : >"${directory}/output"
  printf '%s\n' "${directory}"
}

# What a case gives the take, beside its world.
declare -A input=()
declare -A over=()
caller=()

reset() {
  input=(["repository-id"]="${ID}" [tag]="${TAG}" [workflow]="${WORKFLOW}" [path]=members/core [token]="${TOKEN}")
  over=([TAKE_GH_URL]="file://${fixtures}/tools/gh.tar.gz" [TAKE_SQV_URL]="file://${fixtures}/tools/sqv.deb"
    [TAKE_HKP]="http://127.0.0.1:${port}" [TAKE_VKS]="http://127.0.0.1:${port}")
  over[TAKE_GH_SHA256]=$(digest "${fixtures}/tools/gh.tar.gz")
  over[TAKE_SQV_SHA256]=$(digest "${fixtures}/tools/sqv.deb")
  caller=(PATH=/usr/bin:/bin "HOME=${fixtures}/home" LANG=C.UTF-8)
}

# Runs action.yml's step in <directory>'s world as the runner would; leaves status, stdout and
# stderr in the directory.
take() { # case directory
  local directory=$1 shell script key value line status
  local -a step words lines
  ln -sfn -- "${directory}" "${fixtures}/current"
  : >"${directory}/github/calls"
  : >"${directory}/github/env"
  shell=$(yq -r '.runs.steps[0].shell' "${directory}/tree/actions/release-take/action.yml")
  yq -r '.runs.steps[0].run' "${directory}/tree/actions/release-take/action.yml" >"${directory}/step.sh"
  script="${directory}/step.sh"
  line=$(yq -r '.runs.steps[0].env | to_entries | .[] | .key + "=" + (.value | @json)' "${directory}/tree/actions/release-take/action.yml")
  mapfile -t lines <<<"${line}"
  step=()
  for line in "${lines[@]}"; do
    key=${line%%=*}
    value=$(jq -r . <<<"${line#*=}")
    if [[ -n ${over[${key}]+set} ]]; then
      value=${over[${key}]}
    elif [[ ${value} =~ ^\$\{\{\ inputs\.([a-z-]+)\ \}\}$ ]]; then
      value=${input[${BASH_REMATCH[1]}]}
    elif [[ ${value} == *"${EXPRESSION}"* ]]; then
      printf 'run.sh: the step env holds %s, which this harness does not stand in for\n' "${line}" >&2
      exit 70
    fi
    step+=("${key}=${value}")
  done
  # The runner's own template for `shell: bash`; any other shell is a command line of its own.
  [[ ${shell} != bash ]] || shell='bash --noprofile --norc -e -o pipefail {0}'
  read -r -a words <<<"${shell//\{0\}/${script}}"
  status=0
  (cd "${directory}/workspace" && env -i "${caller[@]}" "${step[@]}" RUNNER_TEMP="${directory}/temp" \
    GITHUB_OUTPUT="${directory}/output" GITHUB_WORKSPACE="${directory}/workspace" \
    GITHUB_ACTION_PATH="${directory}/tree/actions/release-take" "${words[@]}") \
    >"${directory}/stdout" 2>"${directory}/stderr" || status=$?
  printf '%s\n' "${status}" >"${directory}/status"
}

# Assertions: each prints why it failed and returns 1.
fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

snapshot() { # case directory: what the workspace holds before the take
  (cd "$1/workspace" && find . -mindepth 1 | sort) >"$1/before"
}

untouched() { # case directory: the workspace as it was, the output empty, nothing left in temp
  local after left
  [[ -f $1/before ]] || : >"$1/before"
  after=$(cd "$1/workspace" && find . -mindepth 1 | sort)
  [[ ${after} == "$(<"$1/before")" ]] || fail "the workspace changed: ${after}"
  [[ ! -s $1/output ]] || fail "GITHUB_OUTPUT holds $(<"$1/output")"
  left=$(find "$1/temp" -mindepth 1 -maxdepth 1)
  [[ -z ${left} ]] || fail "RUNNER_TEMP holds ${left}"
}

refused() { # case directory, exit status, text stderr must hold
  local status tail
  status=$(<"$1/status")
  tail=$(tail -n 5 "$1/stderr")
  [[ ${status} == "$2" ]] || fail "exit ${status}, not $2" "${tail}"
  grep -qF -- "$3" "$1/stderr" || fail "stderr lacks: $3" "${tail}"
  untouched "$1"
}

admitted() { # case directory, path
  local status release name placed held tail left
  status=$(<"$1/status")
  tail=$(tail -n 5 "$1/stderr")
  [[ ${status} == 0 ]] || fail "exit ${status}" "${tail}"
  [[ $(<"$1/output") == "commit=${COMMIT}" ]] || fail "GITHUB_OUTPUT holds $(<"$1/output")"
  release=$(release_dir "$1")
  placed=$(cd "$1/workspace/$2" && find . -mindepth 1 -printf '%y %P\n' | sort)
  held=$(cd "${release}" && find . -mindepth 1 -printf '%y %P\n' | sort)
  [[ ${placed} == "${held}" ]] || fail "placed: ${placed}"
  for name in "${release}"/*; do
    cmp -s -- "${name}" "$1/workspace/$2/${name##*/}" || fail "${name##*/} differs"
  done
  left=$(find "$1/temp" -mindepth 1 -maxdepth 1)
  [[ -z ${left} ]] || fail "RUNNER_TEMP holds ${left}"
  left=$(find "$1/workspace" -name '.release-take.*')
  [[ -z ${left} ]] || fail "a staging directory is left: ${left}"
}

# The cases, one per refusal of each of the contract's items, and the admitted paths.

case_admit_primary() {
  local d calls expected fingerprints request requests count
  d=$(world admit_primary)
  take "${d}"
  admitted "${d}" members/core
  # Item 9: gh fetched the named release and its proofs and nothing else.
  calls=$(sed -E 's/release-take\.[A-Za-z0-9]+/W/g; s|'"${d}"'|D|g' "${d}/github/calls")
  expected="gh --version
gh api repositories/${ID} --jq $(printf '%q' '"\(.id) \(.owner.id) \(.full_name)"')
gh api repos/${REPOSITORY}/git/ref/tags/${TAG} --jq $(printf '%q' '"\(.ref) \(.object.type) \(.object.sha)"')
gh api repos/${REPOSITORY}/git/tags/${OBJECT} --jq $(printf '%q' '"\(.sha) \(.object.type) \(.object.sha) \(.tag)"')
gh api repos/${REPOSITORY}/git/tags/${OBJECT} --jq $(printf '%q' '.verification.payload // empty | @base64')
gh api repos/${REPOSITORY}/git/tags/${OBJECT} --jq $(printf '%q' '.verification.signature // empty | @base64')
gh release download ${TAG} --repo ${REPOSITORY} --dir D/temp/W/release"
  count=$(head -n 7 <<<"${calls}")
  [[ ${count} == "${expected}" ]] || fail "gh was called otherwise: ${calls}"
  count=$(grep -c '^gh attestation download D/temp/W/release/[a-z_.0-9]* --repo shuwariafrica/azkaban$' <<<"${calls}")
  [[ ${count} == 2 ]] || fail "attestation downloads: ${calls}"
  count=$(grep -c "^gh attestation verify .* --repo ${REPOSITORY} --signer-workflow github.com/${REPOSITORY}/${WORKFLOW}@refs/tags/${TAG} --source-ref refs/tags/${TAG} --source-digest ${COMMIT} --deny-self-hosted-runners --format json --jq " <<<"${calls}")
  [[ ${count} == 2 ]] || fail "attestation verifications: ${calls}"
  count=$(wc -l <<<"${calls}")
  [[ ${count} == 11 ]] || fail "gh calls: ${calls}"
  # Each keyserver request is a lookup of C1 or an admitted primary.
  fingerprints=$(for name in c1 alice bob carol dave erin; do fingerprint "${name}"; done)
  # The last twelve requests are this case's: both keyservers, for C1 and the five admitted keys.
  requests=$(sed -n 's/.*"GET \([^ ]*\) HTTP.*/\1/p' "${fixtures}/keyserver.log" | tail -n 12)
  while IFS= read -r request; do
    [[ ${request} =~ ^/pks/lookup\?op=get\&options=mr\&search=0x([0-9A-F]{40})$ || ${request} =~ ^/vks/v1/by-fingerprint/([0-9A-F]{40})$ ]] ||
      fail "keyserver request ${request}"
    grep -qx -- "${BASH_REMATCH[1]}" <<<"${fingerprints}" || fail "keyserver lookup of ${BASH_REMATCH[1]}"
  done <<<"${requests}"
}

case_admit_subkey() {
  local d
  d=$(world admit_subkey)
  sign_tag "${d}" alice subkey "${COMMIT}" "${TAG}"
  tag_document "${d}"
  take "${d}"
  admitted "${d}" members/core
}

case_admit_existing_parent() {
  local d
  d=$(world admit_existing_parent)
  mkdir "${d}/workspace/members"
  printf 'kept\n' >"${d}/workspace/members/other"
  take "${d}"
  admitted "${d}" members/core
  [[ $(<"${d}/workspace/members/other") == kept ]] || fail 'a file beside path changed'
}

# Item 1: any failed check fails the step.
case_i1_shape() {
  local action=${ACTION} script first answer
  answer=$(yq '.runs.steps | length' "${action}")
  [[ ${answer} == 1 ]] || fail 'action.yml runs more than one step'
  answer=$(yq '.runs.steps[0] | has("continue-on-error") or has("if")' "${action}")
  [[ ${answer} == false ]] || fail 'the step has continue-on-error or if'
  answer=$(yq -r '.runs.steps[0].shell' "${action}")
  [[ ${answer} == '/usr/bin/bash --posix --noprofile --norc -e -o pipefail {0}' ]] ||
    fail 'the step shell is not the image bash with -e and pipefail'
  first=$(yq -r '.runs.steps[0].run' "${action}" | awk 'NR == 1')
  [[ ${first} == 'set -euo pipefail' ]] || fail 'run opens otherwise'
  for script in take tag tools; do
    first=$(awk '!/^#/ && NF {print; exit}' "${tree}/actions/release-take/${script}.sh")
    [[ ${first} == 'set -euo pipefail' ]] || fail "${script}.sh opens with ${first}"
  done
}

case_i1_failed_download() {
  local d release
  d=$(world i1_failed_download)
  release=$(release_dir "${d}")
  rm -rf -- "${release}"
  take "${d}"
  refused "${d}" 1 'release not found'
  ! grep -q SHA256SUMS "${d}/stderr" || fail 'the take ran on past the failed download'
}

# Item 2: files reach path only after every proof (each refusal asserts the workspace untouched).
case_i2_proofs_before_placing() {
  local d release sum
  d=$(world i2_proofs_before_placing)
  release=$(release_dir "${d}")
  sum=$(digest "${release}/notes.txt")
  rm -f -- "${d}/github/attestations/${REPOSITORY}/${sum}.jsonl"
  take "${d}"
  refused "${d}" 65 'holds no attestation of notes.txt'
}

# Item 3: commit set only when every proof passed, and as the tag's commit.
case_i3_commit_form() {
  local d upper=${COMMIT^^}
  d=$(world i3_commit_form)
  sign_tag "${d}" bob primary "${upper}" "${TAG}"
  tag_document "${d}"
  jq --arg c "${upper}" '.object.sha = $c' "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json" >"${d}/t.json"
  mv "${d}/t.json" "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json"
  take "${d}"
  refused "${d}" 65 "the tag ${TAG} names"
}

# Item 4: the tag, now, as the gate holds its own.
case_i4_empty_tag() {
  local d
  d=$(world i4_empty_tag)
  input[tag]=''
  take "${d}"
  refused "${d}" 64 'tag is empty'
  [[ ! -s ${d}/github/calls ]] || fail "gh ran: $(<"${d}/github/calls")"
  ! grep -q '^tools:' "${d}/stdout" || fail 'tools were downloaded'
}

case_i4_tag_form() {
  local d
  d=$(world i4_tag_form)
  input[tag]='v1..2'
  take "${d}"
  refused "${d}" 64 'is not one a release tag is named by'
}

edit_json() { # file, jq edit
  jq "$2" "$1" >"$1.edited"
  mv -- "$1.edited" "$1"
}

case_i4_lightweight() {
  local d
  d=$(world i4_lightweight)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/ref/tags/${TAG}.json" ".object.type = \"commit\" | .object.sha = \"${COMMIT}\""
  take "${d}"
  refused "${d}" 65 'not a signed tag object'
}

case_i4_ref_answer() {
  local d
  d=$(world i4_ref_answer)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/ref/tags/${TAG}.json" '.ref = "refs/tags/v1.2.30"'
  take "${d}"
  refused "${d}" 65 "GitHub answers refs/tags/${TAG}"
}

case_i4_object_answer() {
  local d
  d=$(world i4_object_answer)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json" '.sha = "0000000000000000000000000000000000000000"'
  take "${d}"
  refused "${d}" 65 'GitHub answers tag object'
}

case_i4_renamed() {
  local d
  d=$(world i4_renamed)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json" '.tag = "v1.2.4"'
  take "${d}"
  refused "${d}" 65 'names itself'
}

case_i4_not_commit() {
  local d
  d=$(world i4_not_commit)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json" '.object.type = "tree"'
  take "${d}"
  refused "${d}" 65 'not a commit'
}

case_i4_unsigned() {
  local d
  d=$(world i4_unsigned)
  edit_json "${d}/github/api/repos/${REPOSITORY}/git/tags/${OBJECT}.json" '.verification.signature = null'
  take "${d}"
  refused "${d}" 65 'carries no signature'
}

case_i4_payload_commit() {
  local d
  d=$(world i4_payload_commit)
  sign_tag "${d}" bob primary "${OBJECT}" "${TAG}"
  tag_document "${d}"
  take "${d}"
  refused "${d}" 65 'the signed tag object does not name commit'
}

case_i4_payload_tag() {
  local d
  d=$(world i4_payload_tag)
  sign_tag "${d}" bob primary "${COMMIT}" v1.2.4
  tag_document "${d}"
  take "${d}"
  refused "${d}" 65 'the signed tag object does not name commit'
}

case_i4_two_signatures() {
  local d
  d=$(world i4_two_signatures)
  mv "${d}/signature" "${d}/bob.asc"
  sign_tag "${d}" alice subkey "${COMMIT}" "${TAG}"
  cat "${d}/bob.asc" >>"${d}/signature"
  tag_document "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_outsider() {
  local d
  d=$(world i4_outsider)
  sign_tag "${d}" mallory primary "${COMMIT}" "${TAG}"
  tag_document "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_published_key() {
  local d
  d=$(world i4_published_key)
  sign_tag "${d}" mallory primary "${COMMIT}" "${TAG}"
  tag_document "${d}"
  mkdir -p "${d}/keyserver/pks"
  cp -- "${fixtures}/public/mallory.asc" "${d}/keyserver/pks/lookup"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_weak_hash() {
  local d
  d=$(world i4_weak_hash)
  sign_tag "${d}" bob primary "${COMMIT}" "${TAG}" --digest-algo SHA1
  tag_document "${d}"
  take "${d}"
  # gpg 2.4 admits a SHA-1 data signature; sqv's policy refuses it.
  refused "${d}" 70 'sqv does not verify the tag'
}

case_i4_revoked() {
  local d
  d=$(world i4_revoked)
  sign_tag "${d}" carol primary "${COMMIT}" "${TAG}"
  tag_document "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_published_revocation() {
  local d dave
  d=$(world i4_published_revocation)
  sign_tag "${d}" dave primary "${COMMIT}" "${TAG}"
  tag_document "${d}"
  mkdir -p "${d}/keyserver/vks/v1/by-fingerprint"
  dave=$(fingerprint dave)
  cp -- "${fixtures}/public/dave-revoked.asc" "${d}/keyserver/vks/v1/by-fingerprint/${dave}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_expired() {
  local d
  d=$(world i4_expired)
  sign_tag "${d}" erin primary "${COMMIT}" "${TAG}" --faked-system-time 20200101T120000!
  tag_document "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i4_silent_keyserver() {
  local d
  d=$(world i4_silent_keyserver)
  over[TAKE_HKP]='http://127.0.0.1:1'
  take "${d}"
  refused "${d}" 75 'did not answer'
}

case_i4_bad_publication() {
  local d
  d=$(world i4_bad_publication)
  mkdir -p "${d}/keyserver/pks"
  printf '<html>not a key</html>\n' >"${d}/keyserver/pks/lookup"
  take "${d}"
  refused "${d}" 65 'what a keyserver published for an admitted primary does not import'
}

# Item 5: the repository, workflow, ref and commit.
case_i5_repository_id() {
  local d
  d=$(world i5_repository_id)
  edit_json "${d}/github/api/repositories/${ID}.json" '.id = 1'
  take "${d}"
  refused "${d}" 65 "repository ${ID} resolves to"
}

case_i5_owner() {
  local d
  d=$(world i5_owner)
  edit_json "${d}/github/api/repositories/${ID}.json" '.owner.id = 1'
  take "${d}"
  refused "${d}" 65 "repository ${ID} resolves to"
}

reattest() { # case directory, jq edit
  rm -rf -- "$1/github/attestations"
  attest "$1" azkaban_1.2.3_amd64.deb "$2"
  attest "$1" notes.txt "$2"
}

case_i5_workflow() {
  local d
  d=$(world i5_workflow)
  reattest "${d}" '.certificate.subjectAlternativeName |= sub("gate.yml"; "ci.yml")'
  take "${d}"
  refused "${d}" 65 'no attestation of'
}

case_i5_source_ref() {
  local d
  d=$(world i5_source_ref)
  reattest "${d}" '.certificate.sourceRepositoryRef = "refs/heads/main"'
  take "${d}"
  refused "${d}" 65 'no attestation of'
}

case_i5_source_digest() {
  local d
  d=$(world i5_source_digest)
  reattest "${d}" ".certificate.sourceRepositoryDigest = \"${OBJECT}\""
  take "${d}"
  refused "${d}" 65 'no attestation of'
}

case_i5_self_hosted() {
  local d
  d=$(world i5_self_hosted)
  reattest "${d}" '.certificate.runnerEnvironment = "self-hosted"'
  take "${d}"
  refused "${d}" 65 'no attestation of'
}

case_i5_identifier() {
  local d
  d=$(world i5_identifier)
  reattest "${d}" '.certificate.sourceRepositoryIdentifier = "1"'
  take "${d}"
  refused "${d}" 65 'names repository and owner ids'
}

case_i5_owner_identifier() {
  local d
  d=$(world i5_owner_identifier)
  reattest "${d}" '.certificate.sourceRepositoryOwnerIdentifier = "1"'
  take "${d}"
  refused "${d}" 65 'names repository and owner ids'
}

case_i5_no_attestation() {
  local d
  d=$(world i5_no_attestation)
  rm -rf -- "${d}/github/attestations"
  take "${d}"
  refused "${d}" 65 'holds no attestation of'
}

# Item 6: a job the gate admitted, for this release.
case_i6_other_release() {
  local d
  d=$(world i6_other_release)
  sign_sums "${d}" c1 "${ID}:refs/tags/v1.2.2"
  take "${d}"
  refused "${d}" 70 'names the run'
}

case_i6_statement() {
  local d
  d=$(world i6_statement)
  sign_sums "${d}" c1 '1100000001:refs/heads/main'
  take "${d}"
  refused "${d}" 70 'names the run'
}

case_i6_not_c1() {
  local d
  d=$(world i6_not_c1)
  sign_sums "${d}" impostor "${ID}:refs/tags/${TAG}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify'
}

case_i6_unnamed_asset() {
  local d release
  d=$(world i6_unnamed_asset)
  release=$(release_dir "${d}")
  printf 'extra\n' >"${release}/extra.bin"
  attest "${d}" extra.bin
  take "${d}"
  refused "${d}" 65 'which SHA256SUMS does not name'
}

case_i6_missing_asset() {
  local d release
  d=$(world i6_missing_asset)
  release=$(release_dir "${d}")
  printf 'gone\n' >"${release}/gone.bin"
  sign_sums "${d}" c1 "${ID}:refs/tags/${TAG}"
  rm -- "${release}/gone.bin"
  take "${d}"
  refused "${d}" 65 'which the release does not hold'
}

case_i6_digest() {
  local d release
  d=$(world i6_digest)
  release=$(release_dir "${d}")
  printf 'changed\n' >"${release}/notes.txt"
  attest "${d}" notes.txt
  take "${d}"
  refused "${d}" 65 'the release does not match its SHA256SUMS'
}

case_i6_subject_outside() {
  local d
  d=$(world i6_subject_outside)
  reattest "${d}" '.statement.subject += [{name: "other.bin", digest: {sha256: "'"${COMMIT}${COMMIT:0:24}"'"}}]'
  take "${d}"
  refused "${d}" 65 'which SHA256SUMS does not'
}

case_i6_sums_form() {
  local d release sub
  d=$(world i6_sums_form)
  release=$(release_dir "${d}")
  sed -i 's/  / /' "${release}/SHA256SUMS"
  sub=$(subkey c1)
  rm -f -- "${release}/SHA256SUMS.asc"
  "${tree}/actions/release-key/sign.sh" "${fixtures}/keys/c1" "${sub}" "${ID}:refs/tags/${TAG}" "${release}/SHA256SUMS" >/dev/null
  take "${d}"
  refused "${d}" 65 'not <sha256>  <name>'
}

case_i6_duplicate() {
  local d release sub line
  d=$(world i6_duplicate)
  release=$(release_dir "${d}")
  line=$(grep notes.txt "${release}/SHA256SUMS")
  printf '%s\n' "${line}" >>"${release}/SHA256SUMS"
  sub=$(subkey c1)
  rm -f -- "${release}/SHA256SUMS.asc"
  "${tree}/actions/release-key/sign.sh" "${fixtures}/keys/c1" "${sub}" "${ID}:refs/tags/${TAG}" "${release}/SHA256SUMS" >/dev/null
  take "${d}"
  refused "${d}" 65 'twice'
}

# Item 7: the caller's environment changes nothing.
plant() { # case directory: a caller environment that would change the take wherever it reached
  local d=$1 tool
  mkdir -p "${d}/planted/bin" "${d}/planted/home" "${d}/planted/cache" "${d}/planted/config" "${d}/planted/gnupg" \
    "${d}/planted/gh" "${d}/planted/tmp" "${d}/planted/lib"
  printf 'printf "BASH_ENV ran\\n" >>%q\n' "${d}/planted/marker" >"${d}/planted/startup.sh"
  for tool in gh gpg sqv sha256sum curl bash; do
    printf '#!/bin/sh\nprintf "planted %s ran\\n" >>%s\nexec /usr/bin/%s "$@"\n' "${tool}" "${d}/planted/marker" "${tool}" \
      >"${d}/planted/bin/${tool}"
    chmod 755 "${d}/planted/bin/${tool}"
  done
  caller=("PATH=${d}/planted/bin:/usr/bin:/bin" "HOME=${d}/planted/home" "TMPDIR=${d}/planted/tmp"
    "XDG_CACHE_HOME=${d}/planted/cache" "XDG_CONFIG_HOME=${d}/planted/config" "GH_CONFIG_DIR=${d}/planted/gh"
    "GNUPGHOME=${d}/planted/gnupg" GH_HOST=attacker.example GH_REPO=attacker/repo GITHUB_TOKEN=other-token
    "BASH_ENV=${d}/planted/startup.sh" "ENV=${d}/planted/startup.sh" SHELLOPTS=xtrace
    "PS4=\$(printf 'PS4 ran\\n' >>${d}/planted/marker)+ " "LD_PRELOAD=${d}/planted/lib/absent.so"
    "LD_LIBRARY_PATH=${d}/planted/lib" "BASH_FUNC_gpg%%=() { printf 'function gpg ran\\n' >>${d}/planted/marker; command gpg \"\$@\"; }"
    "BASH_FUNC_sha256sum%%=() { printf 'function sha256sum ran\\n' >>${d}/planted/marker; command sha256sum \"\$@\"; }")
}

case_i7_environment() {
  local d names expected work shown
  d=$(world i7_environment)
  plant "${d}"
  take "${d}"
  admitted "${d}" members/core
  [[ ! -e ${d}/planted/marker ]] || fail "the caller's environment reached the take: $(<"${d}/planted/marker")"
  shown=$(grep -E '^\+|preload|ld\.so' "${d}/stderr" || true) # none is the pass
  [[ -z ${shown} ]] || fail "stderr: ${shown}"
  # gh saw the take's own environment alone.
  names=$(sed -n '1,/^--$/p' "${d}/github/env" | sed '$d' | cut -d= -f1 | tr '\n' ' ')
  expected='GH_CONFIG_DIR GH_HOST GH_NO_UPDATE_NOTIFIER GH_PROMPT_DISABLED GH_TOKEN GITHUB_ACTION_PATH GITHUB_OUTPUT GITHUB_WORKSPACE GNUPGHOME HOME LC_ALL PATH PWD RUNNER_TEMP SHLVL TAKE_GH_SHA256 TAKE_GH_URL TAKE_HKP TAKE_PATH TAKE_REPOSITORY_ID TAKE_SQV_SHA256 TAKE_SQV_URL TAKE_TAG TAKE_VKS TAKE_WORKFLOW TMPDIR XDG_CACHE_HOME XDG_CONFIG_HOME _ '
  [[ ${names} == "${expected}" ]] || fail "gh's environment: ${names}"
  work=$(sed -n 's|^HOME=\(.*\)/home$|\1|p' "${d}/github/env" | head -n 1)
  [[ ${work} == "${d}/temp/release-take."* ]] || fail "gh's HOME is under ${work}"
  for name in "GH_HOST=github.com" "XDG_CACHE_HOME=${work}/cache" "GH_CONFIG_DIR=${work}/gh" "GNUPGHOME=${work}/gnupg" \
    "PATH=${work}/bin:/usr/bin:/bin" "TMPDIR=${work}/tmp"; do
    grep -qxF -- "${name}" "${d}/github/env" || fail "gh's environment lacks ${name}"
  done
}

case_i7_special_builtin() {
  local d
  d=$(world i7_special_builtin)
  caller+=("BASH_FUNC_exec%%=() { printf 'function exec ran\\n' >>${d}/planted/marker; }")
  take "${d}"
  refused "${d}" 2 'is a special builtin'
  [[ ! -e ${d}/planted/marker ]] || fail "$(<"${d}/planted/marker")"
}

# Item 8: the roots are the action's own commit's.
case_i8_consumer_c1() {
  local d
  d=$(world i8_consumer_c1)
  mkdir -p "${d}/workspace/signing"
  cp -- "${fixtures}/public/impostor.asc" "${d}/workspace/signing/c1-public.asc"
  sign_sums "${d}" impostor "${ID}:refs/tags/${TAG}"
  snapshot "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify'
}

case_i8_consumer_core_keys() {
  local d
  d=$(world i8_consumer_core_keys)
  mkdir -p "${d}/workspace/signing/core-keys"
  cp -- "${fixtures}/public/mallory.asc" "${d}/workspace/signing/core-keys/mallory.asc"
  sign_tag "${d}" mallory primary "${COMMIT}" "${TAG}"
  tag_document "${d}"
  snapshot "${d}"
  take "${d}"
  refused "${d}" 70 'gpg does not verify the tag'
}

case_i8_no_c1() {
  local d
  d=$(world i8_no_c1)
  rm -- "${d}/tree/signing/c1-public.asc"
  take "${d}"
  refused "${d}" 66 'holds no signing/c1-public.asc'
}

case_i8_no_core_keys() {
  local d
  d=$(world i8_no_core_keys)
  rm -rf -- "${d}/tree/signing/core-keys"
  take "${d}"
  refused "${d}" 66 'holds no signing/core-keys'
}

# Item 9: nothing fetched but the named release, the tools fixed by digest (the call log is
# admit_primary's).
case_i9_gh_digest() {
  local d
  d=$(world i9_gh_digest)
  over[TAKE_GH_SHA256]=$(digest "${fixtures}/tools/sqv.deb")
  take "${d}"
  refused "${d}" 65 'the gh archive at'
}

case_i9_sqv_digest() {
  local d
  d=$(world i9_sqv_digest)
  over[TAKE_SQV_SHA256]=$(digest "${fixtures}/tools/gh.tar.gz")
  take "${d}"
  refused "${d}" 65 'the sqv package at'
}

# Item 10: names confined.
case_i10_name_slash() {
  local d release sub sum
  d=$(world i10_name_slash)
  release=$(release_dir "${d}")
  sum=$(digest "${release}/notes.txt")
  printf '%s  sub/notes.txt\n' "${sum}" >>"${release}/SHA256SUMS"
  sub=$(subkey c1)
  rm -f -- "${release}/SHA256SUMS.asc"
  "${tree}/actions/release-key/sign.sh" "${fixtures}/keys/c1" "${sub}" "${ID}:refs/tags/${TAG}" "${release}/SHA256SUMS" >/dev/null
  take "${d}"
  refused "${d}" 65 'SHA256SUMS names sub/notes.txt'
  ! grep -q 'which the release does not hold' "${d}/stderr" || fail 'refused for the absent file, not for its name'
}

case_i10_name_dots() {
  local d release
  d=$(world i10_name_dots)
  release=$(release_dir "${d}")
  printf 'dots\n' >"${release}/a..b"
  sign_sums "${d}" c1 "${ID}:refs/tags/${TAG}"
  attest "${d}" 'a..b'
  take "${d}"
  refused "${d}" 65 'the release holds an asset named a..b'
}

case_i10_link() {
  local d release
  d=$(world i10_link)
  release=$(release_dir "${d}")
  ln -s /etc/hostname "${release}/link.txt"
  take "${d}"
  refused "${d}" 65 'which is not a regular file'
}

case_i10_path_parent() {
  local d
  d=$(world i10_path_parent)
  input[path]='../outside'
  take "${d}"
  refused "${d}" 64 'path is directories under the workspace'
  [[ ! -e ${d}/outside ]] || fail 'the take placed outside the workspace'
}

case_i10_path_absolute() {
  local d
  d=$(world i10_path_absolute)
  input[path]="${d}/outside"
  take "${d}"
  refused "${d}" 64 'path is directories under the workspace'
}

case_i10_path_github() {
  local d
  d=$(world i10_path_github)
  input[path]='.GitHub/actions/x'
  take "${d}"
  refused "${d}" 64 'path is directories under the workspace'
}

case_i10_path_link() {
  local d placed
  d=$(world i10_path_link)
  mkdir "${d}/outside"
  ln -s "${d}/outside" "${d}/workspace/members"
  snapshot "${d}"
  take "${d}"
  refused "${d}" 64 'is a link'
  placed=$(find "${d}/outside" -mindepth 1)
  [[ -z ${placed} ]] || fail "the take placed through the link: ${placed}"
}

case_i10_path_exists() {
  local d
  d=$(world i10_path_exists)
  mkdir -p "${d}/workspace/members/core"
  printf 'kept\n' >"${d}/workspace/members/core/kept"
  snapshot "${d}"
  take "${d}"
  refused "${d}" 64 'exists in the workspace'
}

make_fixtures
mkdir -p "${fixtures}/cases" "${fixtures}/home"
ln -sfn -- "${fixtures}/cases" "${fixtures}/current"
# Every request goes to the case the take runs in, through the `current` link.
python3 -u -m http.server --bind 127.0.0.1 0 --directory "${fixtures}/current/keyserver" >"${fixtures}/keyserver.log" 2>&1 &
server=$!
port=''
for _ in {1..50}; do
  port=$(sed -n 's/^Serving HTTP on 127.0.0.1 port \([0-9]*\) .*/\1/p' "${fixtures}/keyserver.log")
  [[ -z ${port} ]] || break
  read -r -t 0.1 <> <(:) || true # a tenth of a second, while the server binds
done
[[ -n ${port} ]] || {
  printf 'the keyserver stand-in did not start: %s\n' "$(<"${fixtures}/keyserver.log")" >&2
  exit 69
}

if ((${#cases[@]} == 0)); then
  listed=$(declare -F | awk '$3 ~ /^case_/ {print substr($3, 6)}')
  mapfile -t cases <<<"${listed}"
fi
passed=0 failed=0
for name in "${cases[@]}"; do
  declare -F "case_${name}" >/dev/null || {
    printf 'no case %s\n' "${name}" >&2
    exit 64
  }
  reset
  # Each case runs in a subshell of its own under -e, so its first failed assertion ends it.
  set +e
  (
    set -e
    "case_${name}"
  )
  status=$?
  set -e
  if ((status == 0)); then
    printf 'ok    %s\n' "${name}"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "${name}"
    failed=$((failed + 1))
  fi
done
printf '%d passed, %d failed\n' "${passed}" "${failed}"
((failed == 0))
