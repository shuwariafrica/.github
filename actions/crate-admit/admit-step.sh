#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-admit's step (bash 5.3, git, gpg 2.4,
# python3 3.11 or later, jq, yq), and a developer's Linux machine for its cases.
# crate-admit's step: the early refusal of a public crate's release, which executes nothing it
# reads. In order: the run is a tag's push, the tag `v` and a semantic version; public-crates' main,
# fetched anonymously, holds the project with its id and signing key, the version is not below its
# first_version; the tag, fetched from the project with its main, is a tag object naming its own
# name and this run's commit; it is signed once, verified by git over a GnuPG home holding only the
# project's tag signers' certificates from keys/, with a GOODSIG and a VALIDSIG whose primary is
# one of them; only then the tagged tree, checked out as data (admit-tree.py); and last
# release.yml at that commit, read as data, pins every action of the organisation's at the
# release's commits and runs verify on exactly the project's platforms.
# Environment: EVENT, REPOSITORY, REPOSITORY_ID, REF, SHA (the run's), GIT_BASE, RUNNER_TEMP,
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTION_PATH.
# Writes version, crates, toolchain, commit, object, signer and primary to GITHUB_OUTPUT.
# Exit 0 admitted; 1 refused; 64 for an invocation it refuses; 69 for an absent tool; 75 when
# something could not be read.
# shellcheck disable=SC2153,SC2154 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

# jq's key for a semantic version's precedence (SemVer 2.0.0, section 11): numbers compare as
# numbers, a version with a pre-release sorts before the same without, numeric identifiers before
# alphanumeric ones. Build metadata is ignored.
readonly SEMVER_JQ='
  def semver: capture("^(?<ma>0|[1-9][0-9]*)\\.(?<mi>0|[1-9][0-9]*)\\.(?<pa>0|[1-9][0-9]*)(-(?<pre>[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")
    | [(.ma | tonumber), (.mi | tonumber), (.pa | tonumber),
       (if .pre == null then [1] else [0] + [.pre | split(".")[] | if test("^[0-9]+$") then [0, tonumber] else [1, .] end] end)];
'

