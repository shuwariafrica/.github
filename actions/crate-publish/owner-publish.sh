#!/usr/bin/env bash
# Targets: the owner's Linux workstation (bash 5, curl, jq, git, gpg, gh signed in, coreutils).
# The owner's first publication of one crate of a release (the release's design, 2.5 line 2), run
# from <clone>, a fresh clone of shuwariafrica/.github, as `git -C <clone> show
# <own>:actions/crate-publish/owner-publish.sh | bash -s -- <clone> <own> ...`. Before reading
# anything else of .github it refuses unless <clone> holds <own>, the commit the run's
# crate-publish ran at, on its origin/main, since GitHub serves a fork's commit under the parent's
# name and nothing on the workstation holds it to main otherwise. It then reads crate-publish's
# lib.sh and release-key's published.sh from the clone at <own>, never over the network; downloads
# the run's own `package` and `signature` artefacts with gh, never the GitHub release; verifies them
# as crate-publish does (the project's certificate in public-crates' signing-keys/ at main's head,
# held to projects.json's signing_key, the keyservers' revocations, one good signature, the body and
# the crate against SHA256SUMS, the body carrying the signed crate); and only then PUTs the body to
# crates.io. The crate-scoped token arrives on descriptor 3, since standard input carries this
# script; it is never an argument, of this script or of curl, which reads its header from its own
# standard input. A body that fails a check is never sent, since crates.io never takes a version
# twice.
# Usage: ... | bash -s -- <clone> <own> <owner/repository> <tag> <run id> <crate> 3<<<"${token}"
# Exit 0 when crates.io took the body; 1 when a check or crates.io refused it; 64 on bad arguments;
# 69 when a tool is missing; 75 when something could not be read.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
# git's configuration for every git run here is the command line's alone.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

WORK=''

cleanup() {
  [[ -n ${WORK} ]] || return 0
  # shellcheck disable=SC2310
  # stop_homes is absent until lib.sh is sourced, and a home's agent may never have started.
  stop_homes "${WORK}" 2>/dev/null || true
  rm -rf -- "${WORK}"
}

refuse() {
  printf '%s: nothing is read or sent\n' "$1" >&2
  exit 1
}

main() {
  local clone=${1:-} own=${2:-} repository=${3:-} tag=${4:-} run=${5:-} crate=${6:-} token='' tool dot version id project body
  local line code agent='shuwariafrica-crate-release (https://github.com/shuwariafrica/.github)'
  [[ $# -eq 6 && -d ${clone} && ${own} =~ ^[0-9a-f]{40}$ && ${repository} =~ ^shuwariafrica/[A-Za-z0-9._-]+$ &&
    ${tag} =~ ^v[0-9A-Za-z.+-]+$ && ${run} =~ ^[1-9][0-9]*$ && ${crate} =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || {
    printf 'usage: owner-publish.sh <clone> <own> <owner/repository> <tag> <run id> <crate>, the token on descriptor 3\n' >&2
    exit 64
  }
  for tool in curl jq git gpg gpgconf gh sha256sum od dd cmp stat mktemp realpath; do
    command -v "${tool}" >/dev/null 2>&1 || {
      printf '%s not found\n' "${tool}" >&2
      exit 69
    }
  done
  # The token first, before anything else is read.
  IFS= read -r -u 3 token || [[ -n ${token} ]] || refuse 'no token on descriptor 3'
  exec 3<&-
  [[ ${#token} -eq 35 && ${token} == cio* ]] || refuse 'that is not a crates.io token (cio and 32 characters)'
  git -C "${clone}" cat-file -e "${own}^{commit}" 2>/dev/null || refuse "${clone} holds no commit ${own}"
  git -C "${clone}" merge-base --is-ancestor "${own}" refs/remotes/origin/main 2>/dev/null ||
    refuse "${own} is not on shuwariafrica/.github's main in ${clone}"
  WORK=$(mktemp -d)
  trap '((BASHPID == '"${BASHPID}"')) && cleanup' EXIT
  dot=${WORK}/dot/actions
  mkdir -p -- "${dot}/crate-publish" "${dot}/release-key" "${WORK}/release"
  git -C "${clone}" show "${own}:actions/crate-publish/lib.sh" >"${dot}/crate-publish/lib.sh"
  git -C "${clone}" show "${own}:actions/release-key/published.sh" >"${dot}/release-key/published.sh"
  chmod 755 -- "${dot}/release-key/published.sh"
  # shellcheck source=actions/crate-publish/lib.sh
  source "${dot}/crate-publish/lib.sh"
  : "${GIT_BASE:=https://github.com}"
  gh run download "${run}" --repo "${repository}" --name package --dir "${WORK}/release" >/dev/null
  gh run download "${run}" --repo "${repository}" --name signature --dir "${WORK}/release" >/dev/null
  id=$(gh api "repos/${repository}" --jq .id)
  version=${tag#v}
  catalogue "${WORK}/public-crates" >/dev/null
  project=$(project_of "${WORK}/public-crates" "${repository}" "${id}")
  jq -e --arg c "${crate}" '.crates | index($c) != null' <<<"${project}" >/dev/null ||
    die "${crate} is not one of ${repository}'s crates: nothing is sent"
  verify_release "${WORK}/release" "${WORK}/public-crates" "${project}" "${WORK}"
  body=${crate}-${version}.upload
  for line in "${body}" "${crate}-${version}.crate"; do
    line=$(awk -v f="${line}" '{name = $2; sub(/^\*/, "", name); if (name == f) print $1 "  " name}' "${WORK}/release/SHA256SUMS")
    [[ -n ${line} ]] || die "SHA256SUMS names no file of ${crate} ${version}: nothing is sent"
    (cd -- "${WORK}/release" && sha256sum --check --strict --quiet <<<"${line}") ||
      die "${line##* } is not the file SHA256SUMS signed: nothing is sent"
  done
  # shellcheck disable=SC2310
  # body_carries's status is its answer.
  body_carries "${WORK}/release/${body}" "${WORK}/release/${crate}-${version}.crate" "${crate}" "${version}" ||
    die "${body} does not carry the signed ${crate}-${version}.crate: nothing is sent"
  printf 'verified %s against SHA256SUMS, signed by the project'"'"'s key\n' "${body}"
  code=$(printf 'Authorization: %s\n' "${token}" | curl --silent --show-error --max-time 300 --user-agent "${agent}" \
    --output "${WORK}/answer" --write-out '%{http_code}' --header @- --request PUT \
    --data-binary "@${WORK}/release/${body}" https://crates.io/api/v1/crates/new) || code=000
  token=''
  [[ ${code} == 200 ]] || die "crates.io answered ${code}: $(<"${WORK}/answer")"
  printf 'crates.io took %s %s; revoke the token now (line 3)\n' "${crate}" "${version}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
