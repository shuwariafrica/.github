# shellcheck shell=bash
# Sourced by the crate-* actions' tests (tests/crate-*/run.sh), with tests/step.sh. Each case's
# world is made in a temporary directory and nothing leaves the machine:
#   - keys made in throwaway GnuPG homes under faked times: a tag signer, the project's signing key
#     (a certifying primary and a signing subkey, as generate-project-key makes it) and a stranger;
#   - public-crates and the project as git repositories, which git reaches at GIT_BASE (file://);
#   - the stand-ins of tests/crate-publish/stub (curl, gh, sudo) first on PATH, through wrappers in
#     the case's bin naming its stub directory, where each records its calls;
#   - a release's files as crate-package writes them, signed by the project's subkey;
#   - an action's step run as the runner runs it, from a copy of its action.yml whose one change is
#     the stand-ins' directory on the PATH its run line builds, and from a directory laid out as the
#     runner lays out a remote action at the commit OWN.
# Usage of a sourcer: run.sh [--tree <directory>] [<case>...], --tree a tree holding actions/ (this
# repository's by default, or a copy with a mutant). Prints ok or FAIL per case and the counts; exit 0
# when every case named (all by default) passed, 1 when one failed, 64 for usage, 69 for an absent
# tool.
# shellcheck disable=SC2154,SC2034 # step.sh reads input, over, caller and runner; the sourcers read the rest
shopt -s inherit_errexit

declare -A input=() over=()
caller=() runner=()
readonly OWN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly GATE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly COMMIT_OFF=cccccccccccccccccccccccccccccccccccccccc
readonly ID=1295027104
readonly AGENT_WANT='shuwariafrica-crate-release (https://github.com/shuwariafrica/.github)'
MADE=$(date -u -d '-10 days' +%Y%m%dT%H%M%S)
SIGNED=$(date -u -d '-9 days' +%Y%m%dT%H%M%S)
REVOKED=$(date -u -d '-8 days' +%Y%m%dT%H%M%S)
TAGGED=$(date -u -d '-9 days' +%s)
readonly MADE SIGNED REVOKED TAGGED

# gpg over the key home <name>, unattended.
g() {
  local home=$1
  shift
  gpg --homedir "${WORK}/keys/${home}" --batch --quiet --pinentry-mode loopback --passphrase '' "$@" 2>>"${WORK}/gpg.log"
}

primary_of() { # key home name: its primary's fingerprint
  local listing
  listing=$(g "$1" --with-colons --list-keys)
  awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; exit}' <<<"${listing}"
}

subkey_of() { # key home name: its signing subkey's fingerprint
  local listing
  listing=$(g "$1" --with-colons --list-keys)
  awk -F: '$1 == "sub" && $12 ~ /s/ {want = 1; next} $1 == "fpr" && want {print $10; exit}' <<<"${listing}"
}

# A key in the new home <name>: <usage> and <expiry> for its primary, and a signing subkey with the
# same expiry where <subkey> is `subkey`.
make_key() {
  local name=$1 usage=$2 expiry=$3 subkey=${4:-} fpr
  mkdir -m 700 -- "${WORK}/keys/${name}"
  g "${name}" --faked-system-time "${MADE}" --quick-gen-key "${name} <${name}@example.invalid>" ed25519 "${usage}" "${expiry}"
  if [[ ${subkey} == subkey ]]; then
    fpr=$(primary_of "${name}")
    g "${name}" --faked-system-time "${MADE}" --quick-add-key "${fpr}" ed25519 sign "${expiry}"
  fi
}

# A case's own copy of the key home <name>, as <name>-<case>, for a case that revokes it; its name
# printed.
own_key() {
  local copy=$1-$2
  cp -a -- "${WORK}/keys/$1" "${WORK}/keys/${copy}"
  printf '%s\n' "${copy}"
}

# The key home <name>'s signing subkey revoked as compromised, eight days ago.
revoke_subkey() {
  local fpr
  fpr=$(primary_of "$1")
  printf 'key 1\nrevkey\ny\n1\ncompromised\n\ny\nsave\n' |
    g "$1" --faked-system-time "${REVOKED}" --command-fd 0 --edit-key "${fpr}"
}

