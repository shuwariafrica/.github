#!/usr/bin/env bash
# Takes one release of another repository the release gate guards into <path> under the workspace,
# once each proof has passed, in this order:
#   - the repository, resolved by its id, is the organisation's;
#   - its tag is an annotated tag object of a commit, signed once by an admitted core key neither
#     revoked nor expired now, its revocations read from both keyservers (tag.sh);
#   - SHA256SUMS is one signature by C1 naming <repository id>:refs/tags/<tag> (release-key's
#     verify.sh, certificate form), names every asset the release holds, and holds each to its digest;
#   - every file it names is the subject of an attestation of <workflow> at that tag and commit, made
#     on a GitHub-hosted runner, of the repository and its owner by their ids, and every subject such
#     an attestation names is a file SHA256SUMS names, at that digest.
# Then it copies the files beside <path>, re-hashes the copies, renames them into <path> whole, and
# writes `commit` to GITHUB_OUTPUT: nothing reaches <path>, and no output is written, before that.
# The roots are this action's own commit's: signing/c1-public.asc and signing/core-keys/*.asc at the
# repository root, two directories above this one.
# action.yml starts it under `env -i`, with the token on descriptor 3 and these variables:
# TAKE_REPOSITORY_ID, TAKE_TAG, TAKE_WORKFLOW, TAKE_PATH (the inputs); TAKE_GH_URL,
# TAKE_GH_SHA256, TAKE_SQV_URL, TAKE_SQV_SHA256 (its tools); TAKE_HKP, TAKE_VKS (the keyservers);
# RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_WORKSPACE and GITHUB_ACTION_PATH. It leaves nothing under
# RUNNER_TEMP.
# Exit 64 for an input it refuses, 65 for a proof that fails, 66 for a root this commit lacks, 69
# for a platform other than Linux; tools.sh's, tag.sh's and release-key's codes pass through.
# Linux with GNU coreutils, tar, curl, dpkg-deb and gpg in /usr/bin, as GitHub's Ubuntu images hold.
# shellcheck disable=SC2154 # TAKE_*, RUNNER_TEMP and the GITHUB_* variables are action.yml's env
set -euo pipefail

readonly OWNER_ID=93454356

work=''
stage=''
created=()

# Every value reaches the message through an argument, %q where an input or an answer gives it, so
# none can write a workflow command of its own.
refuse() { # exit code, printf format, value...
  local code=$1 format=$2 message
  shift 2
  # shellcheck disable=SC2059 # every format is a literal of this script
  printf -v message "${format}" "$@"
  printf '::error title=release-take::%s\n' "${message}" >&2
  exit "${code}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  local index
  [[ -z ${stage} ]] || rm -rf -- "${stage}"
  # Directories made for <path> go again when nothing was placed in them.
  for ((index = ${#created[@]} - 1; index >= 0; index--)); do
    rmdir -- "${created[index]}" 2>/dev/null || true # one that holds something stays
  done
  [[ -z ${work} ]] || rm -rf -- "${work}"
}

# A tag the API path and refs/tags/ both take as written: components of [A-Za-z0-9._+-], each opening
# with a letter or digit, no `..`, and no `.` or `.lock` at its end.
is_tag() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$ && $1 != *..* && $1 != *. && $1 != *.lock ]]
}