# One output line: a value never spans lines, so GITHUB_OUTPUT reads it as one.
output() {
  local value=${2//$'\r'/ }
  printf '%s=%s\n' "$1" "${value//$'\n'/ }" >>"${GITHUB_OUTPUT}"
}

# The run is a push of the tag REF at SHA, of the repository REPOSITORY_ID. Sets TAG and VERSION.
inputs() {
  local number='(0|[1-9][0-9]*)' pre='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)' build='[0-9A-Za-z-]+'
  [[ ${EVENT} == push ]] || die "a release runs on a tag's push, and this run is a ${EVENT}"
  [[ ${REF} == refs/tags/* ]] || die "a release runs on a tag, and this run is on ${REF}"
  TAG=${REF#refs/tags/}
  [[ ${TAG} =~ ^v${number}\.${number}\.${number}(-${pre}(\.${pre})*)?(\+${build}(\.${build})*)?$ ]] ||
    die "${TAG} is not v and a semantic version"
  [[ ${SHA} =~ ^[0-9a-f]{40}$ ]] || die "the run's commit ${SHA} is not 40 hexadecimal digits"
  [[ ${REPOSITORY_ID} =~ ^[1-9][0-9]*$ ]] || die "the repository's id ${REPOSITORY_ID} is not a number"
  VERSION=${TAG#v}
}

# public-crates' main: the project, the version against its first_version, and gate-commit. Sets
# PROJECT and GATE.
catalogue_read() {
  local first
  catalogue "${CAT}" >/dev/null
  PROJECT=$(project_of "${CAT}" "${REPOSITORY}" "${REPOSITORY_ID}")
  first=$(jq -r '.first_version' <<<"${PROJECT}")
  jq -en --arg v "${VERSION}" --arg f "${first}" "${SEMVER_JQ}"'($v | semver) >= ($f | semver)' >/dev/null 2>&1 ||
    die "v${VERSION} is below the project's first_version ${first}"
  GATE=$(catalogue_file "${CAT}" gate-commit)
  GATE=${GATE//[[:space:]]/}
  [[ ${GATE} =~ ^[0-9a-f]{40}$ ]] || die "public-crates' gate-commit names no full commit"
}

# The tag and the project's main, fetched anonymously into TREE: the tag's ref names a tag object.
# Sets OBJECT.
fetch_tag() {
  local answer rc=0 kind
  git init --quiet -- "${TREE}"
  answer=$(git -C "${TREE}" fetch --quiet --no-tags -- "${GIT_BASE}/${REPOSITORY}" \
    "+refs/tags/${TAG}:refs/tags/${TAG}" "+refs/heads/main:refs/remotes/origin/main" 2>&1) || rc=$?
  ((rc == 0)) || unreadable "the project cannot be read: ${answer//$'\n'/ }"
  kind=$(git -C "${TREE}" cat-file -t "refs/tags/${TAG}")
  [[ ${kind} == tag ]] || die "the tag ${TAG} names a ${kind}, not a signed tag object"
  OBJECT=$(git -C "${TREE}" rev-parse "refs/tags/${TAG}")
}

# The project's tag signers' certificates from public-crates' keys/, alone, in the run's own home;
# each must hold its own fingerprint.
keyring() {
  local signers signer listed
  mkdir -m 700 -- "${GNUPGHOME}"
  signers=$(jq -r '.tag_signers[]' <<<"${PROJECT}")
  [[ -n ${signers} ]] || die "the project lists no tag signer"
  while IFS= read -r signer; do
    [[ ${signer} =~ ^[0-9A-F]{40}$ ]] || die "the tag signer ${signer} is not a v4 fingerprint"
    git -C "${CAT}" show "refs/heads/main:keys/${signer}.asc" >"${WORK}/signer.asc" 2>/dev/null ||
      die "public-crates' main holds no keys/${signer}.asc"
    gpg --batch --quiet --import "${WORK}/signer.asc" 2>/dev/null || die "keys/${signer}.asc does not import"
    listed=$(gpg --batch --with-colons --list-keys -- "${signer}" 2>/dev/null || true) # absent is answered below
    listed=$(awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}' <<<"${listed}")
    grep -qxF -- "${signer}" <<<"${listed}" || die "keys/${signer}.asc holds no certificate of ${signer}"
  done <<<"${signers}"
}

# The tag object binds the tag: its header, git's own (`object`, `type`, `tag` in that order, each
# once, up to the first empty line), names this tag and this run's commit. Sets COMMIT.
binding() {
  local text header first named kind fields
  text=$(git -C "${TREE}" cat-file tag "${OBJECT}")
  header=$(sed -n '/^$/q;p' <<<"${text}")
  first=$(sed -n 1p <<<"${header}")
  [[ ${first} =~ ^object\ ([0-9a-f]{40})$ ]] || die "the tag object's header is not git's"
  COMMIT=${BASH_REMATCH[1]}
  kind=$(sed -n '2s/^type //p' <<<"${header}")
  named=$(sed -n '3s/^tag //p' <<<"${header}")
  fields=$(grep -cE '^(object|type|tag) ' <<<"${header}" || true) # 0 is answered below
  if [[ -z ${kind} || -z ${named} ]] || ((fields != 3)); then
    die "the tag object's header is not git's"
  fi
  [[ ${named} == "${TAG}" ]] || die "the tag object is ${named}, pushed as ${TAG}"
  [[ ${kind} == commit ]] || die "the tag object tags a ${kind}"
  [[ ${COMMIT} == "${SHA}" ]] || die "the tag names ${COMMIT}, and this run is at ${SHA}"
}

# The tag's signature, by git's own check over the run's keyring, gpg refusing a SHA-1 digest:
# exactly one signature, gpg's GOODSIG, and a VALIDSIG whose primary is one of the project's tag
# signers. Sets PRIMARY and SIGNER.
signature() {
  local text markers answer status signatures result validsig signers signer primary
  local -a fields
  text=$(git -C "${TREE}" cat-file tag "${OBJECT}")
  # git takes the signature from the last line that opens one of the forms it knows.
  markers=$(grep -E '^-----BEGIN (PGP SIGNATURE|PGP MESSAGE|SIGNED MESSAGE|SSH SIGNATURE)-----' <<<"${text}" || true) # none when unsigned
  [[ -n ${markers} ]] || die "the tag is not signed"
  [[ ${markers##*$'\n'} == -----BEGIN\ PGP* ]] || die "the tag's signature is not one OpenPGP signature"
  printf '#!/bin/sh\nexec %s --weak-digest SHA1 "$@"\n' "${GPG}" >"${WORK}/gpg"
  chmod 700 -- "${WORK}/gpg"
  # git's exit is not the verdict: gpg's status is, and git's exit is 0 for a key since expired.
  answer=$(git -C "${TREE}" -c gpg.program="${WORK}/gpg" verify-tag --raw "${OBJECT}" 2>&1 || true)
  status=$(grep '^\[GNUPG:\] ' <<<"${answer}" || true) # none when gpg did not run
  [[ -n ${status} ]] || unreadable "gpg gave no status for the tag's signature: ${answer//$'\n'/ }"
  signatures=$(grep -c '^\[GNUPG:\] NEWSIG' <<<"${status}" || true) # 0 is answered here
  ((signatures == 1)) || die "the tag's signature is not one OpenPGP signature"
  # Neither line is there for a signature gpg cannot parse, and VALIDSIG only where it verifies.
  result=$(grep -m1 -E '^\[GNUPG:\] (GOODSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG) ' <<<"${status}" || true)
  validsig=$(grep -m1 '^\[GNUPG:\] VALIDSIG ' <<<"${status}" || true)
  read -ra fields <<<"${validsig}"
  signer=${fields[2]:-}
  primary=${fields[11]:-}
  read -ra fields <<<"${result}"
  case ${fields[1]:-} in
    ERRSIG)
      # ERRSIG <key id> <algorithm> <hash> <class> <time> <code> [<fingerprint>]; code 9 is no key.
      [[ ${fields[7]:-} != 9 ]] || die "no admitted key made the signature (issuers ${fields[8]:-${fields[2]:-}})"
      die "the signature by ${fields[8]:-${fields[2]:-}} is refused: gpg cannot check it (code ${fields[7]:-}, hash algorithm ${fields[4]:-})"
      ;;
    BADSIG) die "the signature by ${fields[2]:-} does not verify" ;;
    GOODSIG) ;;
    EXPSIG) die "the signature by ${signer} has expired" ;;
    EXPKEYSIG) die "${signer} has expired" ;;
    REVKEYSIG) die "${signer} is revoked" ;;
    *) die "the tag's signature is not one OpenPGP signature" ;;
  esac
  ! grep -q '^\[GNUPG:\] KEYREVOKED' <<<"${status}" || die "${signer} is revoked"
  signers=$(jq -r '.tag_signers[]' <<<"${PROJECT}")
  if [[ -z ${primary} ]] || ! grep -qxF -- "${primary}" <<<"${signers}"; then
    die "${primary:-${signer}} is not one of the project's tag signers"
  fi
  PRIMARY=${primary}
  SIGNER=${signer}
}

# Only then the tree, checked out as data: no symbolic link, no filter, no hook. The commit is on
# the first-parent line of the project's main, then the tree's own checks. Sets FACTS, their JSON.
tree() {
  local answer rc=0 error crates
  answer=$(git -C "${TREE}" rev-list --first-parent refs/remotes/origin/main 2>&1) || rc=$?
  ((rc == 0)) || unreadable "the project's main cannot be read: ${answer//$'\n'/ }"
  grep -qxF -- "${COMMIT}" <<<"${answer}" || die "${COMMIT} is not on the first-parent line of the project's main"
  answer=$(git -C "${TREE}" -c core.symlinks=false -c core.hooksPath=/dev/null -c filter.lfs.smudge= -c filter.lfs.process= \
    -c filter.lfs.required=false checkout --quiet --detach "${COMMIT}" 2>&1) || rc=$?
  ((rc == 0)) || unreadable "the tagged tree cannot be checked out: ${answer//$'\n'/ }"
  crates=$(jq -c '.crates' <<<"${PROJECT}")
  answer=$(python3 -I "${HERE}/admit-tree.py" "${TREE}" "${VERSION}" "${crates}" 2>"${WORK}/tree.error") || rc=$?
  error=$(<"${WORK}/tree.error")
  case ${rc} in
    0) FACTS=${answer} ;;
    1) die "${answer//$'\n'/ }" ;;
    *) unreadable "the tagged tree cannot be read: ${answer//$'\n'/ } ${error//$'\n'/ }" ;;
  esac
}

# release.yml at the commit, as data: every action at a commit the release holds it to,
# and verify on exactly the project's platforms, each on platforms.json's runner.
workflow() {
  local file=${WORK}/release.yml departures rc=0 platforms want have
  git -C "${TREE}" show "${COMMIT}:.github/workflows/release.yml" >"${file}" 2>/dev/null ||
    die "the tagged commit holds no .github/workflows/release.yml"
  # shellcheck disable=SC2310
  # pins_hold's status is its answer, and it dies on what it cannot read.
  departures=$(pins_hold "${file}" "${OWN}" "${GATE}" "${HERE}/../third-party.tsv") || rc=$?
  ((rc == 0)) || die "release.yml's pins are not the release's: ${departures//$'\n'/; }"
  platforms=$(catalogue_file "${CAT}" platforms.json)
  want=$(jq -c --argjson p "${platforms}" '[.platforms[] | {platform: ., runner: ($p[.].runner // error("platforms.json has no platform \(.)"))}] | sort' <<<"${PROJECT}" 2>&1) ||
    die "the project names a platform public-crates' platforms.json does not hold: ${want}"
  have=$(yq -o=json -I=0 '[.jobs.verify.strategy.matrix.include[] | {"platform": .platform, "runner": .runner}] | sort_by(.platform, .runner)' "${file}" 2>/dev/null) || have=none
  have=$(jq -c 'sort' <<<"${have}" 2>/dev/null) || have=none
  [[ ${have} == "${want}" ]] || die "release.yml's verify runs on ${have}, and the project's platforms are ${want}"
}

cleanup() {
  [[ -n ${WORK:-} ]] || return 0
  gpgconf --homedir "${WORK}/gnupg" --kill all 2>/dev/null || true         # its agent may never have started
  gpgconf --homedir "${WORK}/gnupg" --remove-socketdir 2>/dev/null || true # nor its socket directory
  rm -rf -- "${WORK}"
}

main() {
  local self crates toolchain
  : "${EVENT?}" "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${REF:?}" "${SHA:?}" "${GIT_BASE:?}" "${RUNNER_TEMP:?}"
  : "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}" "${GITHUB_ACTION_PATH:?}"
  self=$(realpath -- "${BASH_SOURCE[0]}")
  HERE=$(dirname -- "${self}")
  # shellcheck source=actions/crate-publish/lib.sh
  source "${HERE}/../crate-publish/lib.sh"
  # shellcheck source=actions/crate-sign/pins.sh
  source "${HERE}/../crate-sign/pins.sh"
  tools git gpg gpgconf python3 jq yq sed awk grep realpath
  GPG=$(command -v gpg)
  WORK=$(mktemp -d -p "${RUNNER_TEMP}")
  CAT=${WORK}/public-crates TREE=${WORK}/project
  export GNUPGHOME=${WORK}/gnupg
  trap '((BASHPID == '"${BASHPID}"')) && cleanup' EXIT
  inputs
  OWN=$(own_commit "${GITHUB_ACTION_PATH}" crate-admit)
  catalogue_read
  fetch_tag
  keyring
  binding
  signature
  tree
  workflow
  crates=$(jq -c '.order' <<<"${FACTS}")
  toolchain=$(jq -r '.toolchain' <<<"${FACTS}")
  output version "${VERSION}"
  output crates "${crates}"
  output toolchain "${toolchain}"
  output commit "${COMMIT}"
  output object "${OBJECT}"
  output signer "${SIGNER}"
  output primary "${PRIMARY}"
  printf 'admitted %s of %s at %s, signed by %s (%s)\n' "${TAG}" "${REPOSITORY}" "${COMMIT}" "${PRIMARY}" "${SIGNER}" |
    tee -a "${GITHUB_STEP_SUMMARY}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