# The run's keys: tag (a tag signer), signing (the project's), stranger (no one's).
make_keys() {
  mkdir -p -- "${WORK}/keys"
  make_key tag cert never subkey
  make_key signing cert never subkey
  make_key stranger cert never subkey
  TAG_KEY=$(primary_of tag)
  TAG_SUBKEY=$(subkey_of tag)
  SIGNING_KEY=$(primary_of signing)
  SIGNING_SUBKEY=$(subkey_of signing)
  STRANGER_KEY=$(primary_of stranger)
  readonly TAG_KEY TAG_SUBKEY SIGNING_KEY SIGNING_SUBKEY STRANGER_KEY
}

# A case's directory, printed: its stand-ins' state (stub), its RUNNER_TEMP (temp), its git
# repositories (git), GITHUB_OUTPUT (output) and GITHUB_STEP_SUMMARY (summary).
fresh() {
  local d=${WORK}/cases/$1 tool found
  mkdir -p -- "${d}/stub" "${d}/temp" "${d}/git/shuwariafrica" "${d}/bin"
  # The case's stand-ins, each naming the case's state, since a step's env -i hands them none.
  for tool in curl gh sudo; do
    printf '#!/usr/bin/env bash
export STUB=%s/stub
exec %s/%s "$@"
' "${d}" "${STUBS}" "${tool}" >"${d}/bin/${tool}"
    chmod 755 -- "${d}/bin/${tool}"
  done
  : >"${d}/stub/routes"
  : >"${d}/stub/calls"
  : >"${d}/stub/argv"
  : >"${d}/output"
  : >"${d}/summary"
  found=$(PATH=${d}/bin:/usr/bin:/bin type -P curl)
  [[ ${found} == "${d}/bin/curl" ]] || fail 'curl does not resolve to the stand-in'
  printf '%s\n' "${d}"
}

route() { # case directory, method, url, status, body file
  printf '%s %s\t%s\t%s\n' "$2" "$3" "$4" "$5" >>"$1/stub/routes"
}

# The project's entry as projects.json holds it, edited by the jq filter <filter>.
project_json() {
  jq -n --arg tag "${TAG_KEY}" --arg signing "${SIGNING_KEY}" --argjson id "${ID}" '{
    repository: "shuwariafrica/probe", repository_id: $id, crates: ["probe-a", "probe-b"],
    crates_io_owners: ["arashi01"], tag_signers: [$tag], signing_key: $signing, first_version: "0.1.0",
    platforms: ["linux-x64"], license: "Apache-2.0", git_sources: []} | '"${1:-.}"
}

# public-crates' main in the case <dir>: projects.json holding the project probe (its entry edited by
# <filter>), platforms.json, keys/ with the tag signer, signing-keys/probe.asc (the certificate of
# the key home <signing>, signing by default) and gate-commit.
catalogue_repo() {
  local d=$1 filter=${2:-.} signing=${3:-signing} repo=$1/git/shuwariafrica/public-crates entry fpr
  rm -rf -- "${repo}"
  mkdir -p -- "${repo}/keys" "${repo}/signing-keys"
  entry=$(project_json "${filter}")
  jq '{projects: {probe: .}}' <<<"${entry}" >"${repo}/projects.json"
  printf '{"linux-x64": {"runner": "ubuntu-26.04"}, "windows-x64": {"runner": "windows-2025-vs2026"}}\n' >"${repo}/platforms.json"
  g tag --armor --export "${TAG_KEY}" >"${repo}/keys/${TAG_KEY}.asc"
  fpr=$(primary_of "${signing}")
  g "${signing}" --armor --export "${fpr}" >"${repo}/signing-keys/probe.asc"
  printf '%s\n' "${GATE}" >"${repo}/gate-commit"
  git init --quiet -b main -- "${repo}"
  git -C "${repo}" add -A
  git -C "${repo}" -c user.name=t -c user.email=t@example.invalid commit --quiet --no-gpg-sign -m catalogue
}

# The four bytes of <n> as a little-endian u32, as printf escapes.
le32() {
  printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255))
}

# crates.io's upload body carrying the file <crate> for <name> <version>, into <out>.
body() {
  local crate=$1 name=$2 version=$3 out=$4 json json_bytes size tar_bytes
  json=$(jq -nc --arg n "${name}" --arg v "${version}" '{name: $n, vers: $v, readme: null, readme_file: null}')
  json_bytes=$(le32 "${#json}")
  size=$(wc -c <"${crate}")
  tar_bytes=$(le32 "${size}")
  {
    # shellcheck disable=SC2059 # the format is the length's escapes
    printf "${json_bytes}"
    printf '%s' "${json}"
    # shellcheck disable=SC2059 # as above
    printf "${tar_bytes}"
    cat -- "${crate}"
  } >"${out}"
}