# The gate's form of `path`: directories under the workspace, none empty, `.` or `..`, the first
# not `.github` in any case.
is_path() {
  local segment segments
  [[ -n $1 && $1 != [/~]* && $1 != *[\\:]* && $1 != *[[:cntrl:]]* && $1 != */ && $1 != *//* ]] || return 1
  IFS=/ read -r -a segments <<<"$1"
  for segment in "${segments[@]}"; do
    [[ ${segment} != . && ${segment} != .. ]] || return 1
  done
  [[ ${segments[0],,} != .github ]]
}

# An asset name placed as one file in <path>.
is_name() {
  [[ -n $1 && $1 != */* && $1 != *..* && $1 != *\\* && $1 != *[[:cntrl:]]* ]]
}

check_inputs() {
  [[ ${TAKE_REPOSITORY_ID} =~ ^[1-9][0-9]*$ ]] ||
    refuse 64 'repository-id is a decimal repository id with no sign or leading zero, not %q' "${TAKE_REPOSITORY_ID}"
  [[ -n ${TAKE_TAG} ]] || refuse 64 'tag is empty: the take names its release exactly, and gh takes an empty tag as the latest release'
  # shellcheck disable=SC2310 # a predicate: its status is its answer
  is_tag "${TAKE_TAG}" || refuse 64 'tag %q is not one a release tag is named by' "${TAKE_TAG}"
  [[ ${TAKE_WORKFLOW} =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] ||
    refuse 64 'workflow is .github/workflows/<name>.yml or .yaml, not %q' "${TAKE_WORKFLOW}"
  # shellcheck disable=SC2310 # a predicate: its status is its answer
  is_path "${TAKE_PATH}" ||
    refuse 64 'path is directories under the workspace, none . or .., the first not .github, not %q' "${TAKE_PATH}"
}

# Every proof's working files, and the homes and caches gh and gpg read, in a directory of its own.
prepare() {
  local token=''
  work=$(mktemp -d -p "${RUNNER_TEMP}" release-take.XXXXXXXX)
  mkdir -m 700 "${work}/home" "${work}/tmp" "${work}/config" "${work}/cache" "${work}/gh" "${work}/gnupg"
  IFS= read -r -u 3 token || [[ -n ${token} ]] || refuse 64 'no token on descriptor 3'
  exec 3<&-
  [[ -n ${token} ]] || refuse 64 'token is empty'
  export HOME="${work}/home" TMPDIR="${work}/tmp" XDG_CONFIG_HOME="${work}/config" XDG_CACHE_HOME="${work}/cache" \
    GH_CONFIG_DIR="${work}/gh" GNUPGHOME="${work}/gnupg" GH_HOST=github.com GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1 LC_ALL=C
  export GH_TOKEN="${token}"
}

resolve() { # repository id: prints <owner>/<name>
  local answer id owner name
  answer=$(gh api "repositories/$1" --jq '"\(.id) \(.owner.id) \(.full_name)"')
  read -r id owner name <<<"${answer}"
  [[ ${id} == "$1" && ${owner} == "${OWNER_ID}" ]] ||
    refuse 65 'repository %s resolves to %q, id %q of owner %q, not one of the organisation (%s)' "$1" "${name}" "${id}" "${owner}" "${OWNER_ID}"
  [[ ${name} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse 65 'repository %s resolves to %q' "$1" "${name}"
  printf '%s\n' "${name}"
}

# The tag object refs/tags/<tag> names, its commit, and the payload and signature GitHub reports for
# it, which are the object's bytes before its signature and that signature. Prints the commit.
tag_object() { # repository, tag, directory
  local answer ref kind object sha commit named
  answer=$(gh api "repos/$1/git/ref/tags/$2" --jq '"\(.ref) \(.object.type) \(.object.sha)"')
  read -r ref kind object <<<"${answer}"
  [[ ${ref} == "refs/tags/$2" ]] || refuse 65 'GitHub answers refs/tags/%s with %q' "$2" "${ref}"
  [[ ${kind} == tag ]] || refuse 65 'refs/tags/%s names a %q, not a signed tag object' "$2" "${kind}"
  [[ ${object} =~ ^[0-9a-f]{40}$ ]] || refuse 65 'refs/tags/%s names %q' "$2" "${object}"
  answer=$(gh api "repos/$1/git/tags/${object}" --jq '"\(.sha) \(.object.type) \(.object.sha) \(.tag)"')
  read -r sha kind commit named <<<"${answer}"
  [[ ${sha} == "${object}" ]] || refuse 65 'GitHub answers tag object %s with %q' "${object}" "${sha}"
  [[ ${named} == "$2" ]] || refuse 65 'the tag object at refs/tags/%s names itself %q' "$2" "${named}"
  [[ ${kind} == commit ]] || refuse 65 'the tag %s is of a %q, not a commit' "$2" "${kind}"
  [[ ${commit} =~ ^[0-9a-f]{40}$ ]] || refuse 65 'the tag %s names %q' "$2" "${commit}"
  gh api "repos/$1/git/tags/${object}" --jq '.verification.payload // empty | @base64' | base64 -d >"$3/payload"
  gh api "repos/$1/git/tags/${object}" --jq '.verification.signature // empty | @base64' | base64 -d >"$3/signature"
  [[ -s $3/payload && -s $3/signature ]] || refuse 65 'the tag %s carries no signature' "$2"
  printf '%s\n' "${commit}"
}

# What both keyservers publish for each certificate under <certificates>, each into its own
# directory under <published>; a keyserver that does not answer ends the take (published.sh's 75).
published() { # certificates directory, published directory
  local certificate index=0
  for certificate in "$1"/*.asc; do
    index=$((index + 1))
    mkdir "$2/${index}"
    "${RELEASE_KEY}/published.sh" "${certificate}" "$2/${index}" "${TAKE_HKP}" "${TAKE_VKS}"
  done
}

# The release's assets, each a regular file at the top of <directory>; prints their names.
assets() { # directory, listing file
  local entry entries
  find "$1" -mindepth 1 -printf '%y %P\0' >"$2"
  mapfile -d '' -t entries <"$2"
  for entry in "${entries[@]}"; do
    [[ ${entry} == f\ * ]] || refuse 65 'the release holds %q, which is not a regular file' "${entry#* }"
    # shellcheck disable=SC2310 # a predicate: its status is its answer
    is_name "${entry#f }" || refuse 65 'the release holds an asset named %q' "${entry#f }"
    printf '%s\n' "${entry#f }"
  done
}

# Copies the verified files into a new directory beside <path>, re-hashes the copies, then renames
# it to <path>, so <path> appears whole or not at all.
place() { # release directory, workspace, path, name...
  local release=$1 at=$2 path=$3 segment parent
  local -a segments
  shift 3
  [[ ! -e ${at}/${path} && ! -L ${at}/${path} ]] ||
    refuse 64 '%q exists in the workspace; the take places a release into a new directory' "${path}"
  IFS=/ read -r -a segments <<<"${path}"
  for segment in "${segments[@]::${#segments[@]}-1}"; do
    at="${at}/${segment}"
    [[ ! -L ${at} ]] || refuse 64 '%q is a link; the take places nothing through one' "${at}"
    if [[ ! -e ${at} ]]; then
      mkdir -- "${at}"
      created+=("${at}")
    fi
    [[ -d ${at} ]] || refuse 64 '%q is not a directory' "${at}"
  done
  parent=${at}
  stage=$(mktemp -d -p "${parent}" .release-take.XXXXXXXX)
  cp -- "${release}/SHA256SUMS" "${release}/SHA256SUMS.asc" "${stage}/"
  for segment in "$@"; do
    cp -- "${release}/${segment}" "${stage}/${segment}"
  done
  if ! cmp -s -- "${release}/SHA256SUMS" "${stage}/SHA256SUMS" || ! cmp -s -- "${release}/SHA256SUMS.asc" "${stage}/SHA256SUMS.asc"; then
    refuse 65 'the copy of SHA256SUMS or its signature differs from what was verified'
  fi
  (cd "${stage}" && sha256sum --check --strict --quiet SHA256SUMS) || refuse 65 'a copy differs from its SHA256SUMS'
  chmod 755 "${stage}"
  mv --no-target-directory -- "${stage}" "${parent}/${segments[-1]}"
  stage=''
  created=()
}

main() {
  local root certificates release commit repository name line attested own verdict listed system
  local -a keys held
  local -A digest_of=()
  : "${TAKE_REPOSITORY_ID?}" "${TAKE_TAG?}" "${TAKE_WORKFLOW?}" "${TAKE_PATH?}"
  : "${TAKE_GH_URL:?}" "${TAKE_GH_SHA256:?}" "${TAKE_SQV_URL:?}" "${TAKE_SQV_SHA256:?}" "${TAKE_HKP:?}" "${TAKE_VKS:?}"
  : "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_WORKSPACE:?}" "${GITHUB_ACTION_PATH:?}"
  check_inputs
  system=$(uname -s)
  [[ ${system} == Linux ]] || refuse 69 'the take runs on Linux, not %q' "${system}"

  root=$(cd -- "${GITHUB_ACTION_PATH}/../.." && pwd)
  readonly RELEASE_KEY="${root}/actions/release-key"
  readonly C1="${root}/signing/c1-public.asc"
  certificates="${root}/signing/core-keys"
  [[ -f ${C1} ]] || refuse 66 'this commit of the action holds no signing/c1-public.asc'
  keys=("${certificates}"/*.asc)
  [[ -f ${keys[0]} ]] || refuse 66 'this commit of the action holds no signing/core-keys/*.asc'

  trap cleanup EXIT
  prepare
  "${GITHUB_ACTION_PATH}/tools.sh" "${work}/bin" "${TAKE_GH_URL}" "${TAKE_GH_SHA256}" "${TAKE_SQV_URL}" "${TAKE_SQV_SHA256}"
  export PATH="${work}/bin:/usr/bin:/bin"

  repository=$(resolve "${TAKE_REPOSITORY_ID}")
  mkdir "${work}/tag" "${work}/published-core" "${work}/published-c1" "${work}/attestations"
  commit=$(tag_object "${repository}" "${TAKE_TAG}" "${work}/tag")
  published "${certificates}" "${work}/published-core"
  "${GITHUB_ACTION_PATH}/tag.sh" "${certificates}" "${work}/published-core" "${TAKE_TAG}" "${commit}" \
    "${work}/tag/payload" "${work}/tag/signature"

  release="${work}/release"
  gh release download "${TAKE_TAG}" --repo "${repository}" --dir "${release}"
  listed=$(assets "${release}" "${work}/assets")
  [[ -f ${release}/SHA256SUMS && -f ${release}/SHA256SUMS.asc ]] || refuse 65 'the release holds no SHA256SUMS and SHA256SUMS.asc'
  mapfile -t held <<<"${listed}"
  mapfile -t listed <"${release}/SHA256SUMS"
  for line in "${listed[@]}"; do
    [[ ${line} =~ ^([0-9a-f]{64})\ [\ *](.+)$ ]] || refuse 65 'SHA256SUMS holds %q, not <sha256>  <name>' "${line}"
    name=${BASH_REMATCH[2]}
    # shellcheck disable=SC2310 # a predicate: its status is its answer
    is_name "${name}" || refuse 65 'SHA256SUMS names %q' "${name}"
    [[ ${name} != SHA256SUMS && ${name} != SHA256SUMS.asc ]] || refuse 65 'SHA256SUMS names %s' "${name}"
    [[ -z ${digest_of["${name}"]+named} ]] || refuse 65 'SHA256SUMS names %q twice' "${name}"
    digest_of["${name}"]=${BASH_REMATCH[1]}
  done
  ((${#digest_of[@]} > 0)) || refuse 65 'SHA256SUMS names no file'
  for name in "${held[@]}"; do
    [[ ${name} == SHA256SUMS || ${name} == SHA256SUMS.asc || -n ${digest_of["${name}"]+named} ]] ||
      refuse 65 'the release holds %q, which SHA256SUMS does not name' "${name}"
  done
  for name in "${!digest_of[@]}"; do
    [[ -f ${release}/${name} ]] || refuse 65 'SHA256SUMS names %q, which the release does not hold' "${name}"
  done

  "${RELEASE_KEY}/published.sh" "${C1}" "${work}/published-c1" "${TAKE_HKP}" "${TAKE_VKS}"
  "${RELEASE_KEY}/verify.sh" certificate "${C1}" "${work}/published-c1" "${TAKE_REPOSITORY_ID}:refs/tags/${TAKE_TAG}" \
    "${release}/SHA256SUMS"
  (cd "${release}" && sha256sum --check --strict --quiet SHA256SUMS) || refuse 65 'the release does not match its SHA256SUMS'

  # Per verified attestation, its repository's and owner's ids, then each subject it names.
  local -r report='.[] | .verificationResult | "attestation \(.signature.certificate.sourceRepositoryIdentifier) \(.signature.certificate.sourceRepositoryOwnerIdentifier)", (.statement.subject[] | "subject \(.digest.sha256) \(.name)")'
  for name in "${!digest_of[@]}"; do
    (cd "${work}/attestations" && gh attestation download "${release}/${name}" --repo "${repository}")
    [[ -s ${work}/attestations/sha256:${digest_of["${name}"]}.jsonl ]] ||
      refuse 65 '%s holds no attestation of %q' "${repository}" "${name}"
    verdict=$(gh attestation verify "${release}/${name}" --bundle "${work}/attestations/sha256:${digest_of["${name}"]}.jsonl" \
      --repo "${repository}" --signer-workflow "github.com/${repository}/${TAKE_WORKFLOW}@refs/tags/${TAKE_TAG}" \
      --source-ref "refs/tags/${TAKE_TAG}" --source-digest "${commit}" --deny-self-hosted-runners \
      --format json --jq "${report}") ||
      refuse 65 'no attestation of %q is one of %s by %s at refs/tags/%s, %s, on a GitHub-hosted runner' \
        "${name}" "${repository}" "${TAKE_WORKFLOW}" "${TAKE_TAG}" "${commit}"
    attested=0 own=0
    while IFS= read -r line; do
      case ${line} in
        "attestation ${TAKE_REPOSITORY_ID} ${OWNER_ID}") attested=$((attested + 1)) ;;
        attestation\ *)
          refuse 65 'an attestation of %q names repository and owner ids %q, not %s %s' \
            "${name}" "${line#attestation }" "${TAKE_REPOSITORY_ID}" "${OWNER_ID}"
          ;;
        "subject ${digest_of["${name}"]} ${name}") own=1 ;;
        subject\ *)
          line=${line#subject }
          [[ ${digest_of["${line#* }"]:-} == "${line%% *}" ]] ||
            refuse 65 'an attestation of %q names the subject %q, which SHA256SUMS does not' "${name}" "${line}"
          ;;
        *) refuse 65 'gh reports %q for %q' "${line}" "${name}" ;;
      esac
    done <<<"${verdict}"
    ((attested > 0 && own == 1)) || refuse 65 'no attestation names %q at its digest' "${name}"
  done

  place "${release}" "${GITHUB_WORKSPACE}" "${TAKE_PATH}" "${!digest_of[@]}"
  printf 'commit=%s\n' "${commit}" >>"${GITHUB_OUTPUT}"
  printf 'took %s %s at %s: %d files into %s\n' "${repository}" "${TAKE_TAG}" "${commit}" "$((${#digest_of[@]} + 2))" "${TAKE_PATH}"
}

main "$@"