# A release of probe-a and probe-b at 0.1.0 in <dir>, as crate-package writes it, its SHA256SUMS
# signed by the subkey of the key home <key> (signing by default) with gpg's further <option>s;
# its digest in DIGEST.
release_dir() {
  local dir=$1 key=${2:-signing} crate found
  shift 2 || shift $#
  mkdir -p -- "${dir}"
  for crate in probe-a probe-b; do
    printf 'the tarball of %s\n' "${crate}" >"${dir}/${crate}-0.1.0.crate"
    body "${dir}/${crate}-0.1.0.crate" "${crate}" 0.1.0 "${dir}/${crate}-0.1.0.upload"
  done
  printf 'probe-a\nprobe-b\n' >"${dir}/order"
  printf '## 0.1.0\n\nThe first.\n' >"${dir}/changelog.md"
  (cd -- "${dir}" && sha256sum -- *.crate *.upload order changelog.md >SHA256SUMS)
  sign_sums "${dir}" "${key}" "$@"
  found=$(sha256sum -- "${dir}/SHA256SUMS")
  DIGEST=${found%% *}
}

sign_sums() { # dir, key home, gpg option...
  local dir=$1 key=$2 sub
  shift 2
  sub=$(subkey_of "${key}")
  g "${key}" "$@" --yes --armor --detach-sign --local-user "${sub}!" \
    --output "${dir}/SHA256SUMS.asc" "${dir}/SHA256SUMS"
}

# The keyservers' answers for <fingerprint> in the case <dir>: none (404), or <file> from both.
keyservers() {
  local d=$1 fpr=$2 file=${3:-}
  if [[ -n ${file} ]]; then
    route "${d}" GET "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${fpr}" 200 "${file}"
    route "${d}" GET "https://keys.openpgp.org/vks/v1/by-fingerprint/${fpr}" 200 "${file}"
  else
    route "${d}" GET "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${fpr}" 404 /dev/null
    route "${d}" GET "https://keys.openpgp.org/vks/v1/by-fingerprint/${fpr}" 404 /dev/null
  fi
}

# A project's release.yml into <file>, its actions at the commits the release holds them to and its
# verify on linux-x64, then edited by the yq expression <edit>.
release_yml() {
  local file=$1 edit=${2:-.}
  cat >"${file}" <<YAML
name: release
on:
  push:
    tags: ["v*"]
permissions: {}
jobs:
  admit:
    runs-on: ubuntu-26.04
    steps:
      - id: admit
        uses: shuwariafrica/.github/actions/crate-admit@${OWN}
  package:
    needs: admit
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: shuwariafrica/.github/actions/crate-package@${OWN}
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9
  verify:
    needs: [admit, package]
    strategy:
      matrix:
        include:
          - platform: linux-x64
            runner: ubuntu-26.04
    runs-on: \${{ matrix.runner }}
    steps:
      - uses: shuwariafrica/public-crates/.github/actions/checks@${GATE}
  sign:
    needs: [admit, package, verify]
    runs-on: ubuntu-26.04
    environment: release
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333
      - uses: shuwariafrica/.github/actions/crate-sign@${OWN}
YAML
  yq -i "${edit}" "${file}"
}

# The directory an action <name> runs from at OWN, as the runner lays it out.
action_path() {
  printf '%s/_actions/shuwariafrica/.github/%s/actions/%s\n' "${WORK}" "${OWN}" "$1"
}

# A script of the tree run as its step runs it, under env -i with the stand-ins first on PATH:
# <case dir> <script, under actions/> [VAR=value...]; standard input is the caller's. Leaves status,
# stdout and stderr in the case directory.
run_script() {
  local d=$1 script=$2 status=0
  shift 2
  env -i PATH="${d}/bin:/usr/bin:/bin" RUNNER_TEMP="${d}/temp" GITHUB_OUTPUT="${d}/output" \
    GITHUB_STEP_SUMMARY="${d}/summary" GIT_BASE="file://${d}/git" "$@" \
    bash --noprofile --norc "${TREE}/actions/${script}" >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
}

# The step <index> of the action <name> run as the runner runs it (step.sh), from a copy of its
# action.yml in the case directory whose one change is the stand-ins' directory on its run line's
# PATH; the copy's difference is asserted first.
wired() {
  local d=$1 name=$2 index=$3 changes other path
  sed "s|PATH=/usr/bin:/bin |PATH=${d}/bin:/usr/bin:/bin |" "${TREE}/actions/${name}/action.yml" >"${d}/action.yml"
  changes=$(diff "${TREE}/actions/${name}/action.yml" "${d}/action.yml" || true) # a difference is the point
  [[ ${changes} == *$'\n> '* ]] || fail "the copy of ${name}'s action.yml did not change"
  other=$(awk '/^[<>]/ && !/PATH=/' <<<"${changes}")
  [[ -z ${other} ]] || fail "the copy of ${name}'s action.yml changed more than its PATH: ${other}"
  path=$(action_path "${name}")
  runner=("RUNNER_TEMP=${d}/temp" "GITHUB_OUTPUT=${d}/output" "GITHUB_STEP_SUMMARY=${d}/summary"
    "GITHUB_ACTION_PATH=${path}" "GITHUB_WORKSPACE=${d}/workspace")
  step "${d}/action.yml" "${index}" "${d}"
}

fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

expect() { # case directory, exit status, text stdout or stderr must hold
  local status tail
  status=$(<"$1/status")
  tail=$(tail -n 5 "$1/stderr")
  [[ ${status} == "$2" ]] || fail "exit ${status}, not $2" "${tail}"
  grep -qF -- "$3" "$1/stdout" "$1/stderr" || fail "neither stdout nor stderr holds: $3" "${tail}"
}

output_of() { # case directory, name: the value GITHUB_OUTPUT holds for it
  sed -n "s/^$2=//p" "$1/output"
}

# How many of the case directory <dir>'s recorded calls match the pattern <pattern>.
calls() {
  grep -cE -- "$2" "$1/stub/calls" || true # none is an answer
}

out_is() { # case directory, name, value GITHUB_OUTPUT must hold for it
  local got
  got=$(output_of "$1" "$2")
  [[ ${got} == "$3" ]] || fail "$2 is [${got}], not [$3]"
}

calls_are() { # case directory, pattern, count of recorded calls that must match it
  local got
  got=$(calls "$1" "$2")
  [[ ${got} == "$3" ]] || fail "${got} calls match $2, not $3"
}

crates_cleanup() {
  local home
  for home in "${WORK}"/keys/*/ "${WORK}"/cases/*/temp/*/*/ "${WORK}"/cases/*/temp/*/; do
    [[ -d ${home} ]] || continue
    gpgconf --homedir "${home%/}" --kill all 2>/dev/null || true # its agent may never have started
  done
  rm -rf -- "${WORK}"
}

# The sourcer's main: its arguments, the tools, the run's keys and stand-ins, then each case.
crates_main() {
  local name status listed passed=0 failed=0 tool
  local -a cases=()
  TREE=$(cd -- "${HERE}/../.." && pwd)
  while (($# > 0)); do
    case $1 in
      --tree)
        TREE=$(cd -- "$2" && pwd)
        shift 2
        ;;
      -*)
        printf 'usage: run.sh [--tree <directory>] [<case>...]\n' >&2
        exit 64
        ;;
      *)
        cases+=("$1")
        shift
        ;;
    esac
  done
  readonly TREE
  for tool in gpg gpgconf git jq yq sha256sum mktemp "${TOOLS[@]}"; do
    command -v "${tool}" >/dev/null 2>&1 || {
      printf '%s not found\n' "${tool}" >&2
      exit 69
    }
  done
  WORK=$(mktemp -d)
  readonly WORK
  trap '((BASHPID == '"${BASHPID}"')) && crates_cleanup' EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  STUBS=${WORK}/stubs
  mkdir -p -- "${STUBS}" "${WORK}/_actions/shuwariafrica/.github"
  cp -- "${HERE}/../crate-publish/stub/curl" "${HERE}/../crate-publish/stub/gh" "${HERE}/../crate-publish/stub/sudo" "${STUBS}/"
  ln -s -- "${TREE}" "${WORK}/_actions/shuwariafrica/.github/${OWN}"
  make_keys
  if ((${#cases[@]} == 0)); then
    listed=$(declare -F | awk '$3 ~ /^case_/ {print substr($3, 6)}')
    mapfile -t cases <<<"${listed}"
  fi
  for name in "${cases[@]}"; do
    declare -F "case_${name}" >/dev/null || {
      printf 'no case %s\n' "${name}" >&2
      exit 64
    }
    input=()
    over=()
    caller=(PATH=/usr/bin:/bin "HOME=${WORK}" LANG=C.UTF-8)
    runner=()
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
}
